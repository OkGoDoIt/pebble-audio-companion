import Foundation
import Intelligence
import Transcription

#if canImport(FoundationModels)
    import FoundationModels
#endif

// Which rows Settings · Transcription & AI may show, and whether this phone can actually do the
// local half of what the modes ask for.
//
// The reported problem: the screen showed every row in every configuration, so "AI Mode ·
// Local only" sat above "OpenAI key · not set" and a row called "Model" that names the CLOUD
// model. Two settings that nothing in that configuration reads, one of them looking like a
// defect ("not set") and one looking like the local engine.
//
// Everything here is a pure function of the two modes plus the chosen cloud provider, so
// `TSTranscriptionRowVisibilityTests` pins all sixteen mode combinations without a view, a
// database or a device.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - What a mode actually runs
// ─────────────────────────────────────────────────────────────────────────────

// One rule, derived from the routers rather than from the four labels:
//
//   `TranscriptionModeRouter.transcribe` / `AiModeRouter.route` both branch the same way —
//   `localOnly` runs the local provider and nothing else, `remoteOnly` runs the remote provider
//   and nothing else, and BOTH "first" modes try one and fall back to the other. So a mode uses
//   the cloud unless it is `localOnly`, and uses the on-device engine unless it is `remoteOnly`.
//
// That makes `localFirst` a cloud-using mode: its fallback is what needs the key. Getting that
// backwards would hide the key row from the one person most likely to be surprised by a
// recording being uploaded.
//
// The cloud half is deliberately the SAME predicate the pipeline is gated on
// (`RuntimeSettings.cloudTranscriptionEnabled` / `remoteAiEnabled`), and the test asserts that
// equality for all sixteen pairs so this cannot drift into a second opinion about the routers.

extension TranscriptionMode {
    /// The on-device speech engine runs in this mode — as the only path, as the preferred one,
    /// or as the fallback for a failed upload.
    var usesOnDeviceEngine: Bool { self != .remoteOnly }

    /// A recording can reach the cloud provider in this mode. Same predicate as
    /// `RuntimeSettings.cloudTranscriptionEnabled`.
    var usesCloudProvider: Bool { self != .localOnly }
}

extension AiProcessingMode {
    /// Apple's on-device model runs in this mode (preferred, only, or as the fallback).
    var usesOnDeviceModel: Bool { self != .remoteOnly }

    /// Transcript text can reach the remote AI provider in this mode. Same predicate as
    /// `RuntimeSettings.remoteAiEnabled`.
    var usesCloudProvider: Bool { self != .localOnly }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The row plan
// ─────────────────────────────────────────────────────────────────────────────

/// Which rows the screen draws for one configuration.
///
/// A value type rather than a pile of `if`s in the view body, because the thing that rots here
/// is the TABLE — someone adds a fifth mode, or moves the key row, and one of the sixteen
/// combinations quietly starts asking for a credential it never uses.
struct TranscriptionAiRowPlan: Equatable {
    var transcriptionMode: TranscriptionMode
    var aiMode: AiProcessingMode
    /// Which backend the transcription half would upload to. Only meaningful when
    /// `transcriptionMode.usesCloudProvider`.
    var cloudTranscriptionProvider: CloudProvider
    /// What the AI half's "remote" is: OpenAI (the person's key) or Apple Private Cloud
    /// Compute (iOS 27; no key). Only meaningful when `aiMode.usesCloudProvider`.
    var remoteAiProvider: RemoteAiProvider = .openAi
    /// Whether this OS offers Private Cloud Compute at all (`#available(iOS 27)`). Decides
    /// whether the choice is drawn, never what the setting is.
    var applePrivateCloudOffered: Bool = false

    // ── Transcription card ───────────────────────────────────────────────────

    /// "Local model". Hidden in Cloud only, where nothing ever resolves the selection — a
    /// picker for an engine that cannot run is the same placebo as a key that is never read.
    var showsLocalModel: Bool { transcriptionMode.usesOnDeviceEngine }

    var showsCloudProvider: Bool { transcriptionMode.usesCloudProvider }

    /// "Upload Audio" is about bytes leaving the phone (`CloudUploadNetworkPolicy`); with no
    /// upload there is no network choice to make. Local model downloads are Wi-Fi-only by their
    /// own rule and are not governed by this setting.
    var showsUploadNetwork: Bool { transcriptionMode.usesCloudProvider }

