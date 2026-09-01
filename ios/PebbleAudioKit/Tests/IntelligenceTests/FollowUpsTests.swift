import AppDB
import Foundation
import Testing
import Transcription

@testable import Intelligence

// The local half of the follow-up contract: what survives parsing, how a conversation is
// rendered for the model, and how a quoted line is found again in the recording.
//
// Every rejection asserted here corresponds to something a real recording produced. The old
// extractor shipped "**Improve transcription UI formatting** — **Owner:** Roger/team" and the
// line "Here are the action items I found:" as things a person had to do; those are the two
// shapes the parser now refuses outright rather than cleaning up.

@Suite struct FollowUpExtractionParserTests {
    private func item(
        task: String = "Take Theo to the airport at 7:00",
        quote: String = "I got to take Theo at 7:00.",
        ifForgotten: String = "Theo misses his ride",
        dueDate: String = "",
        confidence: String = "high"
    ) -> ExtractedFollowUp {
        ExtractedFollowUp(
            task: task, quote: quote, ifForgotten: ifForgotten, dueDate: dueDate,
            confidence: confidence)
    }

    @Test func parsesTheAgreedShape() {
        let raw = """
            {"items":[{"task":"Take Theo to the airport at 7:00",
            "quote":"I got to take Theo at 7:00.","ifForgotten":"Theo misses his ride",
            "dueDate":"2026-08-31","confidence":"high"}]}
            """
        let items = FollowUpExtractionParser.parse(raw: raw)
        #expect(items?.count == 1)
        #expect(items?.first?.task == "Take Theo to the airport at 7:00")
        #expect(items?.first?.dueDate == "2026-08-31")
        #expect(items?.first?.confidence == "high")
    }

    @Test func acceptsAnEmptyListAsARealAnswer() {
        #expect(FollowUpExtractionParser.parse(raw: #"{"items":[]}"#)?.isEmpty == true)
    }

    @Test func unwrapsAFencedResponse() {
        let raw = """
            Here you go:
            ```json
            {"items":[{"task":"Renew the permit","quote":"I need to renew the permit this week",
            "ifForgotten":"the permit lapses","dueDate":"","confidence":"medium"}]}
            ```
            """
        #expect(FollowUpExtractionParser.parse(raw: raw)?.count == 1)
    }

    /// Prose is a FAILED call, not a lenient one. The old parser's prose path is where
    /// "Here are the action items I found:" reached the person's list as a task.
    @Test func refusesProse() {
        #expect(FollowUpExtractionParser.parse(raw: "- Send Dana the file\n- Book the electrician")
            == nil)
        #expect(FollowUpExtractionParser.parse(raw: "No action items found.") == nil)
    }

    @Test func dropsAnItemWithNoUsableQuote() {
        #expect(FollowUpExtractionParser.clean(item(quote: "")) == nil)
        #expect(FollowUpExtractionParser.clean(item(quote: "yeah ok")) == nil)
    }

    @Test func dropsAnItemThatCannotNameACost() {
        #expect(FollowUpExtractionParser.clean(item(ifForgotten: "   ")) == nil)
    }

    @Test func dropsMarkdownAndFieldLabels() {
        #expect(
            FollowUpExtractionParser.clean(item(task: "**Improve transcription UI formatting**"))
                == nil)
        #expect(
            FollowUpExtractionParser.clean(item(task: "Send the file. Owner: Roger")) == nil)
        #expect(FollowUpExtractionParser.clean(item(task: "Book it. Due: Friday")) == nil)
    }

    /// Prose in a date slot is the model saying there is no date. It must never become one:
    /// a follow-up dated "when she is back" sorts as if it were due at the epoch.
    @Test func keepsOnlyRealCalendarDates() {
        #expect(FollowUpExtractionParser.clean(item(dueDate: "2026-09-04"))?.dueDate == "2026-09-04")
        #expect(FollowUpExtractionParser.clean(item(dueDate: "Thursday"))?.dueDate == "")
        #expect(FollowUpExtractionParser.clean(item(dueDate: "when she is back"))?.dueDate == "")
        #expect(FollowUpExtractionParser.clean(item(dueDate: "next month"))?.dueDate == "")
    }

    @Test func normalizesConfidenceToTheThreeWeKnow() {
        #expect(FollowUpExtractionParser.clean(item(confidence: "HIGH"))?.confidence == "high")
        #expect(FollowUpExtractionParser.clean(item(confidence: "certain"))?.confidence == "medium")
    }

    @Test func tidiesWhitespaceAndStrayQuoting() {
        let cleaned = FollowUpExtractionParser.clean(
            item(task: "  Take   Theo  to the\nairport ", quote: "\u{201C}I got to take Theo\u{201D}"))
        #expect(cleaned?.task == "Take Theo to the airport")
        #expect(cleaned?.quote == "I got to take Theo")
    }
}

