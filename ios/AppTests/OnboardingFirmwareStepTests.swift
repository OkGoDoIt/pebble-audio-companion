import Foundation
import Testing

// Onboarding's firmware step: a watch that answers without the audio service is not a failure
// card any more, it is the install. While that step waits for the watch to restart into the new
// build, every check is quiet — a watch mid-install looks exactly like one that is missing, out
// of range, or still on stock firmware, and none of those may throw a failure card over the
// "Installing on your watch" screen. Only a watch that comes back offering the service moves
// the flow on, and it lands on the on-watch prompt saying the install worked.
@Suite("onboarding firmware step") @MainActor
struct OnboardingFirmwareStepTests {

    /// Replays one scripted attempt per `pairingUpdates()` call; an exhausted script finishes
    /// at once.
    private final class ScriptedSource: WatchPairingSource, @unchecked Sendable {
        private var attempts: [[PairingUpdate]]
        private(set) var cancelled = false

        init(_ attempts: [[PairingUpdate]]) { self.attempts = attempts }

        func pairingUpdates() -> AsyncStream<PairingUpdate> {
            let updates = attempts.isEmpty ? [] : attempts.removeFirst()
            return AsyncStream { continuation in
                for update in updates { continuation.yield(update) }
                continuation.finish()
            }
        }

        func cancelPairing() async { cancelled = true }
    }

    /// Lets the attempt's task drain its stream.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aWatchWithoutTheServiceGetsTheInstallAndOnlyItsReturnMovesOn() async {
        let source = ScriptedSource([
            // Connect: the watch answers, without the audio service.
            [.searching, .failed(.cantSendAudio)],
            // Mid-install, the watch restarting: nothing found.
            [.searching, .failed(.noPebbleFound)],
            // The Pebble app ignored the file: still stock firmware.
            [.searching, .failed(.cantSendAudio)],
            // Restarted into the audio firmware: the watch is asking.
            [.searching, .confirmOnWatch],
        ])
        let model = OnboardingViewModel(source: source)

        model.beginPairing()
        await settle()
        #expect(model.phase == .firmware)
        #expect(model.pairing == .idle)

        model.checkForAudioFirmware()
        await settle()
        #expect(model.phase == .firmware, "a watch mid-install is not a failure")
        #expect(model.pairing == .idle)

        model.checkForAudioFirmware()
        await settle()
        #expect(model.phase == .firmware, "still stock firmware: keep waiting")
        #expect(!model.firmwareJustInstalled)

        model.checkForAudioFirmware()
        await settle()
        #expect(model.phase == .confirm)
        #expect(model.pairing == .confirmOnWatch)
        #expect(model.firmwareJustInstalled)
    }

    @Test func otherFailuresStillShowTheirCardAndCancelLeavesNothingBehind() async {
        let source = ScriptedSource([
            [.searching, .failed(.declined)],
            [.searching, .failed(.cantSendAudio)],
        ])
        let model = OnboardingViewModel(source: source)

        model.beginPairing()
        await settle()
        #expect(model.phase == .confirm)
        #expect(model.pairing == .failed(.declined))

        model.startRequest()
        await settle()
        #expect(model.phase == .firmware)

        model.cancelPairing()
        #expect(model.phase == .connect)
        #expect(!model.firmwareJustInstalled)
        // The checks only run on the firmware step.
        model.checkForAudioFirmware()
        await settle()
        #expect(model.phase == .connect)
    }
}
