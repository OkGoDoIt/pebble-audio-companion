import Foundation

/// What the app is doing, as one of six stable labels.
///
/// On iOS 27 these are reported through StateReporting so MetricKit aggregates CPU, memory and
/// terminations PER STATE — and the battery gate (`scripts/phone-cost-report.sh`) can read "what
/// does an hour of background capture cost" straight off a report instead of reconstructing it
/// from heartbeat deltas. The label set is deliberately tiny and low-cardinality: MetricKit
/// fragments its aggregation across every distinct label it sees, and a report split ten ways
/// says nothing about any of them.
///
/// Each label names the DOMINANT cost of the moment, which is why they take precedence in the
/// order below rather than combining:
///
/// - `playback`: a person is on the Conversation screen listening; audio output is running.
/// - `pipeline-bg`: a BGProcessing or charging catch-up window is open in the background. This
///   is the sanctioned CPU burst (regroup, transcription, enrichment, recap) and the one state
///   allowed to be expensive; attributing it separately keeps it from being read as a leak in
///   `capturing-bg`.
/// - `capturing-fg` / `capturing-bg`: the watch is streaming audio to us. This is the steady
///   cost the product lives on — Bluetooth notifications, Speex frames to disk — and the
///   background variant is the number that decides whether the app can stay on a phone.
/// - `idle-fg` / `idle-bg`: nothing above is true. The background variant is the floor: a
///   resident process waiting for the watch should cost nothing measurable.
///
/// A pipeline window that is still open when the person foregrounds the app is labelled by the
/// foreground: what a person is looking at is a different cost regime, and there is no
/// `pipeline-fg` because the foreground pass is not a window-bounded burst.
enum AppActivityState: String, CaseIterable, Sendable {
    case idleForeground = "idle-fg"
    case idleBackground = "idle-bg"
    case capturingForeground = "capturing-fg"
    case capturingBackground = "capturing-bg"
    case pipelineBackground = "pipeline-bg"
    case playback

    /// The four facts the label is derived from. Every one of them is published by something
    /// that already exists: UIKit's foreground notifications, the receiver's session state, the
    /// BGTask handlers (through `TelemetryEvents`) and the player (likewise).
    struct Inputs: Equatable, Sendable {
        var foreground = false
        var streaming = false
        var pipelineWindowOpen = false
        var playback = false

        init(
            foreground: Bool = false, streaming: Bool = false,
            pipelineWindowOpen: Bool = false, playback: Bool = false
        ) {
            self.foreground = foreground
            self.streaming = streaming
            self.pipelineWindowOpen = pipelineWindowOpen
            self.playback = playback
        }
    }

    /// The one decision, kept pure so its whole matrix is a test.
    static func derive(_ inputs: Inputs) -> AppActivityState {
        if inputs.playback { return .playback }
        if inputs.pipelineWindowOpen, !inputs.foreground { return .pipelineBackground }
        switch (inputs.streaming, inputs.foreground) {
        case (true, true): return .capturingForeground
        case (true, false): return .capturingBackground
        case (false, true): return .idleForeground
        case (false, false): return .idleBackground
        }
    }

    /// `fg=1 stream=0 pipeline=0 play=0` — the inputs, for the log line beside the label.
    static func describe(_ inputs: Inputs) -> String {
        "fg=\(inputs.foreground ? 1 : 0) stream=\(inputs.streaming ? 1 : 0) "
            + "pipeline=\(inputs.pipelineWindowOpen ? 1 : 0) play=\(inputs.playback ? 1 : 0)"
    }
}

/// Folds the input sources into one label and reports a transition ONLY when the label changes.
///
/// The "only on change" rule is not hygiene: StateReporting treats a repeated transition to the
/// same label as invalid, and every input source here can re-emit its current value (a conflated
/// stream replays on subscription; UIKit posts `didBecomeActive` on every return). The tracker is
/// the one place that turns four chatty sources into a quiet sequence of distinct states.
///
/// Thread-safe: inputs arrive from the receiver's stream, the main actor and whichever task a
/// hook is called from, and the lock keeps the read-modify-write of `inputs` atomic. The sink is
/// invoked INSIDE the lock, deliberately: two updates racing on different threads would
/// otherwise be free to deliver their transitions out of order, and "X, then X" is exactly the
/// repeat StateReporting rejects. The sink is a reporter call and a log line — microseconds —
/// and it must not call back into the tracker.
final class AppActivityTracker: @unchecked Sendable {
    typealias Sink = @Sendable (AppActivityState, AppActivityState.Inputs) -> Void

    private let lock = NSLock()
    private var inputs: AppActivityState.Inputs
    private var reported: AppActivityState?
    private let sink: Sink

    init(initial: AppActivityState.Inputs = .init(), sink: @escaping Sink) {
        self.inputs = initial
        self.sink = sink
    }

    /// The label the tracker last reported, or nil before the first `update`/`prime`.
    var current: AppActivityState? { lock.withLock { reported } }

    /// The inputs as last applied — for tests and the diagnostics line.
    var snapshot: AppActivityState.Inputs { lock.withLock { inputs } }

    /// Applies a change to the inputs. Returns the new label when it differs from the last one
    /// reported (and has reported it), nil when nothing changed.
    @discardableResult
    func update(_ change: (inout AppActivityState.Inputs) -> Void) -> AppActivityState? {
        lock.withLock {
            change(&inputs)
            let next = AppActivityState.derive(inputs)
            guard next != reported else { return nil }
            reported = next
            sink(next, inputs)
            return next
        }
    }

    /// Reports the current label if nothing has been reported yet, so the reporter always has a
    /// state from the moment it starts rather than from the first change.
    @discardableResult
    func prime() -> AppActivityState? {
        update { _ in }
    }
}
