import AppIntents
import Foundation

// Pause/Resume App Intents (plan 6.8). This file compiles into BOTH the app and the widget
// extension, because Control Center's toggle and the widgets' interactive buttons live in the
// extension and must invoke the same intent types the app and Siri use.
//
// What an intent does is narrow on purpose: it writes the desired tri-state to the App Group,
// posts the Darwin notification, and then WAITS to be told the app applied it. The app — alive
// in the background via bluetooth-central — applies it through the normal ReceiverService path
// (`CompanionRuntime.startCapture` / `setCaptureIntent`, which dial the link rather than only
// setting a preference). The extension never touches BLE and never starts a session itself.
//
// Two behaviours here are deliberate reversals of the original 6.8 wiring:
//
//  1. `off → active` is HONOURED. It used to be refused as a consent question that belonged in
//     the app, but a Control Center toggle is not a side effect — it is the user pressing a
//     switch. The consent that matters is still enforced where it always was: the watch
//     requires an on-watch confirmation for a first authorization and fails closed without it.
//     A switch that silently does nothing is worse than the risk it was guarding.
//  2. An unanswered request is never reported as success. Every intent now WAITS for the app to
//     consume the request before it says anything. Where the escalation is available (the app's
//     own copy, used by Siri and Shortcuts) it asks the system to continue in the foreground and
//     the app applies the request as it activates. Where it is not (the extension's copy, used
//     by Control Center and widget buttons) the request stays queued and the dialog says exactly
//     that. Either way the user is never told capture changed when it did not.
//
// Note on the strings: every `title` / `IntentDescription` / dialog below is an inline literal.
// `appintentsmetadataprocessor` extracts them at build time and rejects constants, so these
// cannot be routed through `Copy` — the one sanctioned exception to the single string catalog.

// `ForegroundContinuableIntent` is unavailable in app extensions, so the escalation exists only
// in the app's copy of these types. That is not just a workaround, it matches where each copy
// runs: Siri and Shortcuts launch the app (in the background) to perform an app intent, and it
// can then ask to come forward; a widget button and a Control Center toggle are performed
// inside the widget extension, which has no way to launch anything and must say so plainly.
#if WIDGET_EXTENSION
    /// Shared delivery for every capture intent: request → wait for the app to answer.
    protocol CaptureRequestingIntent: AppIntent {}

    extension CaptureRequestingIntent {
        /// The extension cannot launch the app. The request stays in the mailbox and will be
        /// applied the next time the app runs; the caller reports that honestly rather than
        /// claiming the watch was reached.
        func escalate() async -> Bool { false }
    }
#else
    /// Shared delivery for every capture intent: request → wait for the app to answer →
    /// escalate by asking the system to continue this intent in the foreground.
    protocol CaptureRequestingIntent: ForegroundContinuableIntent {}

    extension CaptureRequestingIntent {
        func escalate() async -> Bool {
            (try? await requestToContinueInForeground()) != nil
        }
    }
#endif

extension CaptureRequestingIntent {
    /// Posts `intent` and reports whether the app actually took it.
    ///
    /// Returns `.applied` when a live app consumed the request, `.opened` when the app had to
    /// be brought forward to do it, and `.unreachable` when neither worked — the caller must
    /// say so rather than claim success.
    func deliver(_ intent: SharedCaptureIntent) async -> CaptureDeliveryOutcome {
        CaptureIntentBridge.request(intent)
        if await CaptureIntentBridge.waitForApply() { return .applied }

        // Nothing read the mailbox, so no app process is alive. Ask the system to continue this
        // intent in the foreground; the app applies the still-pending request as it activates.
        guard await escalate() else { return .unreachable }
        return await CaptureIntentBridge.waitForApply(timeoutMs: 4000) ? .opened : .unreachable
    }
}

enum CaptureDeliveryOutcome {
    case applied
    case opened
    case unreachable
}

/// Pause capture. Idempotent — pausing an already-paused watch is a no-op with the same answer.
struct PauseCaptureIntent: AppIntent, CaptureRequestingIntent {
    static var title: LocalizedStringResource = "Pause Capture"
    static var description = IntentDescription(
        "Stops capturing audio from your Pebble. Coverage shows this as paused, not missing."
    )
    /// Never yanks the user into the app unless the app turns out to be the only way to act.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await deliver(.paused) {
        case .applied, .opened:
            return .result(dialog: "Capture paused.")
        case .unreachable:
            // The request is still in the mailbox and will be applied at the next launch —
            // say that, rather than "paused" (untrue) or "failed" (also untrue).
            return .result(dialog: "Pebble Audio is not running. Capture will pause when you open it.")
        }
    }
}

/// Resume capture — including from `off`, which goes through the app's normal Start path (it
/// arms exactly one on-watch enable prompt and then dials the link).
struct ResumeCaptureIntent: AppIntent, CaptureRequestingIntent {
    static var title: LocalizedStringResource = "Resume Capture"
    static var description = IntentDescription(
        "Starts capturing audio from your Pebble again."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await deliver(.active) {
        case .applied, .opened:
            return .result(dialog: "Capture resumed.")
        case .unreachable:
            return .result(dialog: "Pebble Audio is not running. Capture will resume when you open it.")
        }
    }
}

/// The Control Center / Shortcuts toggle. `SetValueIntent` is what `ControlWidgetToggle`
/// requires: the control hands us the value it wants, we record it, the app applies it.
struct ToggleCaptureIntent: SetValueIntent, CaptureRequestingIntent {
    static var title: LocalizedStringResource = "Toggle Capture"
    static var description = IntentDescription("Pauses or resumes capture from your Pebble.")
    static var openAppWhenRun: Bool = false

    /// True = capturing, false = paused.
    @Parameter(title: "Capturing")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await deliver(value ? .active : .paused) {
        case .applied, .opened:
            return .result(dialog: value ? "Capture resumed." : "Capture paused.")
        case .unreachable:
            return .result(
                dialog: "Pebble Audio is not running. This will apply when you open it."
            )
        }
    }
}
