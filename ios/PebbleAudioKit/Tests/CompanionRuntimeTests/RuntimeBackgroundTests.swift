import CompanionRuntime
import Foundation
import Receiver
import Testing

// Port of `app/src/commonTest/.../AudioCompanionRuntimeBackgroundTest.kt` — all 5 cases, same
// names and same assertions, on virtual time.
//
// Background processing policy: receiving keeps running, but the heavy processing loop must defer
// and release the local model while backgrounded so a short Core Bluetooth wake stays cheap.

@Suite struct RuntimeBackgroundTests {

    @Test func backgroundMarksTranscriptionDeferredInDiagnostics() async throws {
        let fixture = try RuntimeFixture()
        await fixture.diagnostics.refresh()
        #expect(!fixture.diagnostics.snapshot.value.transcriptionDeferredInBackground)

        await fixture.runtime.setForeground(false)
        #expect(fixture.diagnostics.snapshot.value.transcriptionDeferredInBackground)

        await fixture.runtime.setForeground(true)
        #expect(!fixture.diagnostics.snapshot.value.transcriptionDeferredInBackground)
    }

    @Test func backgroundReleasesLocalModel() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.start()
        await TestClock.settle()  // let the initial foreground pass run and suspend

        await fixture.runtime.setForeground(false)
        await TestClock.settle()  // background release runs

        #expect(
            fixture.lifecycle.releaseReasons.contains("background"),
            "expected the local model to be released on background; got \(fixture.lifecycle.releaseReasons)"
        )
        await fixture.runtime.stop()
    }

    @Test func foregroundIdlePassChecksForModelRelease() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.start()
        // `settle()` yields a fixed number of times; whether the foreground loop has reached its
        // idle check by then depends on how much real work startup did ahead of it, so a fixed
        // yield count is a race rather than a synchronisation point. Wait for the fact itself.
        let checked = await waitUntil { fixture.lifecycle.idleChecks > 0 }

        #expect(
            checked,
            "expected the foreground loop to evaluate idle model release"
        )
        await fixture.runtime.stop()
    }

    @Test func catchUpBurstIsSkippedInForeground() async throws {
        let fixture = try RuntimeFixture()
        // Default policy is foreground; the normal loop owns catch-up there.
        let processed = await fixture.runtime.runCatchUpBurst()

        #expect(processed == 0)
        #expect(!fixture.lifecycle.releaseReasons.contains("background catch-up"))
    }

    @Test func catchUpBurstRunsAndReleasesModelWhenBackgrounded() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setForeground(false)

        let processed = await fixture.runtime.runCatchUpBurst()

        #expect(processed == 0)  // empty queue
        #expect(
            fixture.lifecycle.releaseReasons.contains("background catch-up"),
            "expected the burst to release the model afterward; got \(fixture.lifecycle.releaseReasons)"
        )
    }
}

// Background RESIDENCY: whether the process is allowed to keep running at all while backgrounded.
//
// Residency is what stops iOS suspending us, and a suspended app cannot answer the watch's 15 s
// liveness watchdog — the watch then stops its microphone. But it is also the most expensive thing
// this app can hold, so the rule is narrow: hold it while the watch is ACTUALLY STREAMING, and at
// no other time.
//
// The first version keyed off the user's capture intent instead, and a night of real logs showed
// what that costs — 152 consecutive minutes holding an audio session with `audio=never`, because
// the watch was paused and had nothing to send. The phone stayed awake all night for a watch that
// was asleep.
@Suite struct BackgroundResidencyWiringTests {

