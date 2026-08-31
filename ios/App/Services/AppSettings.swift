import Foundation
import Observation
import Receiver
import Transcription
import Intelligence
import CompanionRuntime

// The user-facing setting types come from the kit — `Receiver.CaptureIntent` (the plan-6.1
// tri-state the session consumes directly) and `Transcription.CloudProvider` (whose raw
// values "OpenAi"/"Soniox" are what the old app persisted, so migration reads them as-is).

extension CaptureIntent {
    /// Persistence encoding for the `capture_intent` defaults key.
    var settingValue: String {
        switch self {
        case .active: return "active"
        case .paused: return "paused"
        case .off: return "off"
        }
    }

    init?(settingValue: String) {
        switch settingValue {
        case "active": self = .active
        case "paused": self = .paused
        case "off": self = .off
        default: return nil
        }
    }
}

extension CloudProvider {
    var displayName: String {
        switch self {
        case .soniox: return "Soniox"
        case .openAi: return "OpenAI"
        }
    }

    var keychainKey: KeychainStore.Key {
        switch self {
        case .soniox: return .sonioxApiKey
        case .openAi: return .openAiApiKey
        }
    }
}

/// The app-settings service — the ONLY writer of user preferences (plan Part 4.6 truth table).
///
/// Everything here is REAL and wired; no placebo controls (Q7/B8/B9). `retentionDays` in
/// particular is real this time. API keys never touch UserDefaults — they go through
/// `KeychainStore` exclusively (B13), which also owns the masked rendering for the key-change
/// flow.
///
/// Persistence keys reuse the old app's names where the semantics survive (Part 4.8 migration
/// reads the same keys); `capture_intent` is new — the migration importer maps the old
/// `background_enabled` bool onto it.
@Observable
@MainActor
final class AppSettings {
    nonisolated static let suiteName = "group.dev.audiocompanion"

    @ObservationIgnored private let defaults: UserDefaults
    /// Secrets live here, never in defaults. Exposed for the key-change screens.
    @ObservationIgnored let keychain: KeychainStore

    // ─── Truth table (Part 4.6) ─────────────────────────────────────────────

    var captureIntent: CaptureIntent {
        didSet { defaults.set(captureIntent.settingValue, forKey: Keys.captureIntent) }
    }

    var transcriptionMode: TranscriptionMode {
        didSet { defaults.set(transcriptionMode.rawValue, forKey: Keys.transcriptionMode) }
    }

    var localTranscriptionModelId: String {
        didSet { defaults.set(localTranscriptionModelId, forKey: Keys.localModel) }
    }

    var cloudTranscriptionProvider: CloudProvider {
        didSet { defaults.set(cloudTranscriptionProvider.rawValue, forKey: Keys.cloudProvider) }
    }

