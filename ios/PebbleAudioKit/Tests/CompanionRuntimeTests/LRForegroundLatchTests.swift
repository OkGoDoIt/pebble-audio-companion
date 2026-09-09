import CompanionRuntime
import Foundation
import Receiver
import Testing

// Regression suite for the 2026-09-08 "Today and Library showed no live conversation while
// recording was healthy" report.
//
// What actually happened, from the device's flight recorder:
//
//   18:51:48.346  ──── process start (foreground) v2.0.0 ────
//   18:51:48.644  launch cause: Core Bluetooth state restoration
//   18:52:15.499  session authorized -> streaming(338564441)
//   18:52:49.098  heartbeat link=streaming intent=active watch=streaming audio=0s ago  (×N)
//
// The user had just installed over the existing app and was looking at it. iOS still handed the
// launch `UIApplicationLaunchOptionsBluetoothCentralsKey`, because the previous process had a
// connected central to restore — it does that for ANY launch with CB state, not only headless
// ones (21 of the 22 process starts in that file carried it). The app read that as "nobody is
// watching", latched receive-only, and `CompanionRuntime.start()` — which reaches the latch only
// after `recoverBeforeReceiving()`, tens of seconds on a migrated container — demoted the runtime
// to background mode with the launch's own `didBecomeActive` already spent.
//
// `setForeground` is a transition guard, so nothing could promote it back. Every pipeline pass
// then took `PipelinePass.run()`'s background early-return (the phone was `thermal=serious`, so
// `BackgroundWorkPolicy` held), which skips `regroup` — the step that puts the open segment in the
// conversations table as `state = "live"`. Capture was perfect throughout; the grouped tables the
// UI reads simply never learned about it. Backgrounding the app and returning was the only cure,
// and that is exactly what the user did.

@Suite struct ForegroundLatchTests {

    /// The incident order: the scene came up first, THEN the relaunch notice.
    @Test func aVisibleAppIsNeverDemotedByARestorationNotice() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        // `didFinishLaunchingWithOptions` sets the latch synchronously, before any event lands.
        fixture.receiver.markLaunchedInBackground()
        await coordinator.handle(.didBecomeActive)
        await coordinator.handle(.restorationRelaunch)

        #expect(
            fixture.runtime.isForeground,
            "a scene came up, so the launch was not headless whatever the launch options said")
        #expect(!fixture.receiver.launchedInBackground)
        await fixture.runtime.stop()
    }

    /// The other order, which is the one that actually bit: the notice lands first (it is a
    /// synchronous delegate callback), the scene comes up a moment later, and `start()` reads the
    /// latch long after both.
    @Test func startDoesNotDemoteAnAppThatHasAlreadyComeOnScreen() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        fixture.receiver.markLaunchedInBackground()
        await coordinator.handle(.restorationRelaunch)
        #expect(!fixture.runtime.isForeground, "receive-only is right until a window exists")

        await coordinator.handle(.didBecomeActive)
        // `runtime.start()` is where the latch is read, and on a migrated container it gets here
        // tens of seconds after the window appeared.
        await coordinator.handle(.didFinishLaunching)

        #expect(
            fixture.runtime.isForeground,
            "start() must not re-apply receive-only to a process the person is looking at")
        await fixture.runtime.stop()
    }

    /// A genuine headless wake — no scene, ever — must still be receive-only. This is the half
    /// that must not regress: promoting it would load a transcription model on a ~10 s Bluetooth
    /// wake, on the tightest memory budget iOS gives us.
    @Test func aTrulyHeadlessWakeStaysReceiveOnly() async throws {
        let fixture = try RuntimeFixture()
        let coordinator = AppLifecycleCoordinator(runtime: fixture.runtime)

        fixture.receiver.markLaunchedInBackground()
        await coordinator.handle(.restorationRelaunch)
        await coordinator.handle(.didFinishLaunching)

        #expect(!fixture.runtime.isForeground)
        #expect(fixture.receiver.launchedInBackground)
        await fixture.runtime.stop()
    }

    /// Why it was invisible rather than merely slow: a background pass never regroups, and the
    /// live conversation row IS the regrouping. Same `thermal=serious` the recorder logged at
    /// 18:51:48, which is what made `BackgroundWorkPolicy` hold.
    @Test func abackgroundPassSkipsTheRegroupEveryLiveRowComesFrom() async throws {
        let stages = StageRecorder()
        let steps = PipelineSteps(
            isForeground: { false },
            regroup: {},
            backgroundWorkDecision: { .hold(reason: .tooHot) }
        )
        let pass = PipelinePass(steps: steps, clock: TestClock(), onStage: { stages.record($0) })

        _ = try await pass.run()

        #expect(stages.stages.contains(.backgroundDefer))
        #expect(
            !stages.stages.contains(.regroup),
            "the grouped tables are where Today and Library read the live conversation from")
    }

    /// ...and a foreground pass does regroup, so the fix has somewhere to land.
    @Test func aForegroundPassRegroups() async throws {
        let stages = StageRecorder()
        let steps = PipelineSteps(isForeground: { true }, regroup: {})
        let pass = PipelinePass(steps: steps, clock: TestClock(), onStage: { stages.record($0) })

        _ = try await pass.run()

        #expect(stages.stages.contains(.regroup))
        #expect(!stages.stages.contains(.backgroundDefer))
    }
}
