import Foundation
import Testing

@testable import Intelligence

// The second relevance signal, and the rule that makes it safe.
//
// Ask drops batches only past the sweep ceiling, and until now on keyword evidence alone. The
// semantic signal is allowed in under one product rule: it may rescue a conversation, never
// cost one. `.keywordFirst` is that rule; these tests are its proof — and, first, the proof that
// the whole-corpus and sweep paths did not move at all.

@Suite("Ask recall policy")
struct AskRecallPolicyTests {
    /// `count` stretches of `chars` each, one per conversation, in recording order.
    private func stretches(count: Int, chars: Int = 1_000) -> [CitableExcerpt] {
        (0..<count).map { index in
            CitableExcerpt(
                number: index + 1,
                segmentId: "seg-\(index)",
                startMs: Int64(index) * 60_000,
                endMs: Int64(index) * 60_000 + 30_000,
                text: String(repeating: "a", count: chars))
        }
    }

    /// The planner as it was before the semantic signal existed, verbatim: pack, then past the
    /// ceiling rank by (sum + best) keyword score with a newest-first tie-break. The reference
    /// the new planner is held to.
    private func legacyPlan(
        stretches: [CitableExcerpt], budget: AskBudget, relevance: (String) -> Double
    ) -> [[CitableExcerpt]] {
        guard !stretches.isEmpty, budget.transcriptChars > 0 else { return [] }
        var batches = AskCorpusPlanner.pack(stretches, limit: budget.transcriptChars)
        func score(_ batch: [CitableExcerpt]) -> Double {
            var seen = Set<String>()
            var total = 0.0
            var best = 0.0
            for stretch in batch where seen.insert(stretch.segmentId).inserted {
                let value = relevance(stretch.segmentId)
                total += value
                best = max(best, value)
            }
            return total + best
        }
        if batches.count > budget.maxBatches {
            let ranked = batches.enumerated()
                .sorted { lhs, rhs in
                    let l = score(lhs.element)
                    let r = score(rhs.element)
                    if l != r { return l > r }
                    return lhs.offset > rhs.offset
                }
                .prefix(budget.maxBatches)
                .map(\.offset)
                .sorted()
            batches = ranked.map { batches[$0] }
        }
        return batches
    }

    /// A deterministic pseudo-random keyword score per segment, seeded so a failure is
    /// reproducible. Many segments score zero, as in a real FTS result.
    private func syntheticKeyword(seed: Int) -> (String) -> Double {
        { id in
            let n = (id.hashValue &* 31 &+ seed).magnitude % 17
            return n < 10 ? 0 : Double(n) * 0.5
        }
    }

    private func syntheticSemantic(seed: Int) -> (String) -> Double {
        { id in
            let n = (id.hashValue &* 17 &+ seed).magnitude % 13
            return n < 8 ? 0 : Double(13 - n) / 13
        }
    }

    // MARK: - Nothing outside the drop stage moved

    /// When the scope fits, or sweeps inside the ceiling, the plan is the packing and nothing
    /// else — with any relevance, any semantic scores, either policy. This is the guarantee the
    /// memory note calls load-bearing: a scope that fits is read whole.
    @Test func belowTheCeilingThePlanIsIdenticalToBeforeUnderEveryPolicy() {
        // (count, chars, limit, ceiling); nil ceiling = exactly the number of packed batches.
        for (count, chars, limit, ceiling) in [
            (200, 1_000, 10_000_000, 12),  // fits in one pass
            (100, 1_000, 30_000, 12),  // sweeps in a few batches
            (100, 1_000, 10_000, nil),  // exactly at the ceiling
        ] as [(Int, Int, Int, Int?)] {
            let all = stretches(count: count, chars: chars)
            let packed = AskCorpusPlanner.pack(all, limit: limit).count
            let maxBatches = ceiling ?? packed
            #expect(packed <= maxBatches, "fixture must not drop")
            let budget = AskBudget(transcriptChars: limit, maxBatches: maxBatches)
            let reference = legacyPlan(
                stretches: all, budget: budget, relevance: syntheticKeyword(seed: 1))
            for policy in AskRecallPolicy.allCases {
                let plan = AskCorpusPlanner.plan(
                    stretches: all, budget: budget,
                    relevance: {
                        AskRelevance(
                            keyword: -1_000,  // hates everything
                            semantic: syntheticSemantic(seed: 7)($0))
                    },
                    policy: policy)
                #expect(plan.batches == reference)
                #expect(plan.batches == AskCorpusPlanner.pack(all, limit: limit))
                #expect(plan.coverage.isComplete)
                #expect(plan.packedBatches == plan.batches.count)
            }
        }
    }