    var aiMode: AiProcessingMode {
        didSet { defaults.set(aiMode.rawValue, forKey: Keys.aiMode) }
    }

    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Keys.aiModel) }
    }

    var automaticWavExportEnabled: Bool {
        didSet { defaults.set(automaticWavExportEnabled, forKey: Keys.wavExport) }
    }

    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }

    /// REAL (Q7 — the old app's was placebo). Days of audio kept; enforced by retention.
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }

    /// Whether a Q14 transcription choice has been made. "Later" leaves this false, which
    /// drives the "Transcripts are off" status family until a mode is configured (6.7).
    var transcriptsConfigured: Bool {
        didSet { defaults.set(transcriptsConfigured, forKey: Keys.transcriptsConfigured) }
    }

    /// The approved "Keep audio" options (6.7).
    static let retentionOptions = [7, 14, 30, 90, 180, 365]

    // ─── API keys (Keychain only — B13) ─────────────────────────────────────

    /// Bumped on every key write so views re-derive masked values (the Keychain itself is
    /// not observable).
    private(set) var apiKeyRevision = 0

    func hasApiKey(for provider: CloudProvider) -> Bool {
        _ = apiKeyRevision
        return keychain.string(for: provider.keychainKey) != nil
    }

    /// Masked rendering ("sk-…gtT4") for the key-change flow — keys never render whole.
    func maskedApiKey(for provider: CloudProvider) -> String? {
        _ = apiKeyRevision
        return keychain.maskedString(for: provider.keychainKey)
    }

    @discardableResult
    func setApiKey(_ value: String, for provider: CloudProvider) -> Bool {
        defer { apiKeyRevision += 1 }
        return keychain.set(value, for: provider.keychainKey)
    }

    // ─── Init ───────────────────────────────────────────────────────────────

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain

        captureIntent =
            defaults.string(forKey: Keys.captureIntent)
            .flatMap(CaptureIntent.init(settingValue:)) ?? .off
        transcriptionMode =
            defaults.string(forKey: Keys.transcriptionMode).flatMap(TranscriptionMode.init)
            ?? .remoteFirst
        localTranscriptionModelId =
            defaults.string(forKey: Keys.localModel) ?? "parakeet-v3"
        cloudTranscriptionProvider =
            defaults.string(forKey: Keys.cloudProvider).flatMap(CloudProvider.init) ?? .soniox
        aiMode = defaults.string(forKey: Keys.aiMode).flatMap(AiProcessingMode.init) ?? .remoteFirst
        aiModel = defaults.string(forKey: Keys.aiModel) ?? "gpt-5.6-luna"
        automaticWavExportEnabled = defaults.bool(forKey: Keys.wavExport)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        let storedRetention = defaults.integer(forKey: Keys.retentionDays)
        retentionDays = AppSettings.retentionOptions.contains(storedRetention)
            ? storedRetention : 30
        transcriptsConfigured = defaults.bool(forKey: Keys.transcriptsConfigured)

        #if DEBUG
        // Simulator-automation staging: relaunching with these args re-enters/skips the
        // onboarding gate without a reinstall. DEBUG builds only.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-onboarding.reset") {
            onboardingComplete = false
            defaults.set(false, forKey: Keys.onboardingComplete)
        } else if args.contains("-onboarding.skip") {
            onboardingComplete = true
            defaults.set(true, forKey: Keys.onboardingComplete)
        }
        #endif
    }

    private enum Keys {
        static let captureIntent = "capture_intent"
        static let transcriptionMode = "transcription_mode"
        static let localModel = "local_transcription_model"
        static let cloudProvider = "cloud_transcription_provider"
        static let aiMode = "ai_mode"
        static let aiModel = "ai_model"
        static let wavExport = "automatic_wav_export"
        static let onboardingComplete = "onboarding_complete"
        static let retentionDays = "retention_days"
        static let transcriptsConfigured = "transcripts_configured"
    }
}

// ─── Display names (approved mode vocabulary) ───────────────────────────────

extension TranscriptionMode {
    /// Approved labels: "Cloud first" / "Local only" (+ natural extensions for the other cases).
    var displayName: String {
        switch self {
        case .remoteFirst: return Copy.Settings.TranscriptionAI.cloudFirst
        case .localFirst: return Copy.Settings.TranscriptionAI.localFirst
        case .localOnly: return Copy.Settings.TranscriptionAI.localOnly
        case .remoteOnly: return Copy.Settings.TranscriptionAI.cloudOnly
        }
    }
}

extension AiProcessingMode {
    /// Approved labels: "Remote first" / "Local only" (+ natural extensions).
    var displayName: String {
        switch self {
        case .remoteFirst: return Copy.Settings.TranscriptionAI.remoteFirst
        case .localFirst: return Copy.Settings.TranscriptionAI.localFirst
        case .localOnly: return Copy.Settings.TranscriptionAI.localOnly
        case .remoteOnly: return Copy.Settings.TranscriptionAI.remoteOnly
        }
    }
}
