import AppIntents
import Foundation

// Pause/Resume App Intents (plan 6.8). This file compiles into BOTH the app and the widget
// extension, because Control Center's toggle lives in the extension and must invoke the same
// intent types the app and Siri use.
//
// What an intent does is narrow on purpose: it writes the desired tri-state to the App Group
// and posts the Darwin notification. The app — alive in the background via bluetooth-central —
// applies it through the normal ReceiverService path. The extension never touches BLE, never
// starts a session, and never turns capture ON from OFF (that needs the app's consent flow).
//
// Note on the strings: every `title` / `IntentDescription` / dialog below is an inline literal.
// `appintentsmetadataprocessor` extracts them at build time and rejects constants, so these
// cannot be routed through `Copy` — the one sanctioned exception to the single string catalog.

/// Pause capture. Idempotent — pausing an already-paused watch is a no-op with the same answer.
struct PauseCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Capture"
    static var description = IntentDescription(
        "Stops capturing audio from your Pebble. Coverage shows this as paused, not missing."
    )
    /// Never yanks the user into the app; the point of the intent is to act in place.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        CaptureIntentBridge.request(.paused)
        return .result(dialog: "Capture paused.")
    }
}

/// Resume capture. Refuses to resume from `off`: turning capture on is a consent-bearing
/// decision that belongs in the app (anti-B3), so we say so instead of silently enabling it.
struct ResumeCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Capture"
    static var description = IntentDescription(
        "Starts capturing audio from your Pebble again."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard CaptureIntentBridge.effectiveIntent() != .off else {
            return .result(dialog: "Capture is off. Open Pebble Audio to turn it back on.")
        }
        CaptureIntentBridge.request(.active)
        return .result(dialog: "Capture resumed.")
    }
}

/// The Control Center / Shortcuts toggle. `SetValueIntent` is what `ControlWidgetToggle`
/// requires: the control hands us the value it wants, we record it, the app applies it.
struct ToggleCaptureIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Toggle Capture"
    static var description = IntentDescription("Pauses or resumes capture from your Pebble.")
    static var openAppWhenRun: Bool = false

    /// True = capturing, false = paused.
    @Parameter(title: "Capturing")
    var value: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // From `off`, only the app can turn capture on — report the real state, don't pretend.
        if value, CaptureIntentBridge.effectiveIntent() == .off {
            return .result(dialog: "Capture is off. Open Pebble Audio to turn it back on.")
        }
        CaptureIntentBridge.request(value ? .active : .paused)
        return .result(dialog: value ? "Capture resumed." : "Capture paused.")
    }
}
