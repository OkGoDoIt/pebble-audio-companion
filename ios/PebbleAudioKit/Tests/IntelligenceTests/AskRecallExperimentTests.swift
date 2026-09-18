import Foundation
import Testing

@testable import Intelligence

// The measured half: two index passes → per-segment scores → one honest record.

@Suite("Ask recall signals")
struct AskRecallSignalsTests {
    private let members = [
        "conv-a": ["seg-1", "seg-2"],
        "conv-b": ["seg-3"],
        "conv-c": ["seg-4", "seg-5"],
    ]
    private var scope: Set<String> { ["seg-1", "seg-2", "seg-3", "seg-4", "seg-5"] }

    /// Both indexes key on CONVERSATION ids; a hit lands on every member segment — comparing
    /// the two namespaces directly is what once silently disabled retrieval entirely.
    @Test func hitsExpandToMemberSegmentsOnEachSignalIndependently() {
        let signals = AskRecallSignals.resolve(
            keyword: [AskIndexHit(id: "conv-a", score: 3)],
            semantic: [AskIndexHit(id: "conv-b", score: 1), AskIndexHit(id: "conv-a", score: 0.5)],
            members: members, scope: scope)
        #expect(signals.scores["seg-1"] == AskRelevance(keyword: 3, semantic: 0.5))
        #expect(signals.scores["seg-2"] == AskRelevance(keyword: 3, semantic: 0.5))
        #expect(signals.scores["seg-3"] == AskRelevance(keyword: 0, semantic: 1))
        #expect(signals.scores["seg-4"] == nil)
        #expect(signals.relevance("seg-4") == .none)
        #expect(signals.keywordConversations == ["conv-a"])
        #expect(signals.semanticConversations == ["conv-a", "conv-b"])
    }

    /// Neither index is date-scoped: a hit on a conversation outside the question's scope
    /// resolves to nothing and must not be counted as evidence found.
    @Test func hitsOutsideTheScopeAreNeitherScoredNorCounted() {
        let signals = AskRecallSignals.resolve(
            keyword: [AskIndexHit(id: "conv-c", score: 9), AskIndexHit(id: "conv-zzz", score: 9)],
            semantic: [AskIndexHit(id: "conv-c", score: 1)],
            members: members, scope: ["seg-1", "seg-2", "seg-3"])
        #expect(signals.scores.isEmpty)
        #expect(signals.keywordConversations.isEmpty)
        #expect(signals.semanticConversations.isEmpty)
    }

    /// The first hit for a segment wins, on each signal, as the retriever has always done.
    @Test func theFirstHitForASegmentWins() {
        let signals = AskRecallSignals.resolve(
            keyword: [AskIndexHit(id: "conv-a", score: 3), AskIndexHit(id: "conv-a", score: 1)],
            semantic: [],
            members: members, scope: scope)
        #expect(signals.scores["seg-1"]?.keyword == 3)
    }

    /// An index that keys on segment ids (no members map) still works: the id is the segment.
    @Test func anUnknownIdIsTakenAsASegmentId() {
        let signals = AskRecallSignals.resolve(
            keyword: [AskIndexHit(id: "seg-9", score: 2)], semantic: [],
            members: [:], scope: ["seg-9"])
        #expect(signals.scores["seg-9"]?.keyword == 2)
        #expect(signals.keywordConversations == ["seg-9"])
    }
}

@Suite("Ask recall experiment")
struct AskRecallExperimentTests {
    private func stretch(_ number: Int, _ segmentId: String) -> CitableExcerpt {
        CitableExcerpt(
            number: number, segmentId: segmentId, startMs: Int64(number) * 1_000,
            endMs: Int64(number) * 1_000 + 500, text: "x")
    }

