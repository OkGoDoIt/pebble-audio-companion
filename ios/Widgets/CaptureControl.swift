import AppIntents
import SwiftUI
import WidgetKit

/// Control Center: one toggle that starts, pauses or resumes capture (plan 6.8 — "Control
/// Center exposes the same intents"). It writes through `CaptureIntentBridge` like every other
/// surface; the app applies it through the runtime's own start/pause path.
///
/// The control's value shows what the user last ASKED for, so a tap looks answered immediately
/// even while the app is still applying it — but the LABEL distinguishes the three real states,
/// because a control that says "Paused" when capture is actually off is a small, avoidable lie
/// about a microphone.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedAppGroup.captureControlKind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Pebble Capture",
                isOn: value.isCapturing,
                action: ToggleCaptureIntent()
            ) { isOn in
                Label(
                    isOn ? "Capturing" : (value.isOff ? "Not recording" : "Paused"),
                    systemImage: isOn ? "waveform" : "pause.fill"
                )
            }
            .tint(Tokens.tint)
        }
        .displayName("Pebble Capture")
        .description("Start, pause, or resume Pebble capture.")
    }

    /// Two bits, not one: `isCapturing` drives the switch, `isOff` only changes what the off
    /// position is CALLED.
    struct Value {
        var isCapturing: Bool
        var isOff: Bool
    }

    struct Provider: ControlValueProvider {
        /// Gallery preview: showing "capturing" is the state the control is for.
        let previewValue = Value(isCapturing: true, isOff: false)

        func currentValue() async throws -> Value {
            let intent = CaptureIntentBridge.effectiveIntent()
            return Value(isCapturing: intent.isActive, isOff: intent == .off)
        }
    }
}
