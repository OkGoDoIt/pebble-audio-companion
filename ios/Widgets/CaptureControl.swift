import AppIntents
import SwiftUI
import WidgetKit

/// Control Center: one toggle that pauses or resumes capture (plan 6.8 — "Control Center
/// exposes the same intents"). It writes through `CaptureIntentBridge` like every other
/// surface; the app applies it. The control's value shows what the user last ASKED for, so a
/// tap looks answered immediately even while the app is still applying it.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedAppGroup.captureControlKind,
            provider: Provider()
        ) { isCapturing in
            ControlWidgetToggle(
                "Pebble Capture",
                isOn: isCapturing,
                action: ToggleCaptureIntent()
            ) { isOn in
                // The control states its own truth: "Capturing" or "Paused", never a bare icon.
                Label(
                    isOn ? "Capturing" : "Paused",
                    systemImage: isOn ? "waveform" : "pause.fill"
                )
            }
            .tint(Tokens.tint)
        }
        .displayName("Pebble Capture")
        .description("Pause or resume Pebble capture.")
    }

    struct Provider: ControlValueProvider {
        /// Gallery preview: showing "capturing" is the state the control is for.
        let previewValue = true

        func currentValue() async throws -> Bool {
            CaptureIntentBridge.effectiveIntent().isActive
        }
    }
}
