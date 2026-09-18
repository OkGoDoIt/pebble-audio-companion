import Foundation
import Testing

// The hooks are the only path by which "a pipeline window is open" and "playback is running"
// reach the activity tracker, and they are called from code that does not know about telemetry.
// Set semantics (overlapping windows, duplicate edges) are what keep a phantom window from
// mislabelling a whole night of capture as `pipeline-bg`.
//
// `.serialized`: the hooks are process-global state.
@Suite(.serialized)
struct TelemetryEventsTests {
    @Test("a window opens and closes")
    func openClose() {
        TelemetryEvents.reset()
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == false)
        TelemetryEvents.pipelineWindow(.backgroundProcessing, open: true)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == true)
        TelemetryEvents.pipelineWindow(.backgroundProcessing, open: false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == false)
    }

    @Test("overlapping windows stay open until the last one ends")
    func overlappingWindows() {
        TelemetryEvents.reset()
        TelemetryEvents.pipelineWindow(.backgroundProcessing, open: true)
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: true)
        TelemetryEvents.pipelineWindow(.backgroundProcessing, open: false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == true)
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == false)
    }

    @Test("duplicate edges are harmless: opened twice, then finished AND expired")
    func duplicateEdges() {
        TelemetryEvents.reset()
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: true)
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: true)
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == false)
        TelemetryEvents.pipelineWindow(.chargingCatchUp, open: false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == false)
    }

    @Test("playback is independent of the windows")
    func playback() {
        TelemetryEvents.reset()
        TelemetryEvents.playback(active: true)
        TelemetryEvents.pipelineWindow(.backgroundProcessing, open: true)
        #expect(TelemetryEvents.state.value == TelemetryEvents.HookState(
            openPipelineWindows: [.backgroundProcessing], playbackActive: true))
        TelemetryEvents.playback(active: false)
        #expect(TelemetryEvents.state.value.playbackActive == false)
        #expect(TelemetryEvents.state.value.pipelineWindowOpen == true)
        TelemetryEvents.reset()
    }

    @Test("the stream replays the current state and then emits only changes")
    func streamSemantics() async {
        TelemetryEvents.reset()
        TelemetryEvents.playback(active: true)
        var iterator = TelemetryEvents.state.stream().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.playbackActive == true)
        TelemetryEvents.playback(active: true)  // no change → no emission
        TelemetryEvents.playback(active: false)
        let second = await iterator.next()
        #expect(second?.playbackActive == false)
        TelemetryEvents.reset()
    }
}
