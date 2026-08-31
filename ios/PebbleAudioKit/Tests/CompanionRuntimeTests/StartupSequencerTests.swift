import CompanionRuntime
import Foundation
import SegmentStore
import Testing

// Startup order (plan Part 4.6): recover → queue recover → retention enforce (with cascade) →
// enqueue → diagnostics, with the M8 legacy import running once BEFORE all of it.

@Suite struct StartupSequencerTests {

    @Test func startupRunsThePlanOrderWithTheImportFirst() async throws {
        let recorder = StepRecorder()
        let sequencer = StartupSequencer(
            steps: StartupSteps(),
            onStep: { recorder.record($0) }
        )

        await sequencer.recoverIfNeeded()

        #expect(
            recorder.steps == [
                .legacyImport,
                .storeRecover,
                .queueRecover,
                .retentionEnforce,
                .enqueueClosedSegments,
                .refreshDiagnostics,
            ]
        )
    }

    @Test func retentionDeletionsCascadeBeforeTheQueueIsRefilled() async throws {
        let calls = CallRecorder()
        let sequencer = StartupSequencer(
            steps: StartupSteps(
                enforceRetention: {
                    calls.record("enforce")
                    return ["seg-a", "seg-b"]
                },
                cascadeDeleted: { calls.record("cascade:\($0)") },
                enqueueClosedSegments: { calls.record("enqueue") }
            )
        )

        await sequencer.recoverIfNeeded()

        #expect(calls.calls == ["enforce", "cascade:seg-a", "cascade:seg-b", "enqueue"])
    }

    @Test func durableRecoveryRunsOnceAndLaterCallsOnlyRefreshDiagnostics() async throws {
        let recorder = StepRecorder()
        let calls = CallRecorder()
        let sequencer = StartupSequencer(
            steps: StartupSteps(
                recoverStore: { calls.record("recover") },
                refreshDiagnostics: { calls.record("diagnostics") }
            ),
            onStep: { recorder.record($0) }
        )

        await sequencer.recoverIfNeeded()
        await sequencer.recoverIfNeeded()
        await sequencer.recoverIfNeeded()

        #expect(calls.calls.filter { $0 == "recover" }.count == 1)
        #expect(calls.calls.filter { $0 == "diagnostics" }.count == 3)
        #expect(recorder.steps.filter { $0 == .storeRecover }.count == 1)
    }

    @Test func aFailedStepNeverBlocksTheRestOfStartup() async throws {
        let recorder = StepRecorder()
        let sequencer = StartupSequencer(
            steps: StartupSteps(
                runLegacyImportIfNeeded: { throw TestFailure() },
                recoverStore: { throw TestFailure() },
                enforceRetention: { throw TestFailure() }
            ),
            onStep: { recorder.record($0) }
        )

        await sequencer.recoverIfNeeded()

        // Every later step still ran: a broken import or an unreadable directory must not leave
        // the app with no queue and no diagnostics.
        #expect(recorder.steps.contains(.enqueueClosedSegments))
        #expect(recorder.steps.last == .refreshDiagnostics)
    }

    @Test func retentionDaysIsWiredIntoTheRealRetentionConfig() throws {
        let sevenDays = RuntimeSettingsSnapshot(retentionDays: 7, retentionMaxBytes: 512)
        let config = retentionConfig(for: sevenDays)

        #expect(config.maxAgeMs == 7 * 24 * 60 * 60 * 1000)
        #expect(config.maxTotalBytes == 512)
        // Free-space floors keep their ported defaults; only the user-visible caps move.
        #expect(config.lowStorageFloorBytes == 500 * 1024 * 1024)
        #expect(config.pauseFloorBytes == 200 * 1024 * 1024)
    }

    @Test func retentionActuallyDeletesSegmentsOlderThanTheSetting() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .active, retentionDays: 1)
        )
        // Two segments: one inside the 1-day window, one well outside it.
        let dayMs: Int64 = 24 * 60 * 60 * 1000
        await fixture.clock.advance(by: 10 * dayMs)
        let stale = try await Fixture.writeSegment(
            into: fixture.store, streamId: 1, receivedAtMs: 0
        )
        let fresh = try await Fixture.writeSegment(
            into: fixture.store, streamId: 2, receivedAtMs: fixture.clock.nowMs
        )

        let deleted = try await fixture.retention.enforce()

        #expect(deleted == [stale])
        let remaining = await fixture.store.listSegments().map(\.segmentId)
        #expect(remaining == [fresh])
    }

    @Test func runtimeStartupRecoversAndPublishesDiagnostics() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store)

        await fixture.runtime.start()
        await TestClock.settle()

        #expect(fixture.diagnostics.snapshot.value.segmentCount == 1)
        #expect(fixture.diagnostics.snapshot.value.openSegmentId == nil)
        // The closed, untranscribed segment reached the queue.
        let tasks = try fixture.queue.all()
        #expect(tasks.count == 1)
        await fixture.runtime.stop()
    }
}
