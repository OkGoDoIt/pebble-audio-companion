import CompanionRuntime
import Foundation
import Testing

// The residency re-assert on `didEnterBackground` must not run under a playing recording: it
// flips the shared AVAudioSession to the mixable residency category while the playback engine
// renders, which ends the listening session (and its Lock Screen controls) exactly when the
// phone is locked mid-listen. The app sets the hold while playing and re-asserts itself when
// playback ends; this pins the seam between the two.

@Suite struct PlaybackHoldTests {

    @Test func theHoldIsAPlainFlag() {
        let hold = PlaybackHold()
        #expect(!hold.isActive)
        hold.set(true)
        #expect(hold.isActive)
        hold.set(false)
        #expect(!hold.isActive)
    }

    @Test func theReceiverSkipsTheReassertWhilePlaybackHoldsTheSession() async throws {
        let fixture = try RuntimeFixture()
        fixture.residency.setWanted(true)
        #expect(fixture.residency.state.value == .held)

        fixture.receiver.playbackHold.set(true)
        #expect(!fixture.receiver.reassertResidencyAfterPlayback(), "playing: skipped")

        fixture.receiver.playbackHold.set(false)
        #expect(fixture.receiver.reassertResidencyAfterPlayback(), "ended: re-asserted")
        #expect(fixture.residency.state.value == .held)
        await fixture.runtime.stop()
    }
}
