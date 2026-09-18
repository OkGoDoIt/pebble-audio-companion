import Foundation
import Intelligence
import SearchKit
import Testing

// Ask's recall experiment, app side: the glue from a semantic index to the planner's two
// signals, the record the Diagnostics screen shows, and the DEBUG replay.

/// A `SemanticRecall` that answers from a canned ranking — the shape `CoreSpotlightSemanticRecall`
/// has, without an OS index.
private struct FakeSemanticRecall: SemanticRecall {
    let ranked: [String]
    func rank(query: String, limit: Int) async -> [SemanticRecallHit] {
        SpotlightSemanticQuery.hits(
            rankedUniqueIdentifiers: ranked.map { "conversation:\($0)" }, limit: limit)
    }
}

@Suite("ask recall check") @MainActor
struct AskRecallCheckTests {

    // MARK: - From the semantic index to the log line

    /// The composition wires a `SemanticRecall` into the retriever's `semantic` slot exactly
    /// like this; from there the kit resolves both passes to in-scope segments, the planner
    /// ranks, and the experiment records the union and the overlap. One question, end to end,
    /// with the OS index replaced by a fake.
    @Test func aSemanticIndexFeedsTheSecondSignalAndTheRecordSaysWhatItAdded() async {
        let semantic = FakeSemanticRecall(ranked: ["conv-b", "conv-c"])
        let retriever = AskRetriever(
            search: { _, _ in [AskIndexHit(id: "conv-a", score: 4), AskIndexHit(id: "conv-b", score: 2)] },
            semantic: { query, limit in
                await semantic.rank(query: query, limit: min(limit, 200))
                    .map { AskIndexHit(id: $0.id, score: Float($0.score)) }
            })
        let members = ["conv-a": ["seg-1"], "conv-b": ["seg-2"], "conv-c": ["seg-3"]]
        let scope: Set<String> = ["seg-1", "seg-2", "seg-3"]

        let hits = await retriever.recall(query: "did the plumber quote?", limit: 6)
        #expect(hits.semanticRan)
        let signals = AskRecallSignals.resolve(
            keyword: hits.keyword, semantic: hits.semantic, members: members, scope: scope)
        #expect(signals.keywordConversations == ["conv-a", "conv-b"])
        #expect(signals.semanticConversations == ["conv-b", "conv-c"])
        // Rank 1 of a limit of 6, through the retriever's `Float` score.
        #expect(
            signals.scores["seg-3"]
                == AskRelevance(keyword: 0, semantic: Double(Float(5.0 / 6.0))))

        // Three one-segment batches; room for two. Keyword keeps a and b; c is the batch only
        // meaning vouched for, and under keywordFirst it cannot displace either.
        let stretches = ["seg-1", "seg-2", "seg-3"].enumerated().map { index, id in
            CitableExcerpt(
                number: index + 1, segmentId: id, startMs: Int64(index) * 1_000,
                endMs: Int64(index) * 1_000 + 500, text: String(repeating: "x", count: 900))
        }
        let plan = AskCorpusPlanner.plan(
            stretches: stretches, budget: AskBudget(transcriptChars: 1_000, maxBatches: 2),
            relevance: signals.relevance, policy: .keywordFirst)
        #expect(plan.stretches.map(\.segmentId) == ["seg-1", "seg-2"])

