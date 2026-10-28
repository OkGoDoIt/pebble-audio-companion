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

    @Test func finishingJobsKeepsTheHistoryScope() async throws {
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
        let job = try #require(try await voice.claimNextJob())
        #expect(try await voice.advanceJob(id: job.id, expectedCursorMediaMs: 0,
            nextCursorMediaMs: 2_000, attributions: []))
        let plan = try #require(try await plans.plans().first)
        #expect(plan.toMs == 99_000 && !plan.discoveryComplete)
    }

    /// A new sample used to restart the whole scan from the first recording, so a library long
    /// enough to need several nights never finished while voices were still being named.
    @Test func newVoicesKeepAHistoryRunsPlaceAndItsQueuedWork() async throws {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db), plans = VoiceHistoryPlanStore(db: db)
        try await voice.setMode(.local)
        _ = try await voice.prepareSource(segmentId: "s", revision: "r")
        try await plans.create(runID: "scan", fromMs: 0, toMs: 9_000)
        try await plans.create(runID: "unfinished", fromMs: 100, toMs: 900)
        try await voice.enqueueJob(runID: "scan", segmentId: "s", startMediaMs: 0,
            endMediaMs: 9_000, recipeID: "recipe")
        try await plans.advance(runID: "scan", startMs: 1, segmentId: "s", queued: true, complete: true)
        try await plans.advance(runID: "unfinished", startMs: 200, segmentId: "s", queued: false)
        let job = try #require(try await voice.claimNextJob())
        // Forgetting even an empty profile changes the voices.
        try await voice.forgetProfile(personId: "changed")
        try await voice.releaseJob(id: job.id)
        #expect(try await voice.claimNextJob()?.id == job.id)
        let result = try await plans.plans()
        #expect(result.first(where: { $0.runID == "scan" })?.discoveryComplete == true)
        #expect(result.first(where: { $0.runID == "unfinished" })?.cursorStartMs == 200)
    }
}
