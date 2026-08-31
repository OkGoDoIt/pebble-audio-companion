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

    /// The runtime's view of this truth table.
    ///
    /// `AppSettings` is `@MainActor @Observable`, so it CANNOT conform to the kit's
    /// `RuntimeSettings` (a non-isolated `Sendable` protocol) soundly — the runtime reads
    /// settings from actors and background passes, and a main-actor-isolated getter reached
    /// from there is a data race the compiler only forgives in Swift 5 mode. So the truth
    /// table is mirrored into this lock-guarded box from every `didSet`, and the runtime
    /// reads the box. One writer (this class), one reader surface (the box).
    @ObservationIgnored let runtimeSettings = RuntimeSettingsBox()

    /// Installed by `AppComposition` so a settings change wakes the pipeline immediately
    /// instead of waiting for the loop's next tick.
    @ObservationIgnored var onRuntimeSettingsChanged: (@Sendable () -> Void)?

    /// Rebuilds the runtime mirror. Called from every `didSet` and once at the end of `init`
    /// (property observers do not fire during initialization).
    private func mirrorToRuntime() {
        runtimeSettings.set(
            RuntimeSettingsSnapshot(
                captureIntent: captureIntent,
                transcriptionMode: transcriptionMode,
                localTranscriptionModelId: localTranscriptionModelId,
                cloudTranscriptionProvider: cloudTranscriptionProvider,
                aiMode: aiMode,
                aiModel: aiModel,
                automaticWavExportEnabled: automaticWavExportEnabled,
                onboardingComplete: onboardingComplete,
                retentionDays: retentionDays,
                retentionMaxBytes: RuntimeSettingsDefaults.retentionMaxBytes,
                transcriptsConfigured: transcriptsConfigured
            )
        )
        onRuntimeSettingsChanged?()
    }

    // ─── Truth table (Part 4.6) ─────────────────────────────────────────────

    var captureIntent: CaptureIntent {
        didSet {
            defaults.set(captureIntent.settingValue, forKey: Keys.captureIntent)
            mirrorToRuntime()
        }
    }

    var transcriptionMode: TranscriptionMode {
        didSet {
            defaults.set(transcriptionMode.rawValue, forKey: Keys.transcriptionMode)
            mirrorToRuntime()
        }
    }

    /// Which on-device engine transcription uses — an id from the local-model catalog
    /// ("apple-speech", "parakeet-tdt-0.6b-v3-int8", …). Same key the old app persisted, so a
    /// migrated choice survives.
    var localTranscriptionModelId: String {
        didSet {
            defaults.set(localTranscriptionModelId, forKey: Keys.localModel)
            mirrorToRuntime()
        }
    }

    var cloudTranscriptionProvider: CloudProvider {
        didSet {
            defaults.set(cloudTranscriptionProvider.rawValue, forKey: Keys.cloudProvider)
            mirrorToRuntime()
        }
    }

    var aiMode: AiProcessingMode {
        didSet {
            defaults.set(aiMode.rawValue, forKey: Keys.aiMode)
            mirrorToRuntime()
        }
    }

    var aiModel: String {
        didSet {
            defaults.set(aiModel, forKey: Keys.aiModel)
            mirrorToRuntime()
        }
    }

    var automaticWavExportEnabled: Bool {
        didSet {
            defaults.set(automaticWavExportEnabled, forKey: Keys.wavExport)
            mirrorToRuntime()
        }
    }

    var onboardingComplete: Bool {
        didSet {
            defaults.set(onboardingComplete, forKey: Keys.onboardingComplete)
            mirrorToRuntime()
        }
    }

    /// REAL (Q7 — the old app's was placebo). Days of audio kept; enforced by retention.
    var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: Keys.retentionDays)
            mirrorToRuntime()
        }
    }

    /// The Q9 loss alert, OFF by default and opt-in. An unasked-for notification the moment a
    /// Bluetooth blip drops a few seconds is noise on a device you wear all day; the coverage
    /// strip already tells the story calmly, in place, whenever you look. Turning this on is
    /// what asks for notification permission — the app never prompts on its own.
    var lossAlertsEnabled: Bool {
        didSet {
            defaults.set(lossAlertsEnabled, forKey: Keys.lossAlerts)
            mirrorToRuntime()
        }
    }

    /// Whether a Q14 transcription choice has been made. "Later" leaves this false, which
    /// drives the "Transcripts are off" status family until a mode is configured (6.7).
    var transcriptsConfigured: Bool {
        didSet {
            defaults.set(transcriptsConfigured, forKey: Keys.transcriptsConfigured)
            mirrorToRuntime()
        }
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

    @discardableResult
    func removeApiKey(for provider: CloudProvider) -> Bool {
        defer { apiKeyRevision += 1 }
        return keychain.remove(provider.keychainKey)
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
        // Apple Speech is the engine that is present on every iOS 26 phone with nothing to
        // download, so it is the default until the user picks another from the catalog.
        localTranscriptionModelId =
            defaults.string(forKey: Keys.localModel) ?? LocalModelCatalog.defaultModelId
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
        // Absent key => false: the loss alert is opt-in, so a fresh install is silent.
        lossAlertsEnabled = defaults.bool(forKey: Keys.lossAlerts)

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

        // Property observers do not fire during initialization, so seed the mirror here.
        mirrorToRuntime()
    }

    /// Re-reads every key from defaults.
    ///
    /// Called once, after `LegacyImporter` runs: the importer writes the migrated preferences
    /// into the App Group AFTER this object was constructed, and without this a migrated user
    /// would see the onboarding gate for one launch despite having finished it long ago.
    func reloadFromDefaults() {
        if let stored = defaults.string(forKey: Keys.captureIntent).flatMap(
            CaptureIntent.init(settingValue:)
        ) {
            captureIntent = stored
        }
        if let stored = defaults.string(forKey: Keys.transcriptionMode).flatMap(
            TranscriptionMode.init
        ) {
            transcriptionMode = stored
        }
        if let stored = defaults.string(forKey: Keys.localModel) {
            localTranscriptionModelId = stored
        }
        if let stored = defaults.string(forKey: Keys.cloudProvider).flatMap(CloudProvider.init) {
            cloudTranscriptionProvider = stored
        }
        if let stored = defaults.string(forKey: Keys.aiMode).flatMap(AiProcessingMode.init) {
            aiMode = stored
        }
        if let stored = defaults.string(forKey: Keys.aiModel) { aiModel = stored }
        automaticWavExportEnabled = defaults.bool(forKey: Keys.wavExport)
        let storedRetention = defaults.integer(forKey: Keys.retentionDays)
        if AppSettings.retentionOptions.contains(storedRetention) { retentionDays = storedRetention }
        transcriptsConfigured = defaults.bool(forKey: Keys.transcriptsConfigured)
        // Absent key => false: the loss alert is opt-in, so a fresh install is silent.
        lossAlertsEnabled = defaults.bool(forKey: Keys.lossAlerts)
        // Onboarding LAST: it is the one key that changes what the user sees immediately, and a
        // migrated "yes" must never be undone by a half-applied reload.
        if defaults.bool(forKey: Keys.onboardingComplete) { onboardingComplete = true }
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
        static let lossAlerts = "loss_alerts_enabled"
    }
}

