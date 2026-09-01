import Foundation
import Testing

@testable import Intelligence

// What Ask is allowed to read, and whether it admits when that was not everything.
//
// The behaviour these pin down replaced a retrieval step that shipped the same twelve
// recordings to the model for every question ever asked (see
// `retrieveMapsConversationHitsOntoTheirMemberSegments` in AskRetrieverTests for the cause).
// The load-bearing property here is not ranking quality — it is that a scope which FITS is read
// whole, so "nothing was recorded about that" is a fact rather than an artefact of sampling.

@Suite("Ask corpus budget")
struct AskBudgetTests {
    @Test func budgetIsTheModelsWindowLessRoomForThePromptAndTheAnswer() {
        let budget = AskBudget.forContext(tokens: 100_000)
        #expect(budget.transcriptChars == (100_000 - AskBudget.overheadTokens) * 3)
    }

    @Test func aModelWithNoRoomLeftBudgetsNothingRatherThanGoingNegative() {
        #expect(AskBudget.forContext(tokens: 1_000).transcriptChars == 0)
    }

    /// The provider that actually runs sets the ceiling. An on-device model holds a few
    /// thousand characters; planning a whole-archive read for it would have the provider
    /// truncate silently while the prompt still claimed to have been shown everything.
    @Test func aLocalFirstUserIsBudgetedForTheONDEVICEWindowNotTheCloudOne() {
        let remote = AskBudget.forMode(.remoteFirst, modelId: "gpt-5.6-luna").transcriptChars
        let local = AskBudget.forMode(.localFirst, modelId: "gpt-5.6-luna").transcriptChars
        let localOnly = AskBudget.forMode(.localOnly, modelId: "gpt-5.6-luna").transcriptChars
        #expect(local == localOnly)
        #expect(local < remote)
        #expect(local < OnDeviceAiProvider.defaultMaxInputChars)
        #expect(local > 0)
        #expect(AskBudget.forMode(.remoteOnly, modelId: "gpt-5.6-luna").transcriptChars == remote)
        // And it does not grind through a dozen slow on-device passes to reach a few percent
        // of a large archive.
        #expect(AskBudget.forMode(.localFirst, modelId: "gpt-5.6-luna").maxBatches
            == AskBudget.localSweepBatches)
        #expect(AskBudget.forMode(.remoteFirst, modelId: "gpt-5.6-luna").maxBatches
            == AskBudget.defaultMaxBatches)
    }

    /// The provider truncates anything over its own ceiling and says so in the text — which
    /// would flatly contradict a COVERAGE line claiming the whole range was shown. The planner's
    /// budget must therefore always sit BELOW what the provider will accept.
    @Test func theRemoteProvidersOwnCeilingSitsAboveWhatThePlannerWouldSend() {
        for id in AiModels.all.map(\.id) {
            let planned = AskBudget.forModel(id: id).transcriptChars
            let providerCeiling = AiModels.byId(id).contextTokens * AskBudget.charsPerToken
            #expect(planned < providerCeiling)
        }
    }

    @Test func theSelectedModelsWindowDrivesTheBudget() {
        let luna = AskBudget.forModel(id: "gpt-5.6-luna").transcriptChars
        let terra = AskBudget.forModel(id: "gpt-5.6-terra").transcriptChars
        #expect(luna > terra)
        // An id we do not know resolves to the model we would actually SEND, so the budget can
        // never exceed what the request will really be answered by.
        #expect(AskBudget.forModel(id: "no-such-model").transcriptChars == luna)
    }
}

@Suite("Ask coverage")
struct AskCoverageTests {
    @Test func completeCoverageLicensesTheModelToStateAnAbsence() {
        let coverage = AskCoverage(conversationsRead: 40, conversationsInScope: 40, passes: 1)
        #expect(coverage.isComplete)
        #expect(coverage.promptLine.contains("ALL 40 conversations"))
        #expect(coverage.promptLine.contains("you may say so plainly"))
        // Nothing to warn about, so the answer card stays quiet.
        #expect(coverage.displayNote == nil)
    }

    @Test func partialCoverageForbidsIt() {
        let coverage = AskCoverage(conversationsRead: 12, conversationsInScope: 510, passes: 12)
        #expect(!coverage.isComplete)
        #expect(coverage.conversationsSkipped == 498)
        #expect(coverage.promptLine.contains("12 of 510"))
        #expect(coverage.promptLine.contains("rather than claiming something is absent"))
        #expect(coverage.displayNote?.contains("12 of 510") == true)
    }

    @Test func coverageIsRecordedOnTheStoredScopeLine() {
        #expect(
            askScopeDescription(
                .everything,
                coverage: AskCoverage(
                    conversationsRead: 510, conversationsInScope: 510, passes: 1))
                == "Everything · 510 conversations read")
        #expect(
            askScopeDescription(
                .everything,
                coverage: AskCoverage(
                    conversationsRead: 60, conversationsInScope: 510, passes: 12))
                == "Everything · 60 of 510 conversations read")
        // Rows written before coverage was tracked keep the bare scope name.
        #expect(askScopeDescription(.today, coverage: nil) == "Today")
    }
}

