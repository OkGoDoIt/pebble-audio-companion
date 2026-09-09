import CompanionRuntime
import Foundation
import Intelligence
import Receiver
import Testing
import Transcription

// Onboarding's capture switch is PROVISIONAL until the flow finishes.
//
// Step 1's "Connect Watch" writes `captureIntent = .active` on purpose — it is the same path
// Today's Start takes, and a completed onboarding is meant to leave capture running. The defect
// this suite pins is what happened on every OTHER way out. `cancelPairing()` covered exactly one
// of them (the Cancel button on step 2, and only on the first attempt); someone who got past
// pairing and then backgrounded, force-quit, or had the process reclaimed came back to a live
// microphone they had never agreed to. On a background-microphone product that is the worst
// failure mode available, and onboarding is re-runnable from Settings → Diagnostics, so
// "they deliberately had capture off before" is the ordinary case rather than a fresh install.
//
// The mechanism is a durable marker (`AppSettings.onboardingCaptureRestore`) consumed at the next
// process start, so these tests do what the app does: build one `AppSettings`, drive it, then
// build a SECOND one over the same defaults suite — that second construction IS the relaunch.
@Suite("onboarding capture restore") @MainActor
struct FLOnboardingCaptureRestoreTests {

    private struct Fixture {
        let defaults: UserDefaults
        let suite: String

        /// A fresh process reading the same stored preferences.
        @MainActor
        func relaunch() -> AppSettings {
            AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
        }
    }

    private func makeFixture() -> (Fixture, AppSettings) {
        let suite = "fl-onboarding-capture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let fixture = Fixture(defaults: defaults, suite: suite)
        return (fixture, fixture.relaunch())
    }

    /// What `LiveWatchPairingSource.run` does, in the order it does it.
    private func connectWatch(_ settings: AppSettings) {
        settings.beginOnboardingCaptureAttempt()
        settings.captureIntent = .active
    }

    // MARK: - The bug

    @Test func abandoningTheFlowAfterPairingSwitchesCaptureBackOff() {
        let (fixture, settings) = makeFixture()
        settings.captureIntent = .off
        settings.onboardingComplete = false

        connectWatch(settings)
        #expect(settings.captureIntent == .active)

        // …and then the person never finishes: they background the app at the processing
        // question and iOS reclaims the process.
        let relaunched = fixture.relaunch()

        #expect(relaunched.captureIntent == .off)
        #expect(relaunched.onboardingCaptureRestore == nil)
        // Once undone, it stays undone — a third launch must not re-apply anything.
        #expect(fixture.relaunch().captureIntent == .off)
    }

    /// A timed pause is a state someone chose too, and it is restored as itself rather than
    /// collapsed to "off".
    @Test func abandoningRestoresAPausedIntentExactly() {
        let (fixture, settings) = makeFixture()
        settings.captureIntent = .paused
        settings.onboardingComplete = false

        connectWatch(settings)

        #expect(fixture.relaunch().captureIntent == .paused)
    }

    // MARK: - …without breaking the case Connect Watch exists for

    @Test func completingTheFlowLeavesCaptureOn() {
        let (fixture, settings) = makeFixture()
        settings.captureIntent = .off
        settings.onboardingComplete = false

        connectWatch(settings)
        OnboardingViewModel(source: MockWatchPairingSource()).finish(settings: settings)

        #expect(settings.onboardingComplete)
        #expect(settings.onboardingCaptureRestore == nil)
        #expect(fixture.relaunch().captureIntent == .active)
    }

    /// Belt and braces: even if the gate is reopened later (Settings → Diagnostics → Redo
    /// onboarding), the capture a FINISHED run left on is not clawed back — the marker was
    /// consumed when that run finished, and a reopened gate has no marker of its own until
    /// somebody taps Connect Watch again.
    @Test func reopeningTheGateAfterAFinishedRunDoesNotUndoCapture() {
        let (fixture, settings) = makeFixture()
        settings.captureIntent = .off
        connectWatch(settings)
        OnboardingViewModel(source: MockWatchPairingSource()).finish(settings: settings)

        OnboardingRerun.reopen(settings)

        #expect(fixture.relaunch().captureIntent == .active)
    }

    // MARK: - The Cancel button, including after a retry

    @Test func cancelReturnsTheIntentToPutBackExactlyOnce() {
        let (_, settings) = makeFixture()
        settings.captureIntent = .off

        connectWatch(settings)

        #expect(settings.takeOnboardingCaptureRestore() == .off)
        #expect(settings.takeOnboardingCaptureRestore() == nil)
    }

    /// Step 2 is retryable ("No Pebble found" → Try again), and each retry re-enters the same
    /// code path. Reading the CURRENT intent there recorded `.active` — what the first attempt
    /// had just written — so Cancel after a retry restored nothing at all. The marker keeps the
    /// first answer.
    @Test func retryingPairingKeepsTheIntentTheRunStartedWith() {
        let (_, settings) = makeFixture()
        settings.captureIntent = .off
        settings.onboardingComplete = false

        connectWatch(settings)  // first attempt: fails
        connectWatch(settings)  // "Try again"
        connectWatch(settings)  // and again

        #expect(settings.takeOnboardingCaptureRestore() == .off)

        // The same, through the launch path rather than the button.
        let (secondFixture, second) = makeFixture()
        second.captureIntent = .off
        second.onboardingComplete = false
        connectWatch(second)
        connectWatch(second)
        #expect(secondFixture.relaunch().captureIntent == .off)
    }

    // MARK: - Nobody is switched off who was already on

    @Test func aRunStartedWithCaptureAlreadyOnHasNothingToUndo() {
        let (_, settings) = makeFixture()
        settings.captureIntent = .active
        settings.onboardingComplete = false

        connectWatch(settings)

        // Cancel has nothing to do…
        #expect(settings.takeOnboardingCaptureRestore() == nil)

        // …and neither does an abandoned run.
        let (secondFixture, second) = makeFixture()
        second.captureIntent = .active
        second.onboardingComplete = false
        connectWatch(second)
        #expect(secondFixture.relaunch().captureIntent == .active)
    }

    /// The marker only ever applies to the run that wrote it: a finished install that somehow
    /// carries no marker is untouched, which is every launch this app will ever make after setup.
    @Test func anOrdinaryLaunchWritesNothingAndChangesNothing() {
        let (fixture, settings) = makeFixture()
        settings.captureIntent = .active
        settings.onboardingComplete = true

        let before = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
        let relaunched = fixture.relaunch()
        let after = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]

        #expect(relaunched.captureIntent == .active)
        #expect(
            Set(before.keys).union(after.keys).allSatisfy {
                String(describing: before[$0]) == String(describing: after[$0])
            }
        )
    }
}
