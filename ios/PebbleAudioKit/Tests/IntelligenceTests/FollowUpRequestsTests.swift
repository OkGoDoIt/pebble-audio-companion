import Foundation
import Testing
import Transcription

@testable import Intelligence

// Finding the sentences in which a person asks, out loud, for something to be remembered.
// Narrow on purpose: a request for information or talk about the feature is not one.
@Suite struct FollowUpRequestsTests {
    @Test(arguments: [
        "Please help me remember to follow up on this.",
        "Create a follow-up for that, okay?",
        "Make a follow-up for the permit.",
        "Remind me to take the bins out tonight.",
        "Please remind me to implement that properly.",
        "Don't let me forget to call the plumber.",
        "Note to self: renew the parking permit.",
        "I need to remember to bring the cables.",
        "Add this to my follow-ups.",
        "And a third follow-up reminder is the watch button.",
    ])
    func findsARequest(_ sentence: String) {
        #expect(FollowUpRequestDetector.mentionsRequest(sentence))
    }

    @Test(arguments: [
        "Can you remind me what her name was?",
        "You remind me of my brother.",
        "We should create follow-ups from phone calls too.",
        "The app adds reminders for every meeting.",
        "I'll follow up with the landlord tomorrow.",
        "That reminds me, the van is due back at eleven.",
    ])
    func ignoresWhatIsNotARequest(_ sentence: String) {
        #expect(!FollowUpRequestDetector.mentionsRequest(sentence))
    }

    @Test func findsEachRequestSentenceInItsTurn() {
        let part = FollowUpSourcePart(
            segmentId: "seg-1", startedAtMs: 0,
            text: "a b c",
            turns: [
                TranscriptSegment(
                    text: "I have an idea. Please help me remember it. It is about the shed.",
                    startMs: 10_000, endMs: 20_000, speaker: "1"),
                TranscriptSegment(
                    text: "Sure, it sounds good.", startMs: 20_000, endMs: 22_000, speaker: "2"),
                TranscriptSegment(
                    text: "Remind me to paint the shed on Saturday.", startMs: 300_000,
                    endMs: 304_000, speaker: "1"),
            ])
        let found = FollowUpRequestDetector.requests(in: [
            FollowUpSourcePart(
                segmentId: part.segmentId, startedAtMs: 0,
                text: part.turns.map(\.text).joined(separator: " "), turns: part.turns)
        ])
        #expect(found.map(\.sentence) == [
            "Please help me remember it.", "Remind me to paint the shed on Saturday.",
        ])
        #expect(found.first?.startMs == 10_000)
    }

    @Test func aQuoteNearARequestIsAskedForAndOneFarAwayIsNot() {
        let requests = [
            FollowUpRequest(
                segmentId: "seg-1", sentence: "Remind me.", startMs: 600_000, endMs: 605_000)
        ]
        let near = QuoteLocation(segmentId: "seg-1", startMs: 560_000, endMs: 570_000)
        let far = QuoteLocation(segmentId: "seg-1", startMs: 100_000, endMs: 110_000)
        let elsewhere = QuoteLocation(segmentId: "seg-2", startMs: 600_000, endMs: 601_000)
        #expect(FollowUpRequestDetector.isAskedFor(near, requests: requests))
        #expect(!FollowUpRequestDetector.isAskedFor(far, requests: requests))
        #expect(!FollowUpRequestDetector.isAskedFor(elsewhere, requests: requests))
    }
}
