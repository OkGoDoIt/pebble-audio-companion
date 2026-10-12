import AppDB
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
                .followUpWallTimes,
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
        // Free-space floors keep the kit's defaults; only the user-visible caps move. The floors
        // are what pauses capture on a filling phone, now that nothing is deleted by default.
        #expect(config.lowStorageFloorBytes == 2 * 1024 * 1024 * 1024)
        #expect(config.pauseFloorBytes == 1 * 1024 * 1024 * 1024)
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

    /// A follow-up written before extraction stored when it was said gets that time at launch,
    /// from the segment's clock, through the same wiring the app uses.
    @Test func runtimeStartupFillsFollowUpWallTimes() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store, frames: 50)
        let followUps = FollowUpStore(db: fixture.database)
        try await followUps.upsertExtracted(
            FollowUp(
                id: "f1", text: "Call Sam", done: false, sourceConversationId: "conv",
                sourceSegmentId: segmentId, createdAtMs: 1, sourceStartMs: 400,
                sourceEndMs: 600))

        await fixture.runtime.start()
        await TestClock.settle()

        let meta = try #require(await fixture.store.readMeta(segmentId))
        #expect(
            try await followUps.load(id: "f1")?.sourceWall
                == SegmentMediaClock.wallRange(ofMediaStartMs: 400, endMs: 600, in: meta))
        await fixture.runtime.stop()
    }
}

// The split that keeps a background wake from expiring before the microphone starts.
//
// A Core Bluetooth relaunch gets roughly ten seconds of runtime, and every one of them is a fresh
// process that re-runs the whole once-per-process recovery order from the beginning. Over a real
// container that order is far slower than the budget — the recovery test against the user's own
// data takes ~16 s on a Mac — so putting all of it in front of `receiver.start()` meant the wake
// could end with the link restored, the watch streaming, and nobody consuming a byte. The next
// wake then started the same sweep over and got no further.
//
// Only `storeRecover` has a real ordering constraint (`SegmentStore.recover()` carries
// `precondition(current == nil)`), plus the legacy import that feeds it. Everything after is
// catch-up on audio that is already durable.
@Suite struct StartupSequencerSplitTests {

    @Test func onlyTheStoreCriticalStepsBlockTheReceiver() async throws {
        let recorder = StepRecorder()
        let sequencer = StartupSequencer(steps: StartupSteps(), onStep: { recorder.record($0) })

        await sequencer.recoverBeforeReceiving()

        #expect(
            recorder.steps == [.legacyImport, .storeRecover],
            "the receiver must not wait for the retention sweep or the transcription catch-up"
        )
    }

    @Test func theTwoHalvesTogetherAreTheWholePlanOrder() async throws {
        let recorder = StepRecorder()
        let sequencer = StartupSequencer(steps: StartupSteps(), onStep: { recorder.record($0) })

        await sequencer.recoverBeforeReceiving()
        await sequencer.recoverRemainder()

        #expect(
            recorder.steps == [
                .legacyImport,
                .storeRecover,
                .queueRecover,
                .retentionEnforce,
                .enqueueClosedSegments,
                .followUpWallTimes,
                .refreshDiagnostics,
            ]
        )
    }

    @Test func eachHalfRunsOnce() async throws {
        let calls = CallRecorder()
        let sequencer = StartupSequencer(
            steps: StartupSteps(
                recoverStore: { calls.record("recover") },
                recoverQueue: { calls.record("queue") },
                refreshDiagnostics: { calls.record("diagnostics") }
            )
        )

        await sequencer.recoverBeforeReceiving()
        await sequencer.recoverRemainder()
        // Foreground entry and BGProcessing both call the whole thing again.
        await sequencer.recoverIfNeeded()

        #expect(
            calls.calls == ["recover", "queue", "diagnostics", "diagnostics"],
            "the durable halves run once; repeat calls only refresh diagnostics"
        )
    }

    @Test func recoverIfNeededStillRunsTheWholeOrderForCallersThatWantIt() async throws {
        // Foreground entry and the BGProcessing window keep using the single call.
        let recorder = StepRecorder()
        let sequencer = StartupSequencer(steps: StartupSteps(), onStep: { recorder.record($0) })

        await sequencer.recoverIfNeeded()

        #expect(recorder.steps.first == .legacyImport)
        #expect(recorder.steps.last == .refreshDiagnostics)
        #expect(recorder.steps.count == 7)
    }
}
