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

    @Test func retrieveOrdersIndexHitsFirstThenStuffsRemainderUpToCap() async {
        let excerpts = (1...15).map {
            TranscriptExcerpt(segmentId: "seg-\($0)", text: "text \($0)")
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
        // The remainder stuffs non-hit excerpts in source order up to the cap.
        #expect(chunks[2].segmentId == "seg-1")
        #expect(!chunks.dropFirst(2).contains { $0.segmentId == "seg-9" || $0.segmentId == "seg-3" })
    }

    @Test func retrieveWithoutIndexStuffsExcerptsInOrder() async {
        let excerpts = ["a", "b", "c"].map { TranscriptExcerpt(segmentId: "seg-\($0)", text: $0) }
        let chunks = await AskRetriever().retrieve(query: "q", excerpts: excerpts)
        #expect(chunks.map(\.segmentId) == ["seg-a", "seg-b", "seg-c"])
        #expect(chunks.allSatisfy { $0.score == 0 })
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
    }
}