    /// Past the ceiling, with no semantic evidence, `.keywordFirst` IS the old planner: the
    /// same batches, in the same order, for many seeds and shapes.
    @Test func withoutSemanticEvidenceKeywordFirstIsByteForByteTheOldRanking() {
        for seed in 0..<40 {
            let count = 60 + seed * 3
            let all = stretches(count: count, chars: 900 + seed * 10)
            let budget = AskBudget(transcriptChars: 6_000, maxBatches: 2 + seed % 5)
            let keyword = syntheticKeyword(seed: seed)
            let reference = legacyPlan(stretches: all, budget: budget, relevance: keyword)
            let viaLegacyOverload = AskCorpusPlanner.plan(
                stretches: all, budget: budget, relevance: keyword)
            let viaTwoSignal = AskCorpusPlanner.plan(
                stretches: all, budget: budget,
                relevance: { AskRelevance(keyword: keyword($0)) }, policy: .keywordFirst)
            #expect(viaLegacyOverload.batches == reference, "seed \(seed)")
            #expect(viaTwoSignal.batches == reference, "seed \(seed)")
            #expect(viaTwoSignal.packedBatches > viaTwoSignal.batches.count, "seed \(seed) drops")
        }
    }

    // MARK: - keywordFirst: additive, never worse

    /// The case the signal exists for: keyword found nothing anywhere (a paraphrase, a topic
    /// named differently in the room), so every batch is keyword-equal and the old planner kept
    /// the newest. A batch only semantic vouches for is now kept — ahead of recency.
    @Test func aSemanticOnlyBatchIsKeptAmongKeywordEqualBatches() {
        let all = stretches(count: 100, chars: 1_000)
        // 10 batches of 10; the semantic hit is in the OLDEST batch, which recency alone would
        // drop first.
        let plan = AskCorpusPlanner.plan(
            stretches: all,
            budget: AskBudget(transcriptChars: 10_000, maxBatches: 2),
            relevance: { AskRelevance(keyword: 0, semantic: $0 == "seg-3" ? 0.8 : 0) },
            policy: .keywordFirst)
        #expect(plan.batches.count == 2)
        #expect(plan.stretches.contains { $0.segmentId == "seg-3" })
        // The other slot still goes to recency.
        #expect(plan.stretches.contains { $0.segmentId == "seg-99" })
        #expect(!plan.coverage.isComplete)
    }

    /// The safety property, directly: a batch with keyword evidence that would be kept today
    /// is kept whatever semantic says about every other batch — semantic cannot buy a
    /// keyword-less batch a slot at its expense.
    @Test func aKeywordKeptBatchIsNeverDisplacedUnderKeywordFirst() {
        let all = stretches(count: 100, chars: 1_000)
        let budget = AskBudget(transcriptChars: 10_000, maxBatches: 3)
        // Keyword evidence in exactly two batches (fewer than the ceiling, so both are kept
        // today on keyword alone); semantic evidence, as strong as it can be, everywhere else.
        let keywordHits: Set<String> = ["seg-12", "seg-45"]
        let plan = AskCorpusPlanner.plan(
            stretches: all, budget: budget,
            relevance: { id in
                AskRelevance(
                    keyword: keywordHits.contains(id) ? 0.01 : 0,
                    semantic: keywordHits.contains(id) ? 0 : 1.0)
            },
            policy: .keywordFirst)
        let kept = Set(plan.stretches.map(\.segmentId))
        #expect(kept.isSuperset(of: keywordHits))
        #expect(plan.batches.count == 3)
    }

