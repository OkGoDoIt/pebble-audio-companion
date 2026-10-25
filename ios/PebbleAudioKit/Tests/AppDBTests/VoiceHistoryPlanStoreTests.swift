import Foundation
import Testing
@testable import AppDB

@Suite struct VoiceHistoryPlanStoreTests {
    @Test func cursorSurvivesRecreationAndOffStopsFurtherDiscovery() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db)
        let plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local)
        try await plans.create(runID: "history", fromMs: 100, toMs: 900)
        try await plans.advance(runID: "history", startMs: 200, segmentId: "first", queued: true)
        let saved = try #require(try await VoiceHistoryPlanStore(db: db).plans().first)
        #expect(saved.cursorStartMs == 200 && saved.cursorSegmentId == "first")
        #expect(saved.queuedCount == 1 && !saved.discoveryComplete)
        try await voice.setMode(.off)
        try await plans.advance(runID: "history", startMs: 300, segmentId: "second", queued: true)
        let stopped = try #require(try await plans.plans().first)
        #expect(stopped.state == "cancelled")
        #expect(stopped.cursorSegmentId == "first")
    }

    @Test func clearingAutomaticNamesStopsPendingHistoryDiscovery() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db), plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local, nowMs: 50)
        try await plans.create(runID: "scan", fromMs: 100, toMs: 900)
        try await voice.clearAutomatic(nowMs: 200)
        try await plans.advance(runID: "scan", startMs: 200, segmentId: "late", queued: true)
        let plan = try #require(try await plans.plans().first)
        #expect(plan.state == "cancelled")
        #expect(plan.queuedCount == 0)
        #expect(try await voice.configuration().mode == .local)
        // A fresh runtime must not rediscover old sources under the new generation.
        #expect(try await voice.configuration().enabledAtMs == 200)
    }

    @Test func boundedQueueCapacityReturnsAsJobsFinishWithoutDiscardingHistoryScope() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db), plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local)
        try await plans.create(runID: "history", fromMs: 0, toMs: 99_000)
        for index in 0..<2 {
            _ = try await voice.prepareSource(segmentId: "s\(index)", revision: "r")
            try await voice.enqueueJob(runID: "history", segmentId: "s\(index)",
                startMediaMs: 0, endMediaMs: 2_000, recipeID: "recipe")
            try await plans.advance(runID: "history", startMs: Int64(index), segmentId: "s\(index)", queued: true)
        }
        #expect(try await plans.pendingCapacity(limit: 2) == 0)
        let job = try #require(try await voice.claimNextJob())
        #expect(try await voice.advanceJob(id: job.id, expectedCursorMediaMs: 0,
            nextCursorMediaMs: 2_000, attributions: []))
        #expect(try await plans.pendingCapacity(limit: 2) == 1)
        let plan = try #require(try await plans.plans().first)
        #expect(plan.toMs == 99_000 && !plan.discoveryComplete)
    }

    @Test func corpusChangeDuringInferenceRestartsFullyDiscoveredCancelledWork() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db), plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local)
        _ = try await voice.prepareSource(segmentId: "s", revision: "r")
        try await plans.create(runID: "scan", fromMs: 0, toMs: 9_000)
        try await voice.enqueueJob(runID: "scan", segmentId: "s", startMediaMs: 0,
            endMediaMs: 9_000, recipeID: "recipe")
        try await plans.advance(runID: "scan", startMs: 1, segmentId: "s", queued: true, complete: true)
        _ = try #require(try await voice.claimNextJob())
        try await voice.forgetProfile(personId: "changed")
        // The worker can cancel stale jobs before the next discovery pass sees the corpus change.
        #expect(try await voice.claimNextJob() == nil)
        #expect(try await voice.jobs(runID: "scan").first?.state == .cancelled)
        _ = try await plans.reconcileCorpus()
        let plan = try #require(try await plans.plans().first)
        #expect(!plan.discoveryComplete && plan.cursorStartMs == Int64.min)
        #expect(try await voice.jobs(runID: "scan").isEmpty)
    }

    @Test func newHumanEvidenceRestartsOnlyUnfinishedScope() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db), plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local)
        for run in ["unfinished", "finished"] {
            try await plans.create(runID: run, fromMs: 100, toMs: 900)
            try await plans.advance(runID: run, startMs: 200, segmentId: "s", queued: false)
        }
        try await plans.finishDiscovery(runID: "finished")
        // Forgetting even an empty profile changes the corpus, invalidating work tokens.
        try await voice.forgetProfile(personId: "no-profile")
        _ = try await plans.reconcileCorpus()
        let result = try await plans.plans()
        #expect(result.first(where: { $0.runID == "unfinished" })?.cursorStartMs == Int64.min)
        #expect(result.first(where: { $0.runID == "finished" })?.cursorStartMs == 200)
        #expect(result.first(where: { $0.runID == "finished" })?.discoveryComplete == true)
    }
}
