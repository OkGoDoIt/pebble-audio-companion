import CompanionRuntime
import Foundation
import Intelligence
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

/// Where one kind of work runs. Transcription (audio → text) and AI (text → summaries, notes,
/// follow-ups, answers) are INDEPENDENT axes, and onboarding used to set only the first — which
/// is how "On this phone — Private." shipped while every transcript still went to OpenAI.
///
/// Only two places, never four modes. The kit's enums also have `localFirst` / `remoteFirst`
/// spellings of "local" and "remote", and neither of the "first" ones is a promise a card may
/// make: `TranscriptionModeRouter.localFirst` uploads the whole segment on any local failure
/// except cancellation and no-speech (the on-device language model simply not being installed is
/// one of those failures), and in AI `localFirst` every follow-up request reaches the remote
/// provider, because `OnDeviceAiProvider` refuses structured output unconditionally. So a choice
/// that says "on this phone" maps to `localOnly` — the only mode that cannot upload.
enum ProcessingPlace: String, CaseIterable, Identifiable {
    case onPhone, inCloud

    var id: String { rawValue }

    var transcriptionMode: TranscriptionMode {
        switch self {
        case .onPhone: return .localOnly
        case .inCloud: return .remoteFirst
        }
    }

    var aiMode: AiProcessingMode {
        switch self {
        case .onPhone: return .localOnly
        case .inCloud: return .remoteFirst
        }
    }
}

/// The step-3 answer. The three presets are the whole question for most people; `mixed` is what
/// the "Set transcripts and AI separately" screen writes. It is never an option the cards offer
/// — the question screen only renders it once it exists, so the answer is visible where it was
/// asked.
enum ProcessingChoice: String, CaseIterable, Identifiable {
    /// Both axes local: the only answer allowed to imply nothing leaves.
    case onPhone
    /// Both axes remote.
    case cloud
    /// Not now. Fails CLOSED — see `ProcessingPlan.plan(for:transcripts:ai:)`.
    case later
    /// Whatever the two-axis screen was left on.
    case mixed

    var id: String { rawValue }

    /// The three cards, in order. `mixed` is deliberately absent: it has its own screen.
    static let presets: [ProcessingChoice] = [.onPhone, .cloud, .later]
}

/// Exactly what an answer writes, as a plain value — so a test can pin every offered choice to
/// its `(transcriptionMode, aiMode)` pair, which is the assertion that would have caught the
/// original bug, and so the key hand-off can ask what this combination actually needs.
struct ProcessingPlan: Equatable {
    var transcriptionMode: TranscriptionMode
    var aiMode: AiProcessingMode
    /// False only for "Later": the Q14 question is still unanswered, which is what Today's
    /// "Transcripts are off" card and the widget both read.
    var transcriptsConfigured: Bool

    /// The same predicates the PROVIDERS are gated on, so "does this need a key" cannot drift
    /// away from "does this actually call out".
    private var modes: RuntimeSettingsSnapshot {
        RuntimeSettingsSnapshot(transcriptionMode: transcriptionMode, aiMode: aiMode)
    }

    /// Cloud transcription is reachable, so a Soniox **or** OpenAI key is wanted.
    var needsTranscriptionKey: Bool { modes.cloudTranscriptionEnabled }
    /// Remote AI is reachable, and `OpenAiChatAiProvider` is the only provider it routes to.
    var needsAiKey: Bool { modes.remoteAiEnabled }
    var needsAnyKey: Bool { needsTranscriptionKey || needsAiKey }

    /// Whether the on-device-AI price list applies (no follow-ups, summaries only where Apple
    /// Intelligence is available).
    var isOnDeviceAi: Bool { aiMode == .localOnly }

    /// Whether to SHOW that price list. "Later" also lands on local-only AI — it fails closed —
    /// but nobody chose AI there, so listing what on-device AI cannot do would be answering a
    /// question the person has just declined to answer. `transcriptsConfigured` is exactly the
    /// "they decided" bit.
    var showsOnDeviceAiCost: Bool { isOnDeviceAi && transcriptsConfigured }

    /// The single mapping from an answer to the settings it writes.
    ///
    /// "Later" is the one that used to be quietly wrong in the other direction: it left both
    /// modes at their `.remoteFirst` defaults, so someone who had not chosen anything yet was
    /// nonetheless configured to upload. `transcriptsConfigured` is only a STATUS flag — nothing
    /// in the pipeline is gated on it — so the modes are what actually decide, and an
    /// undecided person must be in the configuration that cannot send.
    static func plan(
        for choice: ProcessingChoice, transcripts: ProcessingPlace, ai: ProcessingPlace
    ) -> ProcessingPlan {
        switch choice {
        case .onPhone:
            return ProcessingPlan(
                transcriptionMode: .localOnly, aiMode: .localOnly, transcriptsConfigured: true)
        case .cloud:
            return ProcessingPlan(
                transcriptionMode: .remoteFirst, aiMode: .remoteFirst, transcriptsConfigured: true)
        case .later:
            return ProcessingPlan(
                transcriptionMode: .localOnly, aiMode: .localOnly, transcriptsConfigured: false)
        case .mixed:
            return ProcessingPlan(
                transcriptionMode: transcripts.transcriptionMode,
                aiMode: ai.aiMode,
                transcriptsConfigured: true)
        }
    }
}

