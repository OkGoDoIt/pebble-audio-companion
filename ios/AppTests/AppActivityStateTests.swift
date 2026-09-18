import Foundation
import Testing

// The label derivation is the battery gate's vocabulary: MetricKit aggregates cost per label, so
// a wrong label silently misattributes an hour of CPU. The full 2^4 input matrix is pinned here,
// case by case, so precedence can never drift without a test naming the exact combination.
struct AppActivityStateTests {
    typealias Inputs = AppActivityState.Inputs

    // MARK: - The whole matrix

    static let matrix: [(Inputs, AppActivityState)] = [
        // foreground, streaming, pipeline, playback
        (Inputs(foreground: false, streaming: false, pipelineWindowOpen: false, playback: false), .idleBackground),
        (Inputs(foreground: false, streaming: false, pipelineWindowOpen: false, playback: true), .playback),
        (Inputs(foreground: false, streaming: false, pipelineWindowOpen: true, playback: false), .pipelineBackground),
        (Inputs(foreground: false, streaming: false, pipelineWindowOpen: true, playback: true), .playback),
        (Inputs(foreground: false, streaming: true, pipelineWindowOpen: false, playback: false), .capturingBackground),
        (Inputs(foreground: false, streaming: true, pipelineWindowOpen: false, playback: true), .playback),
        (Inputs(foreground: false, streaming: true, pipelineWindowOpen: true, playback: false), .pipelineBackground),
        (Inputs(foreground: false, streaming: true, pipelineWindowOpen: true, playback: true), .playback),
        (Inputs(foreground: true, streaming: false, pipelineWindowOpen: false, playback: false), .idleForeground),
        (Inputs(foreground: true, streaming: false, pipelineWindowOpen: false, playback: true), .playback),
        (Inputs(foreground: true, streaming: false, pipelineWindowOpen: true, playback: false), .idleForeground),
        (Inputs(foreground: true, streaming: false, pipelineWindowOpen: true, playback: true), .playback),
        (Inputs(foreground: true, streaming: true, pipelineWindowOpen: false, playback: false), .capturingForeground),
        (Inputs(foreground: true, streaming: true, pipelineWindowOpen: false, playback: true), .playback),
        (Inputs(foreground: true, streaming: true, pipelineWindowOpen: true, playback: false), .capturingForeground),
        (Inputs(foreground: true, streaming: true, pipelineWindowOpen: true, playback: true), .playback),
    ]

    @Test("every one of the 16 input combinations maps to the documented label")
    func wholeMatrix() {
        #expect(Self.matrix.count == 16)
        for (inputs, expected) in Self.matrix {
            #expect(
                AppActivityState.derive(inputs) == expected,
                "\(AppActivityState.describe(inputs)) → \(expected.rawValue)")
        }
    }

    @Test("the matrix covers every distinct input combination exactly once")
    func matrixIsExhaustive() {
        var seen = Set<[Bool]>()
        for (inputs, _) in Self.matrix {
            seen.insert([inputs.foreground, inputs.streaming, inputs.pipelineWindowOpen, inputs.playback])
        }
        #expect(seen.count == 16)
    }

    @Test("every label is reachable")
    func everyLabelReachable() {
        let reached = Set(Self.matrix.map(\.1))
        #expect(reached == Set(AppActivityState.allCases))
    }

    // MARK: - Precedence, stated as rules

    @Test("playback wins over everything, foreground or not")
    func playbackWins() {
        for foreground in [false, true] {
            for streaming in [false, true] {
                for pipeline in [false, true] {
                    let inputs = Inputs(
                        foreground: foreground, streaming: streaming,
                        pipelineWindowOpen: pipeline, playback: true)
                    #expect(AppActivityState.derive(inputs) == .playback)
                }
            }
        }
    }

    @Test("a pipeline window is a background label only — the foreground decides in front")
    func pipelineWindowIsBackgroundOnly() {
        #expect(AppActivityState.derive(Inputs(foreground: false, pipelineWindowOpen: true)) == .pipelineBackground)
        #expect(AppActivityState.derive(Inputs(foreground: true, pipelineWindowOpen: true)) == .idleForeground)
        #expect(
            AppActivityState.derive(Inputs(foreground: true, streaming: true, pipelineWindowOpen: true))
                == .capturingForeground)
    }

    @Test("a pipeline window outranks capture in the background")
    func pipelineOutranksCapture() {
        #expect(
            AppActivityState.derive(Inputs(foreground: false, streaming: true, pipelineWindowOpen: true))
                == .pipelineBackground)
    }

    // MARK: - Wire form

    @Test("raw values are the wire labels the cost report greps for")
    func rawValues() {
        #expect(AppActivityState.idleForeground.rawValue == "idle-fg")
        #expect(AppActivityState.idleBackground.rawValue == "idle-bg")
        #expect(AppActivityState.capturingForeground.rawValue == "capturing-fg")
        #expect(AppActivityState.capturingBackground.rawValue == "capturing-bg")
        #expect(AppActivityState.pipelineBackground.rawValue == "pipeline-bg")
        #expect(AppActivityState.playback.rawValue == "playback")
    }

    @Test("the inputs describe themselves as key=value tokens")
    func describe() {
        #expect(
            AppActivityState.describe(Inputs(foreground: true, streaming: false, pipelineWindowOpen: true, playback: false))
                == "fg=1 stream=0 pipeline=1 play=0")
        #expect(AppActivityState.describe(Inputs()) == "fg=0 stream=0 pipeline=0 play=0")
    }
}

