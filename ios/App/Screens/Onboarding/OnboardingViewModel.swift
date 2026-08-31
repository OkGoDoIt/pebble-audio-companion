import Foundation
import Observation
import Transcription

// MARK: - Pairing seam

/// Every way the watch hand-off can end (States · Onboarding artboard + the 6.7
/// Bluetooth-permission branch). All recoverable — the UI offers bordered retries.
enum OnboardingFailure: String, CaseIterable, Identifiable {
    case noPebbleFound
    case cantSendAudio
    case declined
    case boundElsewhere
    case timedOut
    case bluetoothDenied

    var id: String { rawValue }
}

enum PairingOutcome: Equatable {
    case authorized
    case failed(OnboardingFailure)
}

/// The receiver-side pairing seam: discovery → firmware check → on-watch consent. The real
/// implementation wraps `ReceiverSession`; the mock simulates the waiting → success path.
protocol WatchPairingSource: Sendable {
    /// Runs one full pairing attempt. Cancelling the surrounding task abandons it.
    func requestPairing() async -> PairingOutcome
}

/// Default mock: two seconds of "Waiting for your Pebble…" then success. `nextOutcome`
/// lets the DEBUG staging control script each failure branch.
final class MockWatchPairingSource: WatchPairingSource, @unchecked Sendable {
    var nextOutcome: PairingOutcome = .authorized
    var delay: Duration = .seconds(2)

    func requestPairing() async -> PairingOutcome {
        try? await Task.sleep(for: delay)
        return nextOutcome
    }
}

// MARK: - Q14 choice

enum TranscriptChoice: CaseIterable {
    case onPhone, cloud, later
}

// MARK: - View model

/// Onboarding state machine (plan 2.1–2.3 + 2.19): connect → confirm-on-watch (with the six
/// failure branches) → transcripts choice → optional cloud-key hand-off → done.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable {
        case connect
        case confirm
        case transcripts
        case cloudKey
    }

    enum PairingState: Equatable {
        case idle
        case waiting
        case failed(OnboardingFailure)
    }

    var phase: Phase = .connect
    private(set) var pairing: PairingState = .idle
    /// Artboard 2.3 shows "In the cloud" selected.
    var choice: TranscriptChoice = .cloud

    let source: WatchPairingSource
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

    /// TODO(M9): point at the real published firmware guide.
    static let firmwareGuideURL = URL(string: "https://github.com/coredevices/PebbleOS")!

    init(source: WatchPairingSource? = nil) {
        #if DEBUG
        let mock = MockWatchPairingSource()
        if ProcessInfo.processInfo.arguments.contains("-onboarding.hold") {
            mock.delay = .seconds(3600)  // freeze "Waiting for your Pebble…" for screenshots
        }
        self.source = source ?? mock
        applyDebugLaunchArguments()
        #else
        self.source = source ?? MockWatchPairingSource()
        #endif
    }

    #if DEBUG
    /// Hidden staging control for simulator automation (sanctioned by the plan: failure
    /// branches must be reachable in DEBUG builds without a watch):
    /// `-onboarding.phase connect|confirm|transcripts|cloudKey`, `-onboarding.fail <case>`,
    /// `-onboarding.hold` (pairing never resolves).
    private func applyDebugLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-onboarding.fail"), index + 1 < args.count,
            let failure = OnboardingFailure(rawValue: args[index + 1]) {
            phase = .confirm
            pairing = .failed(failure)
            return
        }
        if let index = args.firstIndex(of: "-onboarding.phase"), index + 1 < args.count {
            switch args[index + 1] {
            case "confirm": beginPairing()
            case "transcripts": phase = .transcripts
            case "cloudKey": phase = .cloudKey
            default: break
            }
        }
    }
    #endif

    // MARK: Connect → Confirm

    func beginPairing() {
        phase = .confirm
        startRequest()
    }

    func startRequest() {
        pairingTask?.cancel()
        pairing = .waiting
        pairingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.source.requestPairing()
            guard !Task.isCancelled else { return }
            switch outcome {
            case .authorized:
                self.pairing = .idle
                self.phase = .transcripts
            case .failed(let failure):
                self.pairing = .failed(failure)
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairing = .idle
        phase = .connect
    }

    // MARK: Transcripts → done

    /// Applies the Q14 choice. Consent on the watch authorizes RECEIVING; it never silently
    /// enables capture (anti-B3) — capture intent stays wherever the user left it.
    func continueFromTranscripts(settings: AppSettings) {
        switch choice {
        case .onPhone:
            settings.transcriptionMode = .localOnly
            settings.transcriptsConfigured = true
            finish(settings: settings)
        case .cloud:
            settings.transcriptionMode = .remoteFirst
            settings.transcriptsConfigured = true
            phase = .cloudKey
        case .later:
            settings.transcriptsConfigured = false
            finish(settings: settings)
        }
    }

    func finish(settings: AppSettings) {
        settings.onboardingComplete = true
    }

    #if DEBUG
    /// Hidden staging control: jump straight to a failure branch.
    func debugTrigger(_ failure: OnboardingFailure) {
        pairingTask?.cancel()
        if phase == .connect { phase = .confirm }
        pairing = .failed(failure)
    }
    #endif
}

// MARK: - Failure card metadata (exact approved copy)

extension OnboardingFailure {
    var headline: String {
        switch self {
        case .noPebbleFound: return Copy.Onboarding.Failure.noPebbleFound
        case .cantSendAudio: return Copy.Onboarding.Failure.cantSendAudio
        case .declined: return Copy.Onboarding.Failure.declined
        case .boundElsewhere: return Copy.Onboarding.Failure.boundElsewhere
        case .timedOut: return Copy.Onboarding.Failure.noAnswer
        case .bluetoothDenied: return Copy.Onboarding.Failure.bluetoothDenied
        }
    }

    var line: String {
        switch self {
        case .noPebbleFound: return Copy.Onboarding.Failure.noPebbleFoundLine
        case .cantSendAudio: return Copy.Onboarding.Failure.cantSendAudioLine
        case .declined: return Copy.Onboarding.Failure.declinedLine
        case .boundElsewhere: return Copy.Onboarding.Failure.boundElsewhereLine
        case .timedOut: return Copy.Onboarding.Failure.noAnswerLine
        case .bluetoothDenied: return Copy.Onboarding.Failure.bluetoothDeniedLine
        }
    }

    var actionTitle: String {
        switch self {
        case .cantSendAudio: return Copy.Onboarding.Failure.firmwareGuide
        case .timedOut: return Copy.Onboarding.Failure.askAgain
        case .bluetoothDenied: return Copy.Status.openSettings
        default: return Copy.Common.tryAgain
        }
    }

    /// Neutral for benign outcomes, attention for the ones needing watch-side action,
    /// destructive for the Bluetooth-permission branch.
    var dotStyle: DotStyle {
        switch self {
        case .cantSendAudio, .boundElsewhere: return .attention
        case .bluetoothDenied: return .destructive
        default: return .neutral
        }
    }

    enum DotStyle { case neutral, attention, destructive }
}