    @Test func capturingWithoutAStreamDoesNotHoldResidency() async throws {
        let fixture = try RuntimeFixture()
        #expect(fixture.residency.state.value == .notNeeded)

        // Intent alone is not enough. The watch's liveness watchdog runs only in its Streaming
        // state, so with nothing streaming there is no deadline to meet and being suspended costs
        // nothing — a BLE notification wakes us when the watch has something to say.
        await fixture.receiver.applyCaptureIntent(.active)
        #expect(
            fixture.residency.state.value == .notNeeded,
            "capture intent with no stream must not hold an audio session"
        )
    }

    @Test func aLiveStreamHoldsResidency() async throws {
        let fixture = try RuntimeFixture()
        try await fixture.beginStreaming()

        #expect(await waitUntil({ fixture.receiver.state.value.isStreaming }))
        #expect(
            await waitUntil({ fixture.residency.state.value == .held }),
            "a streaming watch is exactly when the process must not be suspended"
        )
        await fixture.receiver.stop()
    }

    @Test func aStreamThatENDSReleasesResidencyAfterTheGrace() async throws {
        // The battery case from the overnight log: the watch stops sending (its own power-save
        // pause, a low battery, a policy pause) and the phone must stop holding an audio session
        // for it. Nothing about the user's intent changed — only the stream.
        let fixture = try RuntimeFixture()
        try await fixture.beginStreaming()
        #expect(await waitUntil({ fixture.residency.state.value == .held }))

        fixture.link.connectionState.value = .disconnected
        #expect(await waitUntil({ !fixture.receiver.state.value.isStreaming }))

        // Held through the grace window, so a reconnect a second later does not thrash the
        // audio session...
        #expect(fixture.residency.state.value == .held)

        // ...and released once the stream is really gone.
        await fixture.clock.advance(by: 21_000)
        #expect(
            await waitUntil({ fixture.residency.state.value == .notNeeded }),
            "a watch that stopped streaming must not keep the phone awake"
        )
        await fixture.receiver.stop()
    }

    @Test func stoppingTheReceiverReleasesResidency() async throws {
        let fixture = try RuntimeFixture()
        try await fixture.beginStreaming()
        #expect(await waitUntil({ fixture.residency.state.value == .held }))

        await fixture.receiver.stop()
        #expect(fixture.residency.state.value == .notNeeded)
    }

    // The one bounded exception to "residency follows the stream": the launch itself. Recovery
    // runs before the receiver, and on a headless launch nothing else keeps the process awake
    // while it does — iOS suspended one such launch mid-recovery for fifteen minutes on
    // 2026-09-15. So `start()` holds residency on the strength of capture being active, and hands
    // it to the stream rule the moment recovery is done: kept while streaming, otherwise released
    // after the ordinary grace.
    @Test func theLaunchHoldsResidencyThroughRecoveryAndThenLetsTheStreamRuleDecide() async throws {
        let fixture = try RuntimeFixture()
        #expect(fixture.residency.state.value == .notNeeded)

        fixture.receiver.holdResidencyThroughStartup()
        #expect(fixture.residency.state.value == .held, "recovery must not run without residency")

        // Recovery done, no stream: the hold survives the grace window and no longer...
        await fixture.receiver.markStoreRecovered()
        #expect(fixture.residency.state.value == .held)
        await fixture.clock.advance(by: 21_000)
        #expect(
            await waitUntil({ fixture.residency.state.value == .notNeeded }),
            "with nothing streaming after recovery, the launch hold must be released"
        )
        await fixture.receiver.stop()
    }

    @Test func theLaunchHoldIsKeptWhenTheStreamArrivesInsideTheGrace() async throws {
        let fixture = try RuntimeFixture()
        fixture.receiver.holdResidencyThroughStartup()
        #expect(fixture.residency.state.value == .held)

        try await fixture.beginStreaming()
        #expect(await waitUntil({ fixture.receiver.state.value.isStreaming }))
        await fixture.clock.advance(by: 21_000)
        // Never released, never thrashed: the stream took the hold over.
        #expect(fixture.residency.state.value == .held)
        await fixture.receiver.stop()
    }

    @Test func aLaunchWithCaptureOffOrPausedHoldsNothing() async throws {
        for intent in [CaptureIntent.off, .paused] {
            let fixture = try RuntimeFixture(settings: RuntimeSettingsSnapshot(captureIntent: intent))
            fixture.receiver.holdResidencyThroughStartup()
            #expect(fixture.residency.state.value == .notNeeded, "\(intent)")
            await fixture.receiver.stop()
        }
    }

    @Test func aPausedWatchDoesNotHoldResidency() async throws {
        // A paused watch is not streaming, so its liveness watchdog is not armed and there is
        // nothing to stay awake for.
        let fixture = try RuntimeFixture()
        await fixture.receiver.applyCaptureIntent(.paused)
        #expect(fixture.residency.state.value == .notNeeded)
        await fixture.receiver.stop()
    }
}