// MARK: - View model

/// Onboarding state machine (plan 2.1–2.3 + 2.19): connect → searching → confirm-on-watch (with
/// the failure branches) → processing choice (optionally its two-axis detail) → the provider-key
/// hand-off this combination actually needs → done. Every step-2 state is the real receiver
/// session's, mapped by `LiveWatchPairingSource`.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable {
        case connect
        case confirm
        /// The three-card processing question. Case name kept from when it asked only about
        /// transcripts, because the DEBUG staging flag `-onboarding.phase transcripts` names it.
        case transcripts
        /// "Set transcripts and AI separately" — the two independent axes.
        case processingDetail
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
    var choice: ProcessingChoice = .cloud
    /// The two-axis screen's draft. Seeded from the preset the person arrives with, so opening
    /// "Set separately" starts from what they already picked instead of an unrelated default.
    var transcriptsPlace: ProcessingPlace = .inCloud
    var aiPlace: ProcessingPlace = .inCloud
    /// Which screen the key hand-off must return to (B15: back names the actual parent step).
    private(set) var keyReturnPhase: Phase = .transcripts
    /// The card the person opened the two-axis screen from, and the axes it was seeded with, so
    /// backing out without touching anything restores exactly what they came in on.
    @ObservationIgnored private var choiceBeforeDetail: ProcessingChoice = .cloud
    @ObservationIgnored
    private var placesBeforeDetail: (ProcessingPlace, ProcessingPlace) = (.inCloud, .inCloud)

    /// Exactly what the current answer will write. One derivation, read by the screens (to show
    /// the stance and the on-device-AI note), by the key hand-off (to ask for what is needed),
    /// and by `continueFromProcessing` (to apply it).
    var plan: ProcessingPlan {
        ProcessingPlan.plan(for: choice, transcripts: transcriptsPlace, ai: aiPlace)
    }

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
    /// `-onboarding.phase connect|confirm|transcripts|processing|cloudKey`,
    /// `-onboarding.fail <case>`,
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
            case "processing": openProcessingDetail()
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

    // MARK: Processing → done

    /// Opens the two-axis screen, seeded from the preset the person is currently on so the
    /// detail screen never contradicts the card they just tapped.
    func openProcessingDetail() {
        let current = plan
        transcriptsPlace = current.transcriptionMode == .localOnly ? .onPhone : .inCloud
        aiPlace = current.aiMode == .localOnly ? .onPhone : .inCloud
        choiceBeforeDetail = choice
        placesBeforeDetail = (transcriptsPlace, aiPlace)
        choice = .mixed
        phase = .processingDetail
    }

    /// Back to the three cards, without quietly changing the answer.
    ///
    /// Touching nothing restores the exact card the person came in on. That matters most for
    /// "Later", whose modes are identical to "On this phone" and differ only in
    /// `transcriptsConfigured`: collapsing on modes alone would turn an undecided person into a
    /// decided one just for looking. Once an axis HAS been changed the mix collapses onto
    /// whichever card writes the same pair, and stays `.mixed` when no card does — that is what
    /// makes the question screen render its summary card.
    func backToProcessing() {
        if (transcriptsPlace, aiPlace) == placesBeforeDetail {
            choice = choiceBeforeDetail
        } else {
            switch (transcriptsPlace, aiPlace) {
            case (.onPhone, .onPhone): choice = .onPhone
            case (.inCloud, .inCloud): choice = .cloud
            default: choice = .mixed
            }
        }
        phase = .transcripts
    }

    /// Applies the step-3 answer — BOTH axes, always. Writing only `transcriptionMode` here is
    /// the defect this flow was rebuilt around: it left `aiMode` at `.remoteFirst`, so the
    /// "On this phone" card shipped audio locally and every transcript, summary, follow-up and
    /// About You block to OpenAI.
    ///
    /// Capture intent was set by the explicit "Connect Watch" tap in step 1 (the same path
    /// Today's Start takes) and is not touched here — consent on the watch by itself never
    /// switches capture on (anti-B3).
    func continueFromProcessing(settings: AppSettings) {
        let plan = self.plan
        settings.transcriptionMode = plan.transcriptionMode
        settings.aiMode = plan.aiMode
        settings.transcriptsConfigured = plan.transcriptsConfigured

        // Ask only for keys this combination will actually use. A local-transcripts + cloud-AI
        // setup needs OpenAI and nothing else; both-local needs no key screen at all.
        guard plan.needsAnyKey else {
            finish(settings: settings)
            return
        }
        keyReturnPhase = phase
        phase = .cloudKey
    }

    /// Back from the key screen to whichever screen sent it there (B15: no dead ends).
    func backFromCloudKey() {
        phase = keyReturnPhase
    }

    /// The back affordance's label on the key screen — the name of the actual parent step.
    var cloudKeyBackLabel: String {
        keyReturnPhase == .processingDetail
            ? Copy.OnboardingProcessing.detailTitle : Copy.OnboardingProcessing.backToProcessing
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
