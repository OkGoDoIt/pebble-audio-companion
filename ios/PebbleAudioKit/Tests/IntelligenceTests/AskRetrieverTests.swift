import Foundation
import Testing
import AppDB
import SegmentStore
import WireProtocol

@testable import Intelligence

// Port of `app/src/commonTest/.../AskRetrieverTest.kt` plus the Ask behaviors plan Part 4.5 /
// 6.6 pins on this layer: hybrid retrieval order + cap, source-order citation numbering, the
// B7-fixed gap summary (visible loss only, never silence), scope resolution as a pure
// function, and Q18 history persistence through AskHistoryStore.

@Suite struct AskRetrieverTests {
    @Test func formatForPromptIncludesSegmentTimesAndGaps() {
        let prompt = AskRetriever().formatForPrompt([
            AskRetriever.RetrievedChunk(
                segmentId: "seg-1",
                text: "We decided to move the launch.",
                startTimeMs: 1_000,
                endTimeMs: 9_000,
                gapSummary: "1 gap, about 2000ms missing; answer may be incomplete.")
        ])

        #expect(prompt.contains("[segment seg-1 @1000-9000ms]"))
        #expect(prompt.contains("GAPS: 1 gap"))
        #expect(prompt.contains("We decided to move the launch."))
    }

    /// Epoch ms are meaningless to a language model — with a real label the prompt says WHEN.
    @Test func formatForPromptPrefersTheHumanReadableRecordingTime() {
        let prompt = AskRetriever().formatForPrompt([
            AskRetriever.RetrievedChunk(
                segmentId: "seg-1",
                text: "We fly out tomorrow.",
                startTimeMs: 1_000,
                endTimeMs: 9_000,
                timeLabel: "Saturday, 29 August 2026, 9:35 PM (yesterday)")
        ])

        #expect(prompt.contains(
            "[segment seg-1, recorded Saturday, 29 August 2026, 9:35 PM (yesterday)]"))
        #expect(!prompt.contains("ms]"))
    }

    // MARK: Time context

    /// The label is built in the zone the audio was RECORDED in (Q16), and names that zone
    /// only when it differs from where the user is standing now.
    @Test func whenLabelStatesTheRecordedDateTimeAndHowLongAgo() {
        let start = atUtc(2026, 8, 29, 21, 35)
        let now = atUtc(2026, 8, 30, 12, 0)

        #expect(
            askWhenLabel(
                startMs: start, endMs: atUtc(2026, 8, 29, 21, 51), timeZoneID: "UTC",
                nowMs: now, deviceTimeZoneID: "UTC")
                == "Saturday, 29 August 2026, 9:35 PM – 9:51 PM (yesterday)")
        // Same instant, recorded in Tokyo: local wall time, and the zone is worth naming.
        #expect(
            askWhenLabel(
                startMs: start, endMs: nil, timeZoneID: "Asia/Tokyo",
                nowMs: now, deviceTimeZoneID: "UTC")
                == "Sunday, 30 August 2026, 6:35 AM (today; Asia/Tokyo)")
    }

    @Test func relativeDayPhrasesReadNaturally() {
        #expect(askRelativeDayPhrase(daysAgo: 0) == "today")
        #expect(askRelativeDayPhrase(daysAgo: 1) == "yesterday")
        #expect(askRelativeDayPhrase(daysAgo: 6) == "6 days ago")
        #expect(askDayDelta(from: "2026-08-29", to: "2026-09-02") == 4)
    }

    /// Without "right now" the model cannot resolve "tomorrow" said in any transcript.
    @Test func nowContextAnchorsTheCurrentDateAndTheScope() {
        let context = askNowContext(
            nowMs: atUtc(2026, 8, 31, 12, 4), timeZoneID: "UTC",
            scopeDescription: "Last 7 days")
        #expect(context.contains("RIGHT NOW: Monday, 31 August 2026 at 12:04 PM (UTC)"))
        #expect(context.contains("TRANSCRIPT RANGE: Last 7 days"))
    }

    // MARK: Follow-ups carry the conversation

    @Test func threadContextReplaysTheEarlierTurnsAndClipsLongAnswers() {
        let turns = [
            AskEntry(
                id: "1", question: "What's the plan?", answerText: "Stay in Saigon [1].",
                citations: [], scopeDescription: "Today", createdAtMs: 1),
            AskEntry(
                id: "2", threadId: "1", question: "For how long?",
                answerText: String(repeating: "x", count: 2_000), citations: [],
                scopeDescription: "Today", createdAtMs: 2),
        ]
        let context = askThreadContext(turns, maxAnswerChars: 1_200)

        #expect(context?.hasPrefix("CONVERSATION SO FAR:") == true)
        #expect(context?.contains("User: What's the plan?\nYou: Stay in Saigon [1].") == true)
        #expect(context?.contains("User: For how long?") == true)
        #expect(context?.contains(String(repeating: "x", count: 1_200) + "…") == true)
        #expect(askThreadContext([]) == nil)
    }

    /// Only the newest turns ride along — the transcripts still need the input budget.
    @Test func threadContextKeepsOnlyTheNewestTurns() {
        let turns = (1...10).map {
            AskEntry(
                id: "\($0)", threadId: "1", question: "q\($0)", answerText: "a\($0)",
                citations: [], scopeDescription: "Today", createdAtMs: Int64($0))
        }
        let context = askThreadContext(turns, maxTurns: 3) ?? ""
        #expect(context.contains("User: q8"))
        #expect(!context.contains("User: q7"))
    }

    /// "So what's the plan?" retrieves nothing on its own; the earlier questions seed it.
    @Test func retrievalQueryForAFollowUpIncludesTheEarlierQuestions() {
        let turns = [
            AskEntry(id: "1", question: "What did we decide about Bangkok?", answerText: "…",
                citations: [], scopeDescription: "Today", createdAtMs: 1),
            AskEntry(id: "2", threadId: "1", question: "And the flights?", answerText: "…",
                citations: [], scopeDescription: "Today", createdAtMs: 2),
        ]
        #expect(
            askRetrievalQuery(question: "So what's the plan?", priorTurns: turns)
                == "What did we decide about Bangkok? And the flights? So what's the plan?")
        #expect(
            askRetrievalQuery(question: "What's new?", priorTurns: []) == "What's new?")
    }

    @Test func retrieveOrdersIndexHitsFirstThenPadsWithTheMostRECENT() async {
        let excerpts = (1...15).map {
            TranscriptExcerpt(
                segmentId: "seg-\($0)", text: "text \($0)", startTimeMs: Int64($0) * 60_000)
        }
        let retriever = AskRetriever(search: { _, _ in
            [AskIndexHit(id: "seg-9", score: 2.0), AskIndexHit(id: "seg-3", score: 1.5)]
        })

        let chunks = await retriever.retrieve(query: "launch", excerpts: excerpts)

        #expect(chunks.count == 12)
        // Hits lead in relevance order, carrying their scores.
        #expect(chunks[0].segmentId == "seg-9")
        #expect(chunks[0].score == 2.0)
        #expect(chunks[1].segmentId == "seg-3")
        // The padding is the NEWEST of what is left, not the oldest. Taking `excerpts.prefix`
        // — which arrive oldest-first — meant a question asked today was padded out with the
        // very start of the archive.
        #expect(chunks[2].segmentId == "seg-15")
        #expect(chunks[3].segmentId == "seg-14")
        #expect(!chunks.contains { $0.segmentId == "seg-1" })
        #expect(!chunks.dropFirst(2).contains { $0.segmentId == "seg-9" || $0.segmentId == "seg-3" })
    }

    @Test func retrieveWithoutIndexTakesTheMostRecentExcerpts() async {
        let excerpts = (1...3).map {
            TranscriptExcerpt(
                segmentId: "seg-\($0)", text: "text", startTimeMs: Int64($0) * 60_000)
        }
        let chunks = await AskRetriever().retrieve(query: "q", excerpts: excerpts)
        #expect(chunks.map(\.segmentId) == ["seg-3", "seg-2", "seg-1"])
        #expect(chunks.allSatisfy { $0.score == 0 })
    }

    /// The bug that made Ask answer every question in the app from the same twelve recordings.
    ///
    /// The search index keys documents on CONVERSATION ids (`conv-<firstMemberSegmentId>`,
    /// donated by `SpotlightDonator`), while excerpts key on segment ids. The retriever compared
    /// the two directly, so no hit could ever match an excerpt: every index hit was silently
    /// dropped and the result fell through to "the first twelve excerpts in list order" —
    /// oldest first, the same twelve every time, whatever was asked.
    @Test func retrieveMapsConversationHitsOntoTheirMemberSegments() async {
        let excerpts = (1...15).map {
            TranscriptExcerpt(
                segmentId: "seg-\($0)", text: "text \($0)", startTimeMs: Int64($0) * 60_000)
        }
        let retriever = AskRetriever(search: { _, _ in
            [AskIndexHit(id: "conv-seg-4", score: 3.0)]
        })

        // Without the bridge the conversation id matches nothing, exactly as before the fix.
        let unmapped = await retriever.retrieve(query: "q", excerpts: excerpts)
        #expect(!unmapped.contains { $0.score > 0 })

        // With it, the hit expands to every member of that conversation.
        let mapped = await retriever.retrieve(
            query: "q", excerpts: excerpts,
            segmentIdsForHit: { $0 == "conv-seg-4" ? ["seg-4", "seg-5"] : [$0] })
        #expect(mapped[0].segmentId == "seg-4")
        #expect(mapped[0].score == 3.0)
        #expect(mapped[1].segmentId == "seg-5")
        #expect(mapped[1].score == 3.0)
        // And a member is never also stuffed in again as padding.
        #expect(mapped.filter { $0.segmentId == "seg-4" }.count == 1)
    }

    @Test func aHitNamingASegmentNoLongerOnDiskDoesNotShrinkTheResult() async {
        let excerpts = (1...15).map {
            TranscriptExcerpt(
                segmentId: "seg-\($0)", text: "text \($0)", startTimeMs: Int64($0) * 60_000)
        }
        let retriever = AskRetriever(search: { _, _ in
            [AskIndexHit(id: "conv-deleted", score: 9.0), AskIndexHit(id: "seg-2", score: 1.0)]
        })
        let chunks = await retriever.retrieve(query: "q", excerpts: excerpts)
        #expect(chunks.count == 12)
        #expect(chunks[0].segmentId == "seg-2")
    }

    /// Citation numbers key to SOURCE-SEGMENT order, not relevance order, so a model `[n]`
    /// maps straight back to `output.segmentIds[n-1]`.
    @Test func citationNumbersKeyToSourceOrderNotRelevanceOrder() {
        let excerpts = [
            TranscriptExcerpt(segmentId: "seg-a", text: "alpha"),
            TranscriptExcerpt(segmentId: "seg-b", text: "beta"),
            TranscriptExcerpt(segmentId: "seg-a", text: "alpha again"),
            TranscriptExcerpt(segmentId: "seg-c", text: "gamma"),
        ]
        let order = askSourceOrder(excerpts)
        #expect(order == ["seg-a", "seg-b", "seg-c"])
        #expect(askCitationNumber(of: "seg-c", sourceOrder: order) == 3)
        #expect(askCitationNumber(of: "seg-x", sourceOrder: order) == nil)

        // Relevance put seg-c first, but its prompt number stays [3].
        let chunks = [
            AskRetriever.RetrievedChunk(segmentId: "seg-c", text: "gamma", score: 9),
            AskRetriever.RetrievedChunk(segmentId: "seg-a", text: "alpha"),
        ]
        let prompt = AskRetriever().formatForPrompt(chunks) {
            askCitationNumber(of: $0, sourceOrder: order)
        }
        #expect(prompt.contains("[3] [segment seg-c]"))
        #expect(prompt.contains("[1] [segment seg-a]"))
    }

    // MARK: Gap summary (anti-B7)

    private func lossGap(frames: UInt32) -> GapMeta {
        GapMeta(
            firstMissingSequence: 100, missingFrameCount: frames,
            firstMissingSampleIndex: 32_000, origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.transportReset.rawValue))
    }

    private func silenceGap(frames: UInt32) -> GapMeta {
        GapMeta(
            firstMissingSequence: 500, missingFrameCount: frames,
            firstMissingSampleIndex: 160_000, origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue))
    }

    @Test func gapSummaryCountsOnlyVisibleLossNeverSilence() {
        // 100 frames * 20 ms = 2000 ms of real loss + a big silence-suppressed span.
        let meta = makeIntelligenceSegment(
            id: "seg-1", startTimeMs: 1_000, transcribed: true,
            gaps: [lossGap(frames: 100), silenceGap(frames: 9_000)])
        #expect(
            askGapSummary(meta)
                == "1 gap, about 2000ms missing; answer may be incomplete for this segment.")
    }

    @Test func gapSummaryIsNilWhenOnlySilenceWasSkipped() {
        let meta = makeIntelligenceSegment(
            id: "seg-1", startTimeMs: 1_000, transcribed: true,
            gaps: [silenceGap(frames: 9_000)])
        #expect(askGapSummary(meta) == nil)
        #expect(askGapSummary(
            makeIntelligenceSegment(id: "seg-2", startTimeMs: 1_000, transcribed: true)) == nil)
    }

    @Test func sequenceSkipCoveredBySilenceGapIsNotLoss() {
        // A receiver-synthesized skip inside the watch's silence record renders as quiet.
        let covered = GapMeta(
            firstMissingSequence: 600, missingFrameCount: 50,
            firstMissingSampleIndex: 192_000, origin: GapMeta.originSequenceSkip)
        let standalone = GapMeta(
            firstMissingSequence: 20_000, missingFrameCount: 25,
            firstMissingSampleIndex: 6_400_000, origin: GapMeta.originSequenceSkip)
        let meta = makeIntelligenceSegment(
            id: "seg-1", startTimeMs: 1_000, transcribed: true,
            gaps: [silenceGap(frames: 9_000), covered, standalone])
        // Only the standalone skip (25 frames = 500 ms) counts.
        #expect(
            askGapSummary(meta)
                == "1 gap, about 500ms missing; answer may be incomplete for this segment.")
    }

    // MARK: Scope resolution (Part 6.6)

    @Test func scopeResolutionFiltersByLogicalDayInRecordedZone() {
        let now = atUtc(2026, 8, 30, 12, 0)  // today = 2026-08-30 (UTC)
        let metas = [
            makeIntelligenceSegment(id: "today", startTimeMs: atUtc(2026, 8, 30, 9, 0), transcribed: true),
            // 01:30 on Aug 30 belongs to the Aug 29 logical day (5 AM boundary).
            makeIntelligenceSegment(id: "late-night", startTimeMs: atUtc(2026, 8, 30, 1, 30), transcribed: true),
            makeIntelligenceSegment(id: "yesterday", startTimeMs: atUtc(2026, 8, 29, 9, 0), transcribed: true),
            makeIntelligenceSegment(id: "last-week", startTimeMs: atUtc(2026, 8, 24, 9, 0), transcribed: true),
            makeIntelligenceSegment(id: "ancient", startTimeMs: atUtc(2026, 7, 1, 9, 0), transcribed: true),
            // 20:00 UTC Aug 29 = 05:00 Aug 30 in Tokyo ⇒ counts as today via its recorded zone.
            makeIntelligenceSegment(
                id: "tokyo-today", startTimeMs: atUtc(2026, 8, 29, 20, 0), transcribed: true,
                recordedTimeZone: "Asia/Tokyo"),
        ]
        func ids(_ scope: AskScope) -> [String] {
            segmentsInAskScope(metas, scope: scope, nowMs: now, fallbackTimeZoneID: "UTC")
                .map(\.segmentId)
        }
        #expect(ids(.today) == ["today", "tokyo-today"])
        #expect(ids(.yesterday) == ["late-night", "yesterday"])
        #expect(ids(.lastSevenDays) == ["today", "late-night", "yesterday", "last-week", "tokyo-today"])
        #expect(ids(.everything) == metas.map(\.segmentId))
        #expect(ids(.dateRange(startKey: "2026-07-01", endKey: "2026-08-24")) == ["last-week", "ancient"])
    }

    @Test func scopeDisplayNamesMatchThePickerCopy() {
        #expect(AskScope.today.displayName == "Today")
        #expect(AskScope.yesterday.displayName == "Yesterday")
        #expect(AskScope.lastSevenDays.displayName == "Last 7 days")
        #expect(AskScope.everything.displayName == "Everything")
        #expect(
            AskScope.dateRange(startKey: "2026-08-01", endKey: "2026-08-05").displayName
                == "2026-08-01 – 2026-08-05")
    }

    // MARK: Ask history (Q18)

    @Test func savedAnswersPersistWithFirstAppearanceCitationNumbers() async throws {
        let db = try AppDatabase.inMemory()
        let history = AskHistoryStore(db: db)
        let entry = try await saveAskAnswer(
            question: "Where are we going?",
            answerText: "Brazil, then Atlanta.",
            citedSegmentIds: ["seg-b", "seg-a"],
            scope: .lastSevenDays,
            history: history,
            nowMs: 1_000)

        let recent = try await history.recent()
        #expect(recent == [entry])
        #expect(recent[0].citations == [
            AskCitation(segmentId: "seg-b", number: 1),
            AskCitation(segmentId: "seg-a", number: 2),
        ])
        #expect(recent[0].scopeDescription == "Last 7 days")
        // An opening question is its own thread; that id is what follow-ups join.
        #expect(recent[0].threadId == recent[0].id)
    }

    /// A follow-up joins the thread it was asked in, and Recent hands the whole conversation
    /// back — that is what makes reopening one restore all of it.
    @Test func followUpsJoinTheirThreadAndReopenTogether() async throws {
        let db = try AppDatabase.inMemory()
        let history = AskHistoryStore(db: db)
        let opening = try await saveAskAnswer(
            question: "What's the plan?", answerText: "Saigon, then Bangkok.",
            citedSegmentIds: [], scope: .today, history: history, nowMs: 1_000)
        let followUp = try await saveAskAnswer(
            question: "When do I leave?", answerText: "Tomorrow or early in the week.",
            citedSegmentIds: [], scope: .today, history: history,
            threadId: opening.threadId, nowMs: 2_000)
        // An unrelated question, asked later, is a separate conversation.
        let other = try await saveAskAnswer(
            question: "Did anything break at home?", answerText: "The hallway light.",
            citedSegmentIds: [], scope: .everything, history: history, nowMs: 3_000)

        #expect(followUp.threadId == opening.threadId)
        let threads = try await history.recentThreads()
        #expect(threads.count == 2)
        // Newest conversation first; turns oldest-first, the order they were had.
        #expect(threads[0].id == other.threadId)
        #expect(threads[1].turns.map(\.question) == ["What's the plan?", "When do I leave?"])
        #expect(threads[1].openingQuestion == "What's the plan?")
        #expect(threads[1].updatedAtMs == 2_000)
    }

    /// Trimming by row would decapitate a long conversation and leave its follow-ups behind
    /// as orphaned fragments, so the window is counted in THREADS.
    @Test func historyTrimsWholeConversationsNeverMidThread() async throws {
        let db = try AppDatabase.inMemory()
        let history = AskHistoryStore(db: db)
        let long = try await saveAskAnswer(
            question: "q0", answerText: "a0", citedSegmentIds: [], scope: .today,
            history: history, nowMs: 1_000)
        for turn in 1...4 {
            try await saveAskAnswer(
                question: "q\(turn)", answerText: "a\(turn)", citedSegmentIds: [],
                scope: .today, history: history, threadId: long.threadId,
                nowMs: Int64(1_000 + turn))
        }
        // Four more conversations fill the window; a fifth pushes the long one out whole.
        for other in 1...4 {
            try await saveAskAnswer(
                question: "other\(other)", answerText: "a", citedSegmentIds: [],
                scope: .today, history: history, nowMs: Int64(2_000 + other))
        }
        var threads = try await history.recentThreads()
        #expect(threads.count == AskHistoryStore.maxEntries)
        // All five turns of the long conversation survived alongside the four others.
        #expect(threads.first { $0.id == long.threadId }?.turns.count == 5)

        try await saveAskAnswer(
            question: "newest", answerText: "a", citedSegmentIds: [], scope: .today,
            history: history, nowMs: 3_000)
        threads = try await history.recentThreads()
        #expect(threads.count == AskHistoryStore.maxEntries)
        #expect(!threads.contains { $0.id == long.threadId })
        // And it left nothing behind: no orphaned turns from the evicted conversation.
        let remaining = try await history.recent(limit: 100)
        #expect(!remaining.contains { $0.threadId == long.threadId })
    }
}
