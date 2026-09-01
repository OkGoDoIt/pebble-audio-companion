import Foundation
import Receiver
import StatusUI
import Testing
import Transcription

/// The four honest answers behind what used to be one calm line.
///
/// Roger watched "Listening — words appear here as they are recognized" for nineteen minutes
/// while no audio had reached the phone for eleven of them. The line was not wrong about the
/// transcript being empty; it was wrong about why, and it was the only thing the screen could
/// say for any reason at all.
@Suite("live transcript status") @MainActor
struct LiveTranscriptStatusTests {

    private func status(
        transcriptsConfigured: Bool = true,
        verdict: StreamVerdict = .hearingAudio,
        mode: TranscriptionMode = .localFirst,
        cloud: CloudHealthStatus = .ok,
        liveLocalFailing: Bool = false
    ) -> LiveTranscriptStatus {
        LiveTodayDataSource.liveStatus(
            transcriptsConfigured: transcriptsConfigured,
            verdict: verdict,
            mode: mode,
            cloudStatus: cloud,
            liveLocalFailing: liveLocalFailing
        )
    }

    @Test func audioArrivingAndNothingRecognisedYetIsTheCalmLine() {
        #expect(status() == .listening)
        #expect(status().isUneventful)
        #expect(status().rowLine == nil)  // Today's status card is right above it.
    }

    @Test func aWatchWeAreNotHearingSaysSo() {
        #expect(status(verdict: .unverified) == .notHearingWatch)
        // The watch answered and said it is NOT capturing — also not something to call
        // "listening", whatever the Live badge says.
        #expect(status(verdict: .watchSaysNotStreaming) == .notHearingWatch)
        #expect(status(verdict: .unverified).isUneventful == false)
    }

    @Test func suppressedSilenceIsQuietAndNeverLoss() {
        // The watch is capturing and deliberately sending nothing. This is the ONE state that
        // must never read as a failure (Q6) — and it is also the state the old line came
        // closest to describing correctly.
        #expect(status(verdict: .watchSaysStreaming) == .quiet)
        #expect(status(verdict: .watchSaysStreaming).line == Copy.Live.quiet)
    }

    @Test func transcriptionThatWasNeverSetUpOutranksEverything() {
        // Nothing will ever appear here, so saying "listening" is the least useful truth
        // available — and the audio IS being recorded, which is the part to lead with.
        #expect(status(transcriptsConfigured: false) == .transcriptsOff)
        #expect(status(transcriptsConfigured: false, verdict: .unverified) == .transcriptsOff)
        #expect(status(transcriptsConfigured: false).line.contains("still recorded"))
    }

    @Test func aFailingLiveEngineIsOnlyBlamedWhileAudioIsArriving() {
        // Audio arriving + the only configured engine failing = the engine's trouble.
        #expect(status(mode: .remoteOnly, cloud: .failed) == .liveTranscriptionDown)
        #expect(status(liveLocalFailing: true) == .liveTranscriptionDown)

        // But not hearing the watch outranks it: with no audio there is nothing to transcribe,
        // and blaming the engine would send someone to fix the wrong thing.
        #expect(status(verdict: .unverified, mode: .remoteOnly, cloud: .failed) == .notHearingWatch)
    }

    @Test func aFallbackModeIsNotCalledDownWhileItsOtherPathWorks() {
        // Remote-FIRST has a real on-device fallback, and the screen shows whichever produced
        // words. Calling live transcription down while it is quietly working would be its own
        // kind of lie.
        #expect(status(mode: .remoteFirst, cloud: .failed) == .listening)
        #expect(status(mode: .localFirst, cloud: .failed) == .listening)
        #expect(status(mode: .remoteOnly, cloud: .ok) == .listening)
    }

    @Test func everyStateHasItsOwnWords() {
        let all: [LiveTranscriptStatus] = [
            .listening, .quiet, .notHearingWatch, .transcriptsOff, .liveTranscriptionDown,
        ]
        #expect(Set(all.map(\.line)).count == all.count)
        // ...and the four that are not "listening" also have a Today-row form.
        #expect(all.filter { $0.rowLine != nil }.count == all.count - 1)
    }
}
