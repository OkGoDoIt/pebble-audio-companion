import CompanionRuntime
import Foundation
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
        await TestClock.settle()

        #expect(
            fixture.lifecycle.idleChecks > 0,
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
// These are the regression tests for the defect behind "it barely records anything unless I'm in
// the app": with only `bluetooth-central`, iOS suspends the process between Core Bluetooth wakes,
// which freezes the 5 s keepalive — and the watch stops its microphone 15 s later
// (RECEIVER_LIVENESS_TIMEOUT_MS in the firmware). Residency is what stops the suspension, so
// "capture is on" and "residency is held" must never disagree.
@Suite struct BackgroundResidencyWiringTests {

    @Test func capturingHoldsResidency() async throws {
        let fixture = try RuntimeFixture()
        #expect(fixture.residency.state.value == .notNeeded)

        await fixture.receiver.applyCaptureIntent(.active)
        #expect(
            fixture.residency.state.value == .held,
            "capture is on, so the process must not be suspendable"
        )
    }

    @Test func turningCaptureOffReleasesResidency() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.applyCaptureIntent(.active)
        #expect(fixture.residency.state.value == .held)

        await fixture.receiver.applyCaptureIntent(.off)
        #expect(
            fixture.residency.state.value == .notNeeded,
            "the user turned capture off; holding an audio session would just spend battery"
        )
    }

    @Test func pausingReleasesResidency() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.applyCaptureIntent(.active)

        // A paused watch is not streaming, so its liveness watchdog is not armed and there is
        // nothing to stay awake for.
        await fixture.receiver.applyCaptureIntent(.paused)
        #expect(fixture.residency.state.value == .notNeeded)

        await fixture.receiver.applyCaptureIntent(.active)
        #expect(fixture.residency.state.value == .held, "resuming must take residency back")
    }

    @Test func startingTheReceiverWithCaptureAlreadyActiveHoldsResidency() async throws {
        // The launch path: intent comes back from settings already `.active`, so it never passes
        // through applyCaptureIntent. If only that funnel took residency, every relaunch — including
        // every Core Bluetooth background relaunch — would come up suspendable.
        let fixture = try RuntimeFixture()  // the fixture's default intent is already `.active`
        #expect(fixture.residency.state.value == .notNeeded)

        await fixture.receiver.start()
        #expect(fixture.residency.state.value == .held)
        await fixture.receiver.stop()
    }

    @Test func aRepeatedActiveIntentStillEndsUpHeld() async throws {
        // Residency is re-asserted before applyCaptureIntent's no-change early return, because the
        // one way this fails is silently: fine in the foreground, dead the moment it backgrounds.
        let fixture = try RuntimeFixture()
        await fixture.receiver.applyCaptureIntent(.active)
        fixture.residency.setWanted(false)  // simulate the session having been lost underneath us

        await fixture.receiver.applyCaptureIntent(.active)
        #expect(fixture.residency.state.value == .held)
    }
}
