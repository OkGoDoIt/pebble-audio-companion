import Foundation

// Settings · Diagnostics → "Redo onboarding".
//
// The row used to be `#if DEBUG` and read "Reset onboarding", which is a promise about data it
// does not keep either way: it never deleted anything, and the word "reset" next to "Delete All
// Data" reads like it might. It ships in every build now, because the person testing the flow on
// a real watch is running a release install, and it says what it does not touch.
extension Copy.Settings.Diagnostics {
    static let redoOnboarding = "Redo onboarding"

    /// Both halves verified.
    ///
    /// What is kept: `OnboardingRerun.reopen` writes `onboardingComplete` and nothing else, and
    /// step 3 now starts on the stored answer rather than its own default, so walking through
    /// unchanged rewrites nothing (`OnboardingViewModel.appliedPlan(with:)`).
    ///
    /// What changes: step 1's Connect Watch is Today's Start — `LiveWatchPairingSource` sets
    /// `captureIntent = .active` before it reaches the watch. So a re-run really does switch
    /// capture on for someone who had it off, and this row is the only place that could say so
    /// before they tap it. (Backing out of step 2 puts it back; finishing does not.)
    static let redoOnboardingFooter =
        "Shows the setup flow again. Recordings, keys, and the watch pairing are kept; Connect "
        + "Watch switches capture on, as on a first run."
}