@Suite struct FollowUpCurationParserTests {
    @Test func parsesDecisions() {
        let raw = """
            {"decisions":[
              {"index":1,"decision":"keep","reason":"dated commitment","task":"Take Theo at 7:00",
               "priority":"high","dueDate":"2026-08-31"},
              {"index":2,"decision":"drop","reason":"resolved in the recording","task":"",
               "priority":"normal","dueDate":""}]}
            """
        let decisions = FollowUpCurationParser.parse(raw: raw)
        #expect(decisions?.count == 2)
        #expect(decisions?.first?.decision == "keep")
        #expect(decisions?.last?.reason == "resolved in the recording")
    }

    @Test func mapsPriorityWords() {
        #expect(FollowUpCurationParser.priority("high") == .high)
        #expect(FollowUpCurationParser.priority("LOW") == .low)
        #expect(FollowUpCurationParser.priority("whatever") == .normal)
    }

    @Test func refusesProse() {
        #expect(FollowUpCurationParser.parse(raw: "keep 1, drop 2") == nil)
    }
}

@Suite struct FollowUpTranscriptRendererTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private func part(
        id: String = "seg-1", startedAtMs: Int64 = 1_788_193_751_778, text: String,
        turns: [TranscriptSegment] = []
    ) -> FollowUpSourcePart {
        FollowUpSourcePart(segmentId: id, startedAtMs: startedAtMs, text: text, turns: turns)
    }

    /// The model used to be handed "starts at epoch ms 1788193751778" and asked to resolve
    /// "tomorrow" from it. A real local date is what makes a due date possible at all.
    @Test func leadsWithARealLocalDate() {
        let body = FollowUpTranscriptRenderer.render(
            parts: [part(text: "Hello")],
            title: nil, summary: nil,
            recordedAt: Date(timeIntervalSince1970: 1_788_193_751.778),
            timeZone: zone, maxChars: 10_000)
        #expect(body.hasPrefix("Recorded: Monday, 2026-08-31"))
        #expect(!body.contains("1788193751778"))
    }

    @Test func carriesTheConversationTitleAndSummary() {
        let body = FollowUpTranscriptRenderer.render(
            parts: [part(text: "Hello")],
            title: "Walking to the market", summary: "They walked to a corner shop.",
            recordedAt: Date(timeIntervalSince1970: 1_788_193_751.778),
            timeZone: zone, maxChars: 10_000)
        #expect(body.contains("Conversation: Walking to the market"))
        #expect(body.contains("Summary so far: They walked to a corner shop."))
    }

    /// Two adjacent sentences by two people read as one person's promise in flat text. That is
    /// exactly how "I might try the soup" and someone else's "I can tell you when to
    /// come down" became a single commitment.
    @Test func splitsSpeakerTurnsAndCollapsesRuns() {
        let turns = [
            TranscriptSegment(text: "I might try the soup.", startMs: 0, endMs: 900,
                speaker: "1"),
            TranscriptSegment(text: "Just in case.", startMs: 900, endMs: 1500, speaker: "1"),
            TranscriptSegment(text: "I can text you when it is ready.", startMs: 1600,
                endMs: 2600, speaker: "3"),
        ]
        let rendered = FollowUpTranscriptRenderer.speakerLines(
            part(text: "flat", turns: turns))
        #expect(rendered == """
            S1: I might try the soup. Just in case.
            S3: I can text you when it is ready.
            """)
    }

    @Test func fallsBackToFlatTextWithoutDiarization() {
        #expect(
            FollowUpTranscriptRenderer.speakerLines(part(text: "just words")) == "just words")
    }

    /// A conversation's later parts are what close its open loops. Trimming from the front is
    /// what makes a finished errand look outstanding.
    @Test func keepsTheEndWhenItHasToTrim() {
        let long = String(repeating: "a", count: 5_000)
        let body = FollowUpTranscriptRenderer.render(
            parts: [part(text: long + "THE-LAST-WORD")],
            title: nil, summary: nil,
            recordedAt: Date(timeIntervalSince1970: 1_788_193_751.778),
            timeZone: zone, maxChars: 500)
        #expect(body.contains("THE-LAST-WORD"))
        #expect(body.hasPrefix("[earlier part of this conversation omitted for length]"))
    }
}

@Suite struct FollowUpQuoteLocatorTests {
    private let parts = [
        FollowUpSourcePart(
            segmentId: "seg-a", startedAtMs: 0,
            text: "Okay. I got to take Theo at 7:00. It is during rush hour.",
            turns: [
                TranscriptSegment(text: "Okay.", startMs: 0, endMs: 500, speaker: "1"),
                TranscriptSegment(
                    text: "I got to take Theo at 7:00.", startMs: 600, endMs: 2400, speaker: "1"),
            ]),
        FollowUpSourcePart(
            segmentId: "seg-b", startedAtMs: 900_000,
            text: "We have to return the van by 11:00.", turns: []),
    ]

    @Test func findsTheSegmentAQuoteCameFrom() {
        let hit = FollowUpQuoteLocator.locate(quote: "I got to take Theo at 7:00.", in: parts)
        #expect(hit?.segmentId == "seg-a")
        #expect(hit?.startMs == 600)
        #expect(hit?.endMs == 2400)
    }

    @Test func matchesPastPunctuationAndCase() {
        let hit = FollowUpQuoteLocator.locate(quote: "we HAVE to return the van by 11:00", in: parts)
        #expect(hit?.segmentId == "seg-b")
        #expect(hit?.startMs == nil)
    }

    /// The check that makes "quote the words" a fact about every shipped row rather than an
    /// instruction the model may ignore.
    @Test func refusesAQuoteThatIsNotInTheRecording() {
        #expect(
            FollowUpQuoteLocator.locate(quote: "I will file the quarterly report", in: parts)
                == nil)
    }

    /// A one-word backchannel used to claim the quote and send the player to the wrong speaker
    /// a minute early: "and" is a substring of "h-and", and the loop took the first match.
    @Test func aBackchannelTurnCannotClaimTheQuote() {
        let part = FollowUpSourcePart(
            segmentId: "seg-c", startedAtMs: 0,
            text: "And? Can you hand me the folder tomorrow morning?",
            turns: [
                TranscriptSegment(text: "And?", startMs: 0, endMs: 800, speaker: "1"),
                TranscriptSegment(
                    text: "Can you hand me the folder tomorrow morning?", startMs: 61_000,
                    endMs: 65_000, speaker: "2"),
            ])
        let hit = FollowUpQuoteLocator.locate(
            quote: "Can you hand me the folder tomorrow morning?", in: [part])
        #expect(hit?.startMs == 61_000)
        #expect(hit?.endMs == 65_000)
    }

    @Test func refusesAQuoteTooShortToMeanAnything() {
        #expect(FollowUpQuoteLocator.locate(quote: "yes", in: parts) == nil)
    }
}
