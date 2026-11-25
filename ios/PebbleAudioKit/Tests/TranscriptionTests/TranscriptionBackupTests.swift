import Foundation
import Testing

@testable import Transcription

// Where audio goes while the chosen provider's account is refused. The rule that matters most:
// it only ever goes to a provider the person named.

@Suite struct TranscriptionBackupTests {
    private func provider(
        _ backup: TranscriptionBackup, held: Set<CloudProvider>,
        keys: Set<CloudProvider> = [.soniox, .openAi]
    ) -> CloudProvider {
        TranscriptionRouting.provider(
            selected: .soniox, backup: backup, isHeld: { held.contains($0) },
            hasKey: { keys.contains($0) })
    }

    @Test func theBackupStandsInOnlyWhileTheChosenAccountIsHeld() {
        #expect(provider(.openAi, held: []) == .soniox)
        #expect(provider(.openAi, held: [.soniox]) == .openAi)
    }

    @Test func nothingGoesToAProviderThatWasNotNamedOrCannotTakeIt() {
        #expect(provider(.none, held: [.soniox]) == .soniox)
        #expect(provider(.onDevice, held: [.soniox]) == .soniox)
        #expect(provider(.soniox, held: [.soniox]) == .soniox)
        #expect(provider(.openAi, held: [.soniox], keys: [.soniox]) == .soniox)
        #expect(provider(.openAi, held: [.soniox, .openAi]) == .soniox)
    }

    @Test func onlyCloudOnlyWithThePhoneNamedChangesMode() {
        for mode in TranscriptionMode.allCases {
            for backup in TranscriptionBackup.allCases {
                for held in [true, false] {
                    let routed = TranscriptionRouting.mode(
                        mode, selected: .soniox, backup: backup, isHeld: { _ in held })
                    let moves = mode == .remoteOnly && backup == .onDevice && held
                    #expect(routed == (moves ? .remoteFirst : mode))
                }
            }
        }
    }

    /// The upgrade from a live hold: the batch path goes to the backup at once, and the first
    /// account being held can never put the second one on hold.
    @Test func aHeldAccountsLateLiveFailureDoesNotHoldTheBackup() async {
        final class Streaming: StreamingTranscriptionProvider, @unchecked Sendable {
            let id = "rt"
            func isAvailable() async -> Bool { true }
            func transcribeStream(pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int)
                -> AsyncThrowingStream<StreamingTranscriptUpdate, Error>
            {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let hold = CloudAccountHold(fileURL: nil, apiKey: { "\($0.rawValue)-key" })
        let live = SelectableStreamingTranscriptionProvider(
            selected: {
                TranscriptionRouting.provider(
                    selected: .soniox, backup: .openAi,
                    isHeld: { hold.active(for: $0) != nil }, hasKey: { _ in true })
            },
            openAi: Streaming(), soniox: Streaming(), hold: hold)
        _ = live.transcribeStream(
            pcm: AsyncThrowingStream { $0.finish() }, sampleRateHz: 16_000)
        // An upload is refused while the live session is still open on Soniox.
        hold.trip(.accountOutOfFunds, provider: .soniox)
        // Then that session is refused too.
        live.noteFailureKind(.accountOutOfFunds)
        #expect(hold.active(for: .soniox) != nil)
        #expect(hold.active(for: .openAi) == nil)
        #expect(await live.isAvailable())
    }

    // MARK: - Being told

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    @Test func aChangeIsToldOnceAndAProbeThatChangesNothingIsNotTold() {
        let told = Count()
        let key = Count()
        let hold = CloudAccountHold(fileURL: nil, apiKey: { _ in "key-\(key.value)" })
        hold.onChanged { told.bump() }
        hold.trip(.accountOutOfFunds, provider: .soniox)
        #expect(told.value == 1)
        hold.trip(.accountOutOfFunds, provider: .soniox)
        hold.recordRefusedProbe(provider: .soniox, kind: .accountOutOfFunds)
        hold.recordInconclusiveProbe(provider: .soniox)
        #expect(told.value == 1)
        // A different reason is something to say.
        hold.recordRefusedProbe(provider: .soniox, kind: .keyRejected)
        #expect(told.value == 2)
        // So is the key being replaced...
        key.bump()
        #expect(hold.active(for: .soniox) == nil)
        #expect(told.value == 3)
        // ...and an account that works again.
        hold.trip(.accountOutOfFunds, provider: .soniox)
        hold.noteSuccess(provider: .soniox)
        #expect(told.value == 5)
    }

    @Test func goingToFixTheAccountStartsItsBackoffOver() {
        let now = Int64(1_000_000_000)
        let hold = CloudAccountHold(fileURL: nil, apiKey: { _ in "key" }, nowMs: { now })
        hold.trip(.accountOutOfFunds, provider: .soniox)
        for _ in 0..<6 { hold.recordRefusedProbe(provider: .soniox, kind: .accountOutOfFunds) }
        #expect(hold.active(for: .soniox)?.nextProbeAtMs == now + CloudAccountHold.maxProbeDelayMs)
        hold.restartBackoff(provider: .soniox)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false))
        hold.recordRefusedProbe(provider: .soniox, kind: .accountOutOfFunds)
        #expect(
            hold.active(for: .soniox)?.nextProbeAtMs
                == now + CloudAccountHold.probeDelayMs(afterRefusedProbes: 1))
    }
}