        let record = AskRecallExperiment.measure(
            atMs: 1, question: "did the plumber quote?", signals: signals, members: members,
            keptSegmentIds: Set(plan.stretches.map(\.segmentId)), plan: plan,
            policy: .keywordFirst, ms: 3, semanticRan: hits.semanticRan)
        #expect(
            record.logLine
                == "ask recall: scope=3 batches=3 kept=2 fts=2 semantic=2 both=1 "
                + "semantic-only-kept=0 fts-only-dropped=0 policy=keywordFirst ms=3 "
                + "semantic-ran=true")

        // With the setting off the semantic slot is not consulted, and the record says so.
        let off = await retriever.recall(query: "q", limit: 6, includeSemantic: false)
        #expect(off.semantic.isEmpty && !off.semanticRan)
    }

    // MARK: - The Diagnostics rows

    @Test func aLedgerRecordBecomesAReadableRow() {
        let atMs = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = LiveDiagnosticsSource.recallRows([
            AskRecallRecord(
                atMs: atMs, question: "Did the plumber ever quote for the boiler?",
                scopeConversations: 40, packedBatches: 31, keptBatches: 12, keyword: 9,
                semantic: 7, both: 4, semanticOnlyKept: 2, keywordOnlyDropped: 1,
                policy: .keywordFirst, ms: 120, semanticRan: true)
        ])
        #expect(rows.count == 1)
        #expect(rows[0].question == "Did the plumber ever quote for the boiler?")
        #expect(rows[0].when.hasPrefix("Today · "))
        #expect(
            rows[0].detail
                == "read 12 of 31 parts · keyword 9 · meaning 7 · both 4 · 2 rescued "
                + "· 1 keyword match lost")
    }

    /// When the semantic pass did not run, the row says "off" — never "meaning 0", which
    /// would read as the index having looked and found nothing.
    @Test func aRecordWithoutASemanticPassSaysSoRatherThanShowingZero() {
        let detail = Copy.Settings.Diagnostics.AskRecall.recordDetail(
            keptBatches: 3, packedBatches: 9, keyword: 5, semantic: 0, both: 0, rescued: 0,
            lost: 0, semanticRan: false)
        #expect(detail == "read 3 of 9 parts · keyword 5 · meaning off")
        #expect(!detail.contains("meaning 0"))
    }

    // MARK: - The replay

    @Test func theReplayReportsUnionOverlapAndNamesEachSidesExclusiveFinds() async {
        let rows = await AskRecallReplay.run(
            questions: ["  ", "Did the plumber quote?", "What about the ferry?"],
            limit: 10,
            recall: { question, _ in
                if question.hasPrefix("Did") {
                    return AskRetriever.RecallHits(
                        keyword: ["a", "b", "c"].map { AskIndexHit(id: $0, score: 1) },
                        semantic: ["b", "d", "e", "f", "g", "gone"].map { AskIndexHit(id: $0, score: 1) },
                        semanticRan: true)
                }
                return AskRetriever.RecallHits(
                    keyword: [AskIndexHit(id: "a", score: 1)], semantic: [], semanticRan: false)
            },
            title: { id in id == "gone" ? nil : "Title \(id)" })

        // The blank question is skipped, not replayed as an empty search.
        #expect(rows.count == 2)
        let plumber = rows[0]
        #expect(plumber.question == "Did the plumber quote?")
        #expect(plumber.keyword == 3 && plumber.semantic == 6 && plumber.both == 1)
        #expect(plumber.union == 8)
        // Named best-first, capped, and a hit on a conversation that no longer exists is not
        // named (it would otherwise be a blank).
        #expect(plumber.semanticOnlyTitles == ["Title d", "Title e", "Title f"])
        #expect(plumber.keywordOnlyTitles == ["Title a", "Title c"])
        #expect(plumber.semanticRan)

        let ferry = rows[1]
        #expect(ferry.keyword == 1 && ferry.semantic == 0 && !ferry.semanticRan)
        #expect(
            Copy.Settings.Diagnostics.AskRecall.replayDetail(
                keyword: 1, semantic: 0, both: 0, semanticRan: false)
                == "keyword 1 · meaning off")
        #expect(
            Copy.Settings.Diagnostics.AskRecall.replayDetail(
                keyword: 3, semantic: 6, both: 1, semanticRan: true)
                == "keyword 3 · meaning 6 · both 1 · together 8")
    }

    /// The mock world's replay: every recent mock question, with the mock's own
    /// conversations as findings, so previews and `-demo-data` show the row doing something.
    @Test func theMockReplayRunsEveryRecentQuestionOverTheMockWorld() async throws {
        let source = MockDiagnosticsSource()
        #expect(source.askRecallReplay == .idle)
        #expect(!source.askRecallRecords.isEmpty)
        await source.replayAskRecall()
        guard case .done(let rows) = source.askRecallReplay else {
            Issue.record("replay did not finish: \(source.askRecallReplay)")
            return
        }
        let questions = try await MockWorld.shared.recentThreads()
            .flatMap { $0.turns.map(\.question) }
        #expect(rows.map(\.question) == questions)
        #expect(!rows.isEmpty)
        // At least one question hits the mock library on both sides, with one find only
        // meaning made.
        #expect(rows.contains { $0.both > 0 && $0.semanticOnlyTitles == ["Coffee with Dana"] })
    }
}