    /// The same property as an invariant over many random corpora: the multiset of KEYWORD
    /// scores of the kept batches is exactly what keyword-only ranking keeps. Semantic can only
    /// change WHICH of the equal-keyword batches fill the tail slots.
    @Test func keywordFirstKeepsExactlyTheKeywordOnlyScoreProfile() {
        for seed in 0..<40 {
            let all = stretches(count: 80 + seed, chars: 1_000)
            let budget = AskBudget(transcriptChars: 7_000, maxBatches: 3 + seed % 4)
            let keyword = syntheticKeyword(seed: seed)
            let semantic = syntheticSemantic(seed: seed + 100)
            let batches = AskCorpusPlanner.pack(all, limit: budget.transcriptChars)
            let scores = batches.map {
                AskCorpusPlanner.score($0) { AskRelevance(keyword: keyword($0), semantic: semantic($0)) }
            }
            let keywordOnly = AskCorpusPlanner.survivingBatches(
                scores: scores.map { AskRelevance(keyword: $0.keyword) },
                keep: budget.maxBatches, policy: .keywordFirst)
            let twoSignal = AskCorpusPlanner.survivingBatches(
                scores: scores, keep: budget.maxBatches, policy: .keywordFirst)
            #expect(
                keywordOnly.map { scores[$0].keyword }.sorted()
                    == twoSignal.map { scores[$0].keyword }.sorted(),
                "seed \(seed)")
            // And every batch keyword strictly preferred (score above the cut) is in both.
            let cut = keywordOnly.map { scores[$0].keyword }.min() ?? 0
            for index in scores.indices where scores[index].keyword > cut {
                #expect(twoSignal.contains(index), "seed \(seed) batch \(index)")
            }
        }
    }

    @Test func amongEqualKeywordAndSemanticTheRecentBatchSurvives() {
        let kept = AskCorpusPlanner.survivingBatches(
            scores: Array(repeating: AskRelevance(keyword: 1, semantic: 0.5), count: 6),
            keep: 2, policy: .keywordFirst)
        #expect(kept == [4, 5])
    }

    // MARK: - blended: the comparison policy

    /// Under `.blended` a batch only semantic vouches for CAN displace a weak keyword batch —
    /// which is exactly why it is not the default, and exactly what the replay compares.
    @Test func blendedLetsAStrongSemanticBatchOutrankAWeakKeywordBatch() {
        let scores = [
            AskRelevance(keyword: 1.0, semantic: 0),  // the keyword best
            AskRelevance(keyword: 0.2, semantic: 0),  // weak keyword
            AskRelevance(keyword: 0, semantic: 1.0),  // semantic only
        ]
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 2, policy: .keywordFirst)
                == [0, 1])
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 2, policy: .blended)
                == [0, 2])
    }

    /// Each signal is normalised to its own best batch, so the bm25 scale (tens) cannot swamp
    /// the rank fraction (at most one).
    @Test func blendedNormalisesEachSignalToItsOwnBest() {
        let scores = [
            AskRelevance(keyword: 40, semantic: 0),  // 1.0 blended
            AskRelevance(keyword: 10, semantic: 0),  // 0.25
            AskRelevance(keyword: 0, semantic: 0.5),  // 0.5 → beats the 0.25
            AskRelevance(keyword: 0, semantic: 1.0),  // 1.0
        ]
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 3, policy: .blended)
                == [0, 2, 3])
    }

    /// With no evidence at all both policies fall back to recency, as before.
    @Test func withNoEvidenceEitherPolicyKeepsTheRecentBatches() {
        let scores = Array(repeating: AskRelevance.none, count: 5)
        for policy in AskRecallPolicy.allCases {
            #expect(
                AskCorpusPlanner.survivingBatches(scores: scores, keep: 2, policy: policy)
                    == [3, 4])
        }
    }

    @Test func aTieOnBlendedScoreGoesToKeywordEvidenceThenRecency() {
        let scores = [
            AskRelevance(keyword: 0, semantic: 1.0),
            AskRelevance(keyword: 5, semantic: 0),
        ]
        // Both blend to 1.0; keyword evidence wins.
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 1, policy: .blended) == [1])
    }

    // MARK: - Shape

    @Test func survivingBatchesKeepsEverythingAtOrBelowTheCeilingAndNothingForZero() {
        let scores = [AskRelevance(keyword: 1), AskRelevance(keyword: 2)]
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 2, policy: .keywordFirst)
                == [0, 1])
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 5, policy: .blended)
                == [0, 1])
        #expect(
            AskCorpusPlanner.survivingBatches(scores: scores, keep: 0, policy: .keywordFirst)
                == [])
    }

    /// The plan says how many batches the scope packed into, so the experiment can report
    /// what was sacrificed without repacking.
    @Test func thePlanReportsHowManyBatchesWerePackedBeforeTheDrop() {
        let all = stretches(count: 100, chars: 1_000)
        let plan = AskCorpusPlanner.plan(
            stretches: all,
            budget: AskBudget(transcriptChars: 10_000, maxBatches: 2),
            relevance: { _ in .none }, policy: .keywordFirst)
        let packed = AskCorpusPlanner.pack(all, limit: 10_000).count
        #expect(packed > 2, "fixture must drop")
        #expect(plan.packedBatches == packed)
        #expect(plan.batches.count == 2)
        // Never claims fewer packed than kept.
        #expect(AskCorpusPlan(batches: [[]], coverage: plan.coverage, packedBatches: 0)
            .packedBatches == 1)
    }

    /// A batch's score is (sum + best) on EACH signal, never a mix of the two.
    @Test func batchScoresKeepTheSignalsApart() {
        let batch = stretches(count: 3)
        let score = AskCorpusPlanner.score(batch) { id in
            AskRelevance(keyword: id == "seg-1" ? 2 : 1, semantic: id == "seg-2" ? 0.5 : 0)
        }
        #expect(score.keyword == 4 + 2)
        #expect(score.semantic == 0.5 + 0.5)
    }
}
