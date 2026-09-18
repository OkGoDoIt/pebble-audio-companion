import Foundation
import Receiver

/// The two activity inputs nothing in the app publishes today, exposed as static hooks.
///
/// The receiver's session state and UIKit's foreground notifications already tell the activity
/// tracker whether we are streaming and whether a person is looking. The other two facts live in
/// code this file's owner does not edit: a BGTask window opening and closing is known only inside
/// `AppComposition.run(backgroundTask:)` / `run(chargingTask:)`, and playback only inside the
/// Conversation screen's `PlayerModel`. Rather than parse the flight log for "window opened", the
/// owners of those places call these two functions — one line each, no dependency on the
/// telemetry types, safe on every OS version (the state simply goes unread on iOS 26).
///
/// Integration points (for the composition root and the player, respectively):
///
///     // AppComposition.run(backgroundTask:) — beside "BGProcessing window opened"
///     TelemetryEvents.pipelineWindow(.backgroundProcessing, open: true)
///     // … and beside "BGProcessing window finished" / "… expired"
///     TelemetryEvents.pipelineWindow(.backgroundProcessing, open: false)
///     // AppComposition.run(chargingTask:) — the same pair with `.chargingCatchUp`
///
///     // PlayerModel — when `playing` flips
///     TelemetryEvents.playback(active: playing)
///
/// Windows are a SET, not a counter: the processing and charging windows can overlap, and a
/// duplicate "opened" or a "finished" after an "expired" must not leave a phantom window open.
enum TelemetryEvents {
    enum PipelineWindow: String, Sendable, CaseIterable {
        case backgroundProcessing = "bgprocessing"
        case chargingCatchUp = "charging"
    }

    struct HookState: Equatable, Sendable {
        var openPipelineWindows: Set<PipelineWindow> = []
        var playbackActive = false

        /// True while any pipeline window is open.
        var pipelineWindowOpen: Bool { !openPipelineWindows.isEmpty }
    }

    /// The current hook state; conflated, replays on subscription, emits only on change — the
    /// same StateFlow semantics the receiver's own state uses.
    static let state = StateSubject<HookState>(HookState())

    private static let lock = NSLock()

    /// A BGProcessing or charging catch-up window opened (`open: true`) or ended (`false`).
    static func pipelineWindow(_ window: PipelineWindow, open: Bool) {
        mutate { hooks in
            if open { hooks.openPipelineWindows.insert(window) } else { hooks.openPipelineWindows.remove(window) }
        }
    }

    /// Conversation playback started (`true`) or paused/stopped (`false`).
    static func playback(active: Bool) {
        mutate { $0.playbackActive = active }
    }

    /// Tests only: back to the launch state.
    static func reset() {
        mutate { $0 = HookState() }
    }

    /// `StateSubject.value` is atomic per get and per set, not across a read-modify-write; the
    /// lock makes the pair one step so two hooks racing cannot drop each other's change.
    private static func mutate(_ change: (inout HookState) -> Void) {
        lock.withLock {
            var next = state.value
            change(&next)
            state.value = next
        }
    }
}