    /// The record counts CONVERSATIONS, and says exactly which the semantic pass rescued and
    /// which keyword evidence lost to the ceiling anyway.
    @Test func theRecordCountsRescuesAndLossesByConversation() {
        let members = [
            "conv-a": ["seg-1", "seg-2"],  // keyword only, kept
            "conv-b": ["seg-3"],  // both, kept
            "conv-c": ["seg-4"],  // semantic only, kept — the rescue
            "conv-d": ["seg-5"],  // keyword only, dropped
            "conv-e": ["seg-6"],  // semantic only, dropped
            "conv-f": ["seg-7"],  // no evidence, dropped
        ]
        let signals = AskRecallSignals(
            scores: [:],
            keywordConversations: ["conv-a", "conv-b", "conv-d"],
            semanticConversations: ["conv-b", "conv-c", "conv-e"])
        let plan = AskCorpusPlan(
            batches: [[stretch(1, "seg-1"), stretch(3, "seg-3")], [stretch(4, "seg-4")]],
            coverage: AskCoverage(conversationsRead: 3, conversationsInScope: 7, passes: 2),
            packedBatches: 5)
        let record = AskRecallExperiment.measure(
            atMs: 1_000, question: "  Did the plumber ever quote for the boiler?  ",
            signals: signals, members: members,
            keptSegmentIds: Set(plan.stretches.map(\.segmentId)), plan: plan,
            policy: .keywordFirst, ms: 42, semanticRan: true)

        #expect(record.question == "Did the plumber ever quote for the boiler?")
        #expect(record.scopeConversations == 6)
        #expect(record.packedBatches == 5)
        #expect(record.keptBatches == 2)
        #expect(record.keyword == 3)
        #expect(record.semantic == 3)
        #expect(record.both == 1)
        #expect(record.semanticOnlyKept == 1)
        #expect(record.keywordOnlyDropped == 1)
        #expect(
            record.logLine
                == "ask recall: scope=6 batches=5 kept=2 fts=3 semantic=3 both=1 "
                + "semantic-only-kept=1 fts-only-dropped=1 policy=keywordFirst ms=42 "
                + "semantic-ran=true")
    }

    /// A conversation is kept when ANY of its segments is — a batch boundary can split one.
    @Test func aConversationIsKeptWhenAnyMemberIs() {
        let members = ["conv-a": ["seg-1", "seg-2"]]
        let plan = AskCorpusPlan(
            batches: [[stretch(2, "seg-2")]],
            coverage: AskCoverage(conversationsRead: 1, conversationsInScope: 2, passes: 1),
            packedBatches: 2)
        let record = AskRecallExperiment.measure(
            atMs: 0, question: "q",
            signals: AskRecallSignals(
                scores: [:], keywordConversations: [], semanticConversations: ["conv-a"]),
            members: members, keptSegmentIds: ["seg-2"], plan: plan,
            policy: .keywordFirst, ms: 0, semanticRan: true)
        #expect(record.semanticOnlyKept == 1)
    }

    /// The question is the user's own words, clipped so a record stays one line — and the
    /// log line never carries it at all.
    @Test func theQuestionIsClippedAndKeptOutOfTheLogLine() {
        let long = String(repeating: "why ", count: 60)
        let record = AskRecallExperiment.measure(
            atMs: 0, question: long,
            signals: AskRecallSignals(
                scores: [:], keywordConversations: [], semanticConversations: []),
            members: [:], keptSegmentIds: [], plan: AskCorpusPlan(
                batches: [], coverage: AskCoverage(
                    conversationsRead: 0, conversationsInScope: 0, passes: 1)),
            policy: .blended, ms: 1, semanticRan: false)
        #expect(record.question.count == AskRecallRecord.maxQuestionChars)
        #expect(record.question.hasSuffix("…"))
        #expect(!record.logLine.contains("why"))
        #expect(record.logLine.hasSuffix("policy=blended ms=1 semantic-ran=false"))
    }
}

@Suite("Ask recall ledger")
struct AskRecallLedgerTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "AskRecallLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func record(_ n: Int) -> AskRecallRecord {
        AskRecallRecord(
            atMs: Int64(n), question: "q\(n)", scopeConversations: n, packedBatches: n,
            keptBatches: 1, keyword: 0, semantic: 0, both: 0, semanticOnlyKept: 0,
            keywordOnlyDropped: 0, policy: .keywordFirst, ms: 0, semanticRan: true)
    }

    @Test func recordsRoundTripNewestFirstAndAreCappedAtTheCapacity() {
        let defaults = freshDefaults()
        let ledger = AskRecallLedger(defaults: defaults, capacity: 3)
        #expect(ledger.records().isEmpty)
        for n in 1...5 { ledger.append(record(n)) }
        #expect(ledger.records().map(\.atMs) == [5, 4, 3])
        // A second ledger over the same suite reads the same records — it is the defaults
        // that hold them, not the object.
        #expect(AskRecallLedger(defaults: defaults, capacity: 3).records().map(\.atMs) == [5, 4, 3])
        ledger.clear()
        #expect(ledger.records().isEmpty)
    }

    @Test func aCorruptBlobReadsAsEmptyRatherThanThrowing() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: AskRecallLedger.defaultKey)
        #expect(AskRecallLedger(defaults: defaults).records().isEmpty)
    }
}

@Suite("Ask retriever recall")
struct AskRetrieverRecallTests {
    /// Both passes run and both results come back, tagged with whether semantic ran.
    @Test func recallRunsBothPassesConcurrentlyAndReportsWhetherSemanticRan() async {
        let retriever = AskRetriever(
            search: { _, _ in [AskIndexHit(id: "conv-k", score: 2)] },
            semantic: { _, limit in [AskIndexHit(id: "conv-s", score: Float(limit))] })
        #expect(retriever.hasSemanticRecall)
        let hits = await retriever.recall(query: "boiler", limit: 7)
        #expect(hits.keyword == [AskIndexHit(id: "conv-k", score: 2)])
        #expect(hits.semantic == [AskIndexHit(id: "conv-s", score: 7)])
        #expect(hits.semanticRan)

        let keywordOnly = await retriever.recall(query: "boiler", limit: 7, includeSemantic: false)
        #expect(keywordOnly.semantic.isEmpty)
        #expect(!keywordOnly.semanticRan)
    }

    /// A retriever built the old way has no semantic pass and says so; `retrieve` is untouched.
    @Test func withoutASemanticPassRecallIsKeywordOnly() async {
        let retriever = AskRetriever(search: { _, _ in [AskIndexHit(id: "conv-k", score: 1)] })
        #expect(!retriever.hasSemanticRecall)
        let hits = await retriever.recall(query: "boiler", limit: 3)
        #expect(hits.keyword.count == 1)
        #expect(hits.semantic.isEmpty)
        #expect(!hits.semanticRan)
    }

    /// The two passes overlap in time: the slow one bounds the wait, not their sum.
    @Test func theTwoPassesOverlap() async {
        let retriever = AskRetriever(
            search: { _, _ in
                try? await Task.sleep(for: .milliseconds(150))
                return []
            },
            semantic: { _, _ in
                try? await Task.sleep(for: .milliseconds(150))
                return []
            })
        let started = ContinuousClock.now
        _ = await retriever.recall(query: "q", limit: 1)
        #expect(ContinuousClock.now - started < .milliseconds(280))
    }
}