    /// Always. Catch-up is when queued work may run while the app is off screen, and a local
    /// engine has exactly the same backlog a cloud one does.
    var showsBackgroundCatchUp: Bool { true }

    /// The key the transcription half needs, or nil when it authenticates with nobody.
    var transcriptionKey: CloudProvider? {
        transcriptionMode.usesCloudProvider ? cloudTranscriptionProvider : nil
    }

    // ── AI card ──────────────────────────────────────────────────────────────

    /// The "On this phone" readiness row. Present whenever Apple's model can be asked to do
    /// something — including `remoteFirst`, where it is the fallback.
    var showsOnDeviceAi: Bool { aiMode.usesOnDeviceModel }

    /// Transcript text can reach Apple Private Cloud Compute in this configuration.
    var usesApplePrivateCloud: Bool {
        aiMode.usesCloudProvider && remoteAiProvider == .applePrivateCloud
    }

    /// "Remote model" — OpenAI or Apple Private Cloud Compute. Drawn wherever the OS offers the
    /// choice, and ALSO wherever the setting already names Private Cloud Compute on an OS that
    /// does not: a person must always be able to switch back, and a hidden row would leave a
    /// fail-closed provider with no way out.
    var showsRemoteModelChoice: Bool {
        aiMode.usesCloudProvider
            && (applePrivateCloudOffered || remoteAiProvider == .applePrivateCloud)
    }

    /// "Cloud model" (the row that used to be called "Model"). It picks the OpenAI model, so it
    /// means nothing in AI Local only — and nothing when the remote is Apple's, which has one.
    var showsCloudModel: Bool { aiMode.usesCloudProvider && remoteAiProvider == .openAi }

    /// The Apple Private Cloud readiness row: present exactly where text can reach it.
    var showsApplePrivateCloud: Bool { usesApplePrivateCloud }

    /// The AI half's key row, or nil. Nil ALSO when the transcription half is already showing
    /// the OpenAI key: one setting, one row — the same key rendered twice on one screen invites
    /// the reader to wonder which of them is which. And nil when the remote is Apple's, which
    /// authenticates with nobody.
    var aiKey: CloudProvider? {
        guard aiMode.usesCloudProvider, remoteAiProvider == .openAi, transcriptionKey != .openAi
        else { return nil }
        return .openAi
    }

    // ── Screen ───────────────────────────────────────────────────────────────

    /// Every provider this configuration will authenticate against, whether or not a row is
    /// drawn for it. Un-deduplicated truth: what the key PRE-CHECK asks about, so an unused
    /// saved key costs no request (see `SettingsTranscriptionScreen.checkKeysIfNeeded`).
    var providersInUse: Set<CloudProvider> {
        var used: Set<CloudProvider> = []
        if let transcriptionKey { used.insert(transcriptionKey) }
        if aiMode.usesCloudProvider, remoteAiProvider == .openAi { used.insert(.openAi) }
        return used
    }

    /// The key rows actually drawn, transcription first (that is their order on screen).
    var keyRows: [CloudProvider] { [transcriptionKey, aiKey].compactMap { $0 } }

    /// "Test Connection" probes the cloud TRANSCRIPTION backend and nothing else:
    /// `TranscriptionService.testCloudConnection` calls `connectivityCheck.checkConnectivity()`,
    /// which `AppComposition` wires to `batchCloud` — the selectable cloud transcription
    /// provider. In a configuration where only the AI half is remote it would test a provider
    /// this phone never uploads to, so it is absent; the OpenAI key row's own [Check Again] is
    /// where that key is verified.
    var showsTestConnection: Bool { transcriptionMode.usesCloudProvider }

    /// Nothing at all reaches a service. The same condition `Copy.Privacy.Stance.isFullyLocal`
    /// reports on Storage & Privacy — read the stance for the wording, this is only the switch.
    /// Apple Private Cloud Compute holds no key, so it is not in `providersInUse`, but text does
    /// leave the phone for it: never "fully local".
    var isFullyLocal: Bool { providersInUse.isEmpty && !usesApplePrivateCloud }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Can this phone run the local AI at all?
// ─────────────────────────────────────────────────────────────────────────────

/// Whether Apple's on-device language model can write anything on THIS phone right now.
///
/// The three unavailable cases are genuinely different situations and the difference is the
/// whole point of showing this: one is permanent, one is a switch in iOS Settings, one is a
/// download that is already running. "Not available" would collapse all three into a shrug.
enum OnDeviceAiReadiness: Equatable, CaseIterable {
    /// Apple Intelligence is on, downloaded, and answering.
    case ready
    /// `deviceNotEligible` — this hardware will never run it.
    case notSupported
    /// `appleIntelligenceNotEnabled` — it could, but it is switched off in iOS Settings.
    case switchedOff
    /// `modelNotReady` — still downloading or warming up.
    case preparing