// The tracker turns four chatty sources into a quiet sequence of DISTINCT labels. StateReporting
// rejects a repeated transition to the same label, so "only on change" is the contract.
struct AppActivityTrackerTests {
    typealias Inputs = AppActivityState.Inputs

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(AppActivityState, Inputs)] = []
        var events: [(AppActivityState, Inputs)] { lock.withLock { _events } }
        var labels: [AppActivityState] { events.map(\.0) }
        func record(_ state: AppActivityState, _ inputs: Inputs) {
            lock.withLock { _events.append((state, inputs)) }
        }
    }

    @Test("nothing is reported until prime or the first update")
    func silentUntilPrimed() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        #expect(tracker.current == nil)
        #expect(recorder.events.isEmpty)
        #expect(tracker.prime() == .idleBackground)
        #expect(recorder.labels == [.idleBackground])
        #expect(tracker.current == .idleBackground)
    }

    @Test("prime is idempotent")
    func primeTwice() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        tracker.prime()
        #expect(tracker.prime() == nil)
        #expect(recorder.labels == [.idleBackground])
    }

    @Test("the initial inputs seed the first label")
    func initialInputs() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(
            initial: Inputs(foreground: true, streaming: true), sink: recorder.record)
        #expect(tracker.prime() == .capturingForeground)
        #expect(recorder.events.first?.1 == Inputs(foreground: true, streaming: true))
    }

    @Test("an update that leaves the label unchanged reports nothing")
    func unchangedLabelIsSilent() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        tracker.prime()
        // Re-emissions of the same value: a conflated stream replaying, didBecomeActive again.
        #expect(tracker.update { $0.foreground = false } == nil)
        #expect(tracker.update { $0.streaming = false } == nil)
        // A change that does not alter the label under the precedence rules.
        tracker.update { $0.playback = true }
        #expect(tracker.update { $0.streaming = true } == nil)
        #expect(recorder.labels == [.idleBackground, .playback])
    }

    @Test("a typical day: launch headless, stream, come to the front, play, go back, a window")
    func typicalDay() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        tracker.prime()
        tracker.update { $0.streaming = true }
        tracker.update { $0.foreground = true }
        tracker.update { $0.foreground = true }  // didBecomeActive posts again after a banner
        tracker.update { $0.playback = true }
        tracker.update { $0.playback = false }
        tracker.update { $0.foreground = false }
        tracker.update { $0.pipelineWindowOpen = true }
        tracker.update { $0.pipelineWindowOpen = false }
        tracker.update { $0.streaming = false }
        #expect(
            recorder.labels == [
                .idleBackground, .capturingBackground, .capturingForeground, .playback,
                .capturingForeground, .capturingBackground, .pipelineBackground,
                .capturingBackground, .idleBackground,
            ])
    }

    @Test("the sink receives the inputs that produced the label")
    func sinkSeesInputs() {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        tracker.update { $0.foreground = true; $0.pipelineWindowOpen = true }
        #expect(recorder.events.last?.0 == .idleForeground)
        #expect(recorder.events.last?.1 == Inputs(foreground: true, pipelineWindowOpen: true))
        #expect(tracker.snapshot == Inputs(foreground: true, pipelineWindowOpen: true))
    }

    @Test("concurrent updates never lose a transition or report a duplicate")
    func concurrentUpdates() async {
        let recorder = Recorder()
        let tracker = AppActivityTracker(sink: recorder.record)
        tracker.prime()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { tracker.update { $0.streaming = (i % 2 == 0) } }
            }
        }
        // Whatever the interleaving, consecutive reported labels always differ — the sink runs
        // under the tracker's lock, so the recorder sees transitions in the order they happened.
        let labels = recorder.labels
        for (a, b) in zip(labels, labels.dropFirst()) { #expect(a != b) }
        // And the last report agrees with the inputs as they ended up.
        #expect(tracker.current == AppActivityState.derive(tracker.snapshot))
        #expect(labels.last == tracker.current)
    }
}
