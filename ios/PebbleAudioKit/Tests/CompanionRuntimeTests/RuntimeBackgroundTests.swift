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
