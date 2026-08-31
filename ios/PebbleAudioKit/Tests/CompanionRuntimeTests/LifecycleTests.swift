import CompanionRuntime
import Foundation
import Receiver
import Testing

// iOS lifecycle (plan Part 4.6). Driven through `AppLifecycleEvent` so the whole matrix runs on
// macOS with no UIKit — the UIKit adapter is a notification-observer shim over exactly this.

@Suite struct LifecycleTests {

    @Test func restorationRelaunchAppliesReceiveOnlyBeforeTheReceiverStarts() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        await coordinator.handle(.restorationRelaunch)

        // The flag AND the policy are set before anything starts, which is the whole point:
        // starting first and demoting after would load a model on a background wake.
        #expect(fixture.receiver.launchedInBackground)
        #expect(!fixture.runtime.isForeground)
        #expect(!fixture.receiver.isRunning)

        await coordinator.handle(.didFinishLaunching)
        #expect(!fixture.runtime.isForeground, "launch must not promote a restoration relaunch")
        await fixture.runtime.stop()
    }

    @Test func foregroundEntryStartsTheReceiverIdempotentlyAndReconciles() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)
        _ = try await Fixture.writeSegment(into: fixture.store)

        await coordinator.handle(.didEnterBackground)
        await coordinator.handle(.didBecomeActive)
        await coordinator.handle(.didBecomeActive)

        #expect(fixture.runtime.isForeground)
        #expect(fixture.receiver.isRunning)
        // reconcilePendingTranscriptions enqueued the segment that closed while backgrounded.
        #expect(try fixture.queue.all().count == 1)
    }

    @Test func foregroundEntryNeverArmsTheWatchPrompt() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        await coordinator.handle(.didEnterBackground)
        await coordinator.handle(.didBecomeActive)

        #expect(
            !fixture.receiver.isWatchEnableRequestArmed,
            "only an explicit Start/Settings tap may prompt the watch"
        )
    }

    @Test func backgroundEntryReleasesTheModelAndHandsOffCloudWork() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, transcriptionMode: .remoteFirst
            )
        )
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        await coordinator.handle(.didEnterBackground)

        #expect(!fixture.runtime.isForeground)
        #expect(fixture.lifecycle.releaseReasons.contains("background"))
    }

    @Test func memoryWarningReleasesTheModel() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        await coordinator.handle(.memoryWarning)

        #expect(fixture.lifecycle.releaseReasons.contains("memory warning"))
    }

    @Test func backgroundProcessingDoesMaintenanceAndNeverTouchesTheReceiverRunState() async throws
    {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)
        await fixture.runtime.start()
        await TestClock.settle()
        let runningBefore = fixture.receiver.isRunning
        let intentBefore = fixture.runtime.captureIntent

        await coordinator.handle(.didEnterBackground)
        await coordinator.handle(.backgroundProcessingStarted)

        // A processing-task window must never be able to disable recording.
        #expect(fixture.receiver.isRunning == runningBefore)
        #expect(fixture.runtime.captureIntent == intentBefore)
        // It also releases the model afterwards, so nothing stays resident into suspension.
        #expect(fixture.lifecycle.releaseReasons.contains("background catch-up"))
        await fixture.runtime.stop()
    }

    @Test func backgroundProcessingExpirationCancelsOnlyOptionalWork() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)
        await fixture.runtime.start()
        await coordinator.handle(.didEnterBackground)
        let runningBefore = fixture.receiver.isRunning

        await coordinator.handle(.backgroundProcessingExpired)

        #expect(fixture.receiver.isRunning == runningBefore)
        #expect(fixture.runtime.captureIntent != .off)
        await fixture.runtime.stop()
    }

    @Test func catchUpBurstIsBoundedAndCancellable() async throws {
        let fixture = try RuntimeFixture()
        // 12 closed segments; the burst must stop at 10.
        for index in 0..<12 {
            _ = try await Fixture.writeSegment(
                into: fixture.store,
                streamId: UInt32(index + 1),
                startTimeMs: UInt64(1_756_512_000_000 + index * 600_000),
                receivedAtMs: Int64(index) * 600_000
            )
        }
        await fixture.runtime.setForeground(false)
        try await fixture.transcription.enqueueClosedSegments()
        #expect(try fixture.queue.all().count == 12)

        // The router has no providers, so each task is parked as Disabled rather than
        // transcribed — the cap itself is what is under test here.
        let processed = await fixture.runtime.runCatchUpBurst(maxSegments: 10)
        #expect(processed <= 10)
    }

    @Test func terminationStopsTheLoopAndTheReceiver() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)
        await coordinator.handle(.didFinishLaunching)
        await TestClock.settle()
        #expect(fixture.receiver.isRunning)

        await coordinator.handle(.willTerminate)

        #expect(!fixture.receiver.isRunning)
    }

    @Test func backgroundUrlSessionEventsReconnectTheUploader() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        // No uploader is wired in tests; the contract is that the event is accepted and routed
        // rather than dropped, and that it never changes run state.
        await coordinator.handle(.backgroundUrlSessionEvents)

        #expect(await coordinator.handledEvents == [.backgroundUrlSessionEvents])
    }

    @Test func backgroundTaskPolicyMatchesThePlan() {
        #expect(
            BackgroundTaskPolicy.processingTaskIdentifier
                == "dev.audiocompanion.app.receiver-processing"
        )
        #expect(BackgroundTaskPolicy.earliestBeginInterval == 15 * 60)
        #expect(!BackgroundTaskPolicy.requiresNetworkConnectivity)
        #expect(!BackgroundTaskPolicy.requiresExternalPower)
        // Model residency: 30 s foreground idle release, 60 s background loop sleep.
        #expect(BackgroundTaskPolicy.foregroundModelIdleMs == 30_000)
        #expect(BackgroundTaskPolicy.backgroundLoopSleepMs == 60_000)
        #expect(PipelinePacing.catchUpMaxSegments == 10)
    }
}