// ─── Where data actually goes (privacy copy — P0) ───────────────────────────

extension AppSettings {
    /// The current modes as a plain truth-table value, so the derived predicates the pipeline is
    /// gated on (`cloudTranscriptionEnabled`, `remoteAiEnabled`) answer the privacy copy too — a
    /// sentence about where data goes must not re-derive its own version of that rule.
    ///
    /// Built from the OBSERVED stored properties rather than from `runtimeSettings`: the mirror
    /// is `@ObservationIgnored`, so a view reading it registers no dependency and goes on showing
    /// the previous answer after a mode change — a stale privacy claim is the bug being fixed.
    private var modes: RuntimeSettingsSnapshot {
        RuntimeSettingsSnapshot(transcriptionMode: transcriptionMode, aiMode: aiMode)
    }

    /// The cloud transcription provider audio is actually sent to, or nil when nothing is.
    var cloudTranscriptionDestination: String? {
        modes.cloudTranscriptionEnabled ? cloudTranscriptionProvider.displayName : nil
    }

    /// The provider transcripts (and the About You context) reach on remote AI runs, or nil in
    /// AI "Local only" — same gate as `OpenAiChatAiProvider`'s consent closure.
    var remoteAiDestination: String? {
        modes.remoteAiEnabled ? Copy.Privacy.remoteAi : nil
    }

    /// e.g. "Soniox and OpenAI" — every destination this configuration sends to, or nil when
    /// everything stays on the phone.
    var cloudDestinations: String? {
        Copy.Privacy.destinations([cloudTranscriptionDestination, remoteAiDestination])
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