    var isReady: Bool { self == .ready }
}

extension OnDeviceAiReadiness {
    /// A snapshot, read fresh on every draw and never cached: Apple Intelligence can be switched
    /// off, and a model can still be downloading, between one reading and the next
    /// (`OnDeviceAiCapability` makes the same point about its own answer).
    ///
    /// The yes/no comes from the kit — `OnDeviceAiCapability.canProposeFollowUps` is
    /// `SystemLanguageModel.default.availability == .available` — so this screen and the
    /// follow-up gate that reads the same property can never disagree about whether the model
    /// works. Only the REASON is resolved here, and only when the answer is already no; there is
    /// no second opinion about readiness anywhere in this file.
    static var current: OnDeviceAiReadiness {
        guard !OnDeviceAiCapability.canProposeFollowUps else { return .ready }
        return unavailableReason()
    }

    private static func unavailableReason() -> OnDeviceAiReadiness {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                // Reachable only if availability flipped between the two reads above. Believe
                // the newer one rather than reporting a reason that is no longer true.
                case .available:
                    return .ready
                case .unavailable(.deviceNotEligible):
                    return .notSupported
                case .unavailable(.appleIntelligenceNotEnabled):
                    return .switchedOff
                case .unavailable(.modelNotReady):
                    return .preparing
                // A reason Apple adds later. `notSupported` is the honest floor: it says the
                // model is not going to answer, and claims nothing about why.
                case .unavailable:
                    return .notSupported
                @unknown default:
                    return .notSupported
                }
            }
            return .notSupported
        #else
            return .notSupported
        #endif
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Can this phone transcribe on its own?
// ─────────────────────────────────────────────────────────────────────────────

/// Whether anything on this phone can turn audio into text right now.
///
/// Two states decide it, because `SelectableLocalTranscriptionProvider.resolution` has exactly
/// one fallback: a chosen model that is not installed transcribes as Apple Speech instead. And
/// `SpeechAnalyzerProvider.isAvailable` is `inventory.status == .installed` — it does NOT install
/// assets on demand — so an Apple Speech that has never been downloaded transcribes nothing at
/// all. That is the silent-nothing this exists to catch.
enum OnDeviceTranscriptionReadiness: Equatable {
    /// An installed engine will transcribe the next segment.
    case ready
    /// A download or unpack is in flight (or waiting for Wi-Fi); the row shows its progress.
    case preparing
    /// Nothing installed and nothing in flight. `appleSpeechUnsupported` is true when iOS has no
    /// speech model for this phone's language, so the usual free fallback is not an option and a
    /// downloaded model is the only route.
    case needsModel(appleSpeechUnsupported: Bool)

    var isReady: Bool { self == .ready }
}

extension OnDeviceTranscriptionReadiness {
    /// - Parameters:
    ///   - selected: state of the engine named by `AppSettings.localTranscriptionModelId`.
    ///   - appleSpeech: state of `LocalModelCatalog.appleSpeechId`, which is the fallback for
    ///     every other selection and is therefore the floor for the whole answer.
    static func resolve(
        selected: LocalModelState, appleSpeech: LocalModelState
    ) -> OnDeviceTranscriptionReadiness {
        if selected == .installed || appleSpeech == .installed { return .ready }
        if selected.isBusy || appleSpeech.isBusy { return .preparing }
        if selected == .waitingForWiFi || appleSpeech == .waitingForWiFi { return .preparing }
        // `.unavailable` only ever comes from Apple Speech (`LiveLocalModelManager.map` maps the
        // kit's `.unsupported`; no Parakeet state produces it), and it means iOS has no speech
        // model for this locale. A downloadable model can still cover it, so this is a reason,
        // not a dead end.
        return .needsModel(appleSpeechUnsupported: appleSpeech == .unavailable)
    }
}
