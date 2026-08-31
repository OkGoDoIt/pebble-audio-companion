import CompanionRuntime
import Foundation
import Receiver
import WireProtocol

// The real onboarding pairing seam. Before this existed, onboarding ran `MockWatchPairingSource`
// in shipping builds — two seconds of pretend "Waiting for your Pebble…" followed by a pretend
// success — so the first honest connection only happened later, when the user tapped Start on
// Today. This drives the SAME path that Today's Start takes:
//
//     settings.captureIntent = .active   →   runtime.startCapture()
//
// (`startCapture` arms exactly one on-watch enable prompt and applies the intent, which starts
// the receiver session), and then reports what the session ACTUALLY did. Finishing onboarding
// therefore leaves the receiver in the state a Start on Today would produce — nothing to press
// a second time.

/// Onboarding step 2, backed by the live receiver session.
@MainActor
final class LiveWatchPairingSource: WatchPairingSource {
    private let composition: AppComposition

    /// The watch's consent prompt expires after a minute (Copy: "The request expired after a
    /// minute."). Give it margin before the phone says so on its own — normally the watch's own
    /// answer arrives first and this timer never fires.
    private static let confirmTimeout: Duration = .seconds(90)

    /// The intent the user had before this attempt, restored if they back out (a cancelled
    /// attempt must not leave capture switched on behind them).
    private var intentBeforeAttempt: CaptureIntent?

    init(composition: AppComposition) {
        self.composition = composition
    }

    nonisolated func pairingUpdates() -> AsyncStream<PairingUpdate> {
        AsyncStream { continuation in
            let attempt = Task { @MainActor in
                await self.run(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in attempt.cancel() }
        }
    }

    /// The user left step 2. Undo the capture intent this attempt turned on — but only back to
    /// where they had it, never past it.
    func cancelPairing() async {
        guard let previous = intentBeforeAttempt else { return }
        intentBeforeAttempt = nil
        guard previous != .active else { return }
        composition.settings.captureIntent = previous
        await composition.runtime.setCaptureIntent(previous)
    }

    private func run(_ continuation: AsyncStream<PairingUpdate>.Continuation) async {
        let runtime = composition.runtime
        continuation.yield(.searching)

        // Exactly Today's Start, in the same order: the settings write first (so every surface
        // flips the moment the user taps), then the runtime call that arms the watch prompt.
        intentBeforeAttempt = composition.settings.captureIntent
        composition.settings.captureIntent = .active
        await runtime.startCapture()

        // A prompt waiting on the watch is the one state that can hang forever, so it — and only
        // it — carries a deadline.
        var confirmTimeout: Task<Void, Never>?
        defer { confirmTimeout?.cancel() }

        for await state in runtime.receiverState.stream() {
            guard !Task.isCancelled else { return }
            guard let update = Self.update(for: state) else { continue }

            if case .confirmOnWatch = update {
                if confirmTimeout == nil {
                    confirmTimeout = Task { @MainActor in
                        try? await Task.sleep(for: Self.confirmTimeout)
                        guard !Task.isCancelled else { return }
                        continuation.yield(.failed(.timedOut))
                        continuation.finish()
                    }
                }
            } else {
                confirmTimeout?.cancel()
                confirmTimeout = nil
            }

            continuation.yield(update)
            switch update {
            case .authorized, .failed:
                return  // terminal: the flow either advances or shows a branch
            case .searching, .confirmOnWatch:
                continue
            }
        }
    }

    // MARK: - Session state → onboarding step 2

    private static func update(for state: ReceiverSessionState) -> PairingUpdate? {
        switch state {
        case .disconnected, .connecting, .authorizing:
            // `.disconnected` with no recorded failure is the pre-connect moment, not an outcome.
            return .searching
        case .pendingConsent, .pendingEnable:
            return .confirmOnWatch
        case .authorized, .streaming:
            return .authorized
        case .connectionFailed(let kind, _):
            return .failed(failure(for: kind))
        case .denied:
            return .failed(failure(forDenied: state.deniedStatus))
        case .revoked(let reasonRaw):
            let reason = UInt8(exactly: reasonRaw).flatMap(RevokeReason.init(rawValue:))
            return .failed(reason == .replaced ? .boundElsewhere : .declined)
        }
    }

    /// Link-level failures, classified by the kit from CoreBluetooth's own error domains.
    private static func failure(for kind: ConnectFailureKind) -> OnboardingFailure {
        switch kind {
        case .bluetoothOff:
            return .bluetoothOff
        case .bluetoothUnauthorized:
            return .bluetoothDenied
        case .watchUnreachable, .bluetoothUnavailable:
            // Nothing answered in ~30 s of retries (or LE is unavailable right now): the honest
            // ask is the same — watch nearby, Bluetooth on, try again.
            return .noPebbleFound
        case .linkRejected:
            // The ATT server refused a handle — in practice a stale iOS GATT cache after a
            // firmware update. Retrying the same handles never clears it.
            return .needsReconnect
        case .unknown:
            // `.unknown` is only produced by the two discovery guards — the audio-companion
            // service or its characteristics were not on the watch — i.e. the wrong firmware.
            return .cantSendAudio
        }
    }

    /// The watch answered, and the answer was no.
    private static func failure(forDenied status: AuthStatus?) -> OnboardingFailure {
        switch status {
        case .deniedMismatch:
            return .boundElsewhere
        case .invalid:
            // The watch rejected the request itself: it does not speak this protocol version.
            return .cantSendAudio
        default:
            // `deniedDisabled` included: the person was asked on the watch and did not allow it.
            return .declined
        }
    }
}
