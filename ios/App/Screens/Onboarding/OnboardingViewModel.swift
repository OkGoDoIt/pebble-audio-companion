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
    case bluetoothOff
    case needsReconnect

    var id: String { rawValue }
}

/// One step-2 moment, as the pairing source reports it.
enum PairingUpdate: Equatable {
    /// Scanning / connecting / authorizing — nothing is waiting on the person yet.
    case searching
    /// A prompt is on the watch (receiver consent, or "turn Background Audio on").
    case confirmOnWatch
    case authorized
    case failed(OnboardingFailure)
}

/// The receiver-side pairing seam: discovery → firmware check → on-watch consent.
/// `LiveWatchPairingSource` drives the real receiver; the mock replays the same shape for
/// previews and the DEBUG staging walkthrough.
protocol WatchPairingSource: Sendable {
    /// One pairing attempt, as a stream that ends at `.authorized` or `.failed`. Terminating
    /// the stream (cancelling the consuming task) abandons the attempt.
    func pairingUpdates() -> AsyncStream<PairingUpdate>

    /// The user backed out of step 2 — undo whatever the attempt switched on.
    func cancelPairing() async
}

extension WatchPairingSource {
    func cancelPairing() async {}
}

/// The onboarding pairing seam, flipped from the mock to the live receiver by
/// `AppComposition.install` — the same mock-until-bootstrap pattern the three screen
/// data-source holders use, so `#Preview` still renders without a graph.
struct OnboardingDataSources {
    var pairing: any WatchPairingSource

    static var current = OnboardingDataSources(pairing: MockWatchPairingSource())
}

/// Preview/staging double: a beat of searching, a beat of confirm-on-watch, then `nextOutcome`.
/// `freeze` holds either waiting state open for screenshots. Never used in a real launch — the
/// composition root installs `LiveWatchPairingSource` over it.
final class MockWatchPairingSource: WatchPairingSource, @unchecked Sendable {
    enum Freeze { case none, searching, confirmOnWatch }

    var nextOutcome: PairingUpdate = .authorized
    var searchingDelay: Duration = .seconds(1)
    var confirmDelay: Duration = .seconds(1)
    var freeze: Freeze = .none

    func pairingUpdates() -> AsyncStream<PairingUpdate> {
        AsyncStream { continuation in
            let outcome = nextOutcome
            let searching = freeze == .searching ? .seconds(3600) : searchingDelay
            let confirm = freeze == .confirmOnWatch ? .seconds(3600) : confirmDelay
            let work = Task {
                continuation.yield(.searching)
                try? await Task.sleep(for: searching)
                guard !Task.isCancelled else { return continuation.finish() }
                continuation.yield(.confirmOnWatch)
                try? await Task.sleep(for: confirm)
                guard !Task.isCancelled else { return continuation.finish() }
                continuation.yield(outcome)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

// MARK: - Q14 choice

enum TranscriptChoice: CaseIterable {
    case onPhone, cloud, later
}

// MARK: - View model

/// Onboarding state machine (plan 2.1–2.3 + 2.19): connect → searching → confirm-on-watch (with
/// the failure branches) → transcripts choice → optional provider-key hand-off → done. Every
/// step-2 state is the real receiver session's, mapped by `LiveWatchPairingSource`.
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
        /// Looking for the watch — no prompt exists on it yet, so the screen must not imply one.
        case searching
        /// A prompt is waiting on the watch.
        case confirmOnWatch
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
        // Real launches pair for real; the mock is reachable only from a preview (no graph
        // installed) or an explicit `-onboarding.*` staging flag.
        self.source = source ?? Self.debugStagedSource() ?? OnboardingDataSources.current.pairing
        applyDebugLaunchArguments()
        #else
        self.source = source ?? OnboardingDataSources.current.pairing
        #endif
    }

    #if DEBUG
    /// Hidden staging control for simulator automation (sanctioned by the plan: failure
    /// branches must be reachable in DEBUG builds without a watch):
    /// `-onboarding.phase connect|confirm|transcripts|cloudKey`, `-onboarding.fail <case>`,
    /// `-onboarding.hold [searching|confirm]` (pairing never resolves), `-onboarding.mock`
    /// (the scripted happy path). `-onboarding.reset` is NOT one of these: it only re-enters
    /// the gate, and pairing there is real.
    private static let stagingFlags = [
        "-onboarding.fail", "-onboarding.phase", "-onboarding.hold", "-onboarding.mock",
    ]

    private static func debugStagedSource() -> WatchPairingSource? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: stagingFlags.contains) else { return nil }
        let mock = MockWatchPairingSource()
        if let index = args.firstIndex(of: "-onboarding.hold") {
            let which = index + 1 < args.count ? args[index + 1] : ""
            mock.freeze = which == "searching" ? .searching : .confirmOnWatch
        }
        return mock
    }

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

    /// One attempt. Every state the screen shows from here on is the receiver's own — searching,
    /// the on-watch prompt, and each failure branch.
    func startRequest() {
        pairingTask?.cancel()
        pairing = .searching
        pairingTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.source.pairingUpdates() {
                guard !Task.isCancelled else { return }
                switch update {
                case .searching:
                    self.pairing = .searching
                case .confirmOnWatch:
                    self.pairing = .confirmOnWatch
                case .authorized:
                    self.pairing = .idle
                    self.phase = .transcripts
                    return
                case .failed(let failure):
                    self.pairing = .failed(failure)
                    return
                }
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairing = .idle
        phase = .connect
        Task { [source] in await source.cancelPairing() }
    }

    // MARK: Transcripts → done

    /// Applies the Q14 choice. Capture intent was set by the explicit "Connect Watch" tap in
    /// step 1 (the same path Today's Start takes) and is not touched again here — consent on the
    /// watch by itself never switches capture on (anti-B3).
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

    /// Back from the key screen to the transcripts choice (B15: no dead ends).
    func backToTranscripts() {
        phase = .transcripts
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
        case .bluetoothOff: return Copy.Onboarding.Failure.bluetoothOff
        case .needsReconnect: return Copy.Onboarding.Failure.needsReconnect
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
        case .bluetoothOff: return Copy.Onboarding.Failure.bluetoothOffLine
        case .needsReconnect: return Copy.Onboarding.Failure.needsReconnectLine
        }
    }

    var actionTitle: String {
        switch self {
        case .cantSendAudio: return Copy.Onboarding.Failure.firmwareGuide
        case .timedOut: return Copy.Onboarding.Failure.askAgain
        case .bluetoothDenied, .bluetoothOff: return Copy.Status.openSettings
        default: return Copy.Common.tryAgain
        }
    }

    /// Neutral for benign outcomes, attention for the ones needing watch-side action,
    /// destructive for the Bluetooth-permission branch.
    var dotStyle: DotStyle {
        switch self {
        case .cantSendAudio, .boundElsewhere, .needsReconnect: return .attention
        case .bluetoothDenied, .bluetoothOff: return .destructive
        default: return .neutral
        }
    }

    enum DotStyle { case neutral, attention, destructive }
}