@Suite("Ask corpus planner")
struct AskCorpusPlannerTests {
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

    @Test func aScopeThatFitsIsReadWHOLEInOnePassWithNoRetrievalAtAll() {
        let plan = AskCorpusPlanner.plan(
            stretches: stretches(count: 200),
            budget: AskBudget(transcriptChars: 10_000_000),
            // A relevance function that hates everything must not be able to drop a single
            // stretch while the scope still fits — that is the whole guarantee.
            relevance: { _ in -1_000 })
        #expect(plan.isSinglePass)
        #expect(plan.batches.count == 1)
        #expect(plan.stretches.count == 200)
        #expect(plan.coverage.isComplete)
        #expect(plan.coverage.conversationsRead == 200)
    }

    @Test func anOversizedScopeIsSweptInBatchesAndStillReadInFull() {
        let plan = AskCorpusPlanner.plan(
            stretches: stretches(count: 100, chars: 1_000),
            budget: AskBudget(transcriptChars: 30_000))
        #expect(plan.batches.count > 1)
        #expect(plan.coverage.isComplete)
        #expect(plan.coverage.conversationsRead == 100)
        #expect(plan.coverage.passes == plan.batches.count)
        // Every stretch appears exactly once, in recording order, across the batches.
        #expect(plan.stretches.map(\.number) == Array(1...100))
    }

    @Test func batchesAreEvenlySizedRatherThanFilledToTheBrimWithARunt() {
        // Filling greedily leaves a last batch holding almost nothing — a whole extra model
        // call for a few minutes of transcript.
        let batches = AskCorpusPlanner.pack(
            stretches(count: 100, chars: 1_000), limit: 55_000)
        #expect(batches.count == 2)
        let sizes = batches.map { batch in batch.reduce(0) { $0 + $1.text.count } }
        let spread = (sizes.max() ?? 0) - (sizes.min() ?? 0)
        #expect(spread <= 5_000)
    }

    @Test func noBatchExceedsTheHardLimit() {
        let limit = 12_345
        let batches = AskCorpusPlanner.pack(stretches(count: 80, chars: 900), limit: limit)
        for batch in batches {
            let cost = batch.reduce(0) {
                $0 + $1.text.count + AskCorpusPlanner.stretchOverheadChars
            }
            #expect(cost <= limit)
        }
    }

    @Test func aSingleStretchLargerThanTheLimitIsStillRead() {
        // Better a call that may be trimmed at the edge than a conversation silently dropped.
        let batches = AskCorpusPlanner.pack(stretches(count: 1, chars: 90_000), limit: 1_000)
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
    }

    @Test func beyondTheSweepCeilingRelevanceChoosesWhatSurvivesAndCoverageSaysSo() {
        // 100 stretches, 10k budget, at most 2 batches: most of the scope cannot be read.
        let all = stretches(count: 100, chars: 1_000)
        let wanted = Set(["seg-40", "seg-41", "seg-42", "seg-43"])
        let plan = AskCorpusPlanner.plan(
            stretches: all,
            budget: AskBudget(transcriptChars: 10_000, maxBatches: 2),
            relevance: { wanted.contains($0) ? 100 : 0 })
        #expect(plan.batches.count == 2)
        #expect(!plan.coverage.isComplete)
        #expect(plan.coverage.conversationsInScope == 100)
        #expect(plan.coverage.conversationsRead < 100)
        // The batch holding the relevant run is one of the two that survived.
        #expect(plan.stretches.contains { wanted.contains($0.segmentId) })
    }

    @Test func withNothingToChooseOnRelevanceTheRECENTBatchesSurvive() {
        // A question asked today is far more often about this month than about the first week
        // of the archive — and the old fallback did exactly the opposite.
        let plan = AskCorpusPlanner.plan(
            stretches: stretches(count: 100, chars: 1_000),
            budget: AskBudget(transcriptChars: 10_000, maxBatches: 1))
        #expect(plan.batches.count == 1)
        let numbers = plan.stretches.map(\.number)
        #expect(numbers.contains(100))
        #expect(!numbers.contains(1))
    }

    @Test func anEmptyScopePlansNothingRatherThanCrashing() {
        let plan = AskCorpusPlanner.plan(
            stretches: [], budget: AskBudget(transcriptChars: 10_000))
        #expect(plan.batches.isEmpty)
        #expect(plan.coverage.conversationsInScope == 0)
        // Vacuously complete: there was nothing to miss.
        #expect(plan.coverage.isComplete)
    }

    @Test func aModelWithNoBudgetReadsNothingAndAdmitsIt() {
        let plan = AskCorpusPlanner.plan(
            stretches: stretches(count: 10), budget: AskBudget(transcriptChars: 0))
        #expect(plan.batches.isEmpty)
        #expect(plan.coverage.conversationsRead == 0)
        #expect(!plan.coverage.isComplete)
    }
}
