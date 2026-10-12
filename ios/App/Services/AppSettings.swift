import Foundation
import Observation
import Receiver
import Transcription
import Intelligence
import CompanionRuntime
import SearchKit

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

    /// Installed by `AppComposition`: a key was saved or removed. Keys live in the Keychain, not
    /// in the runtime mirror, so without this a new key — the fix for a rejected one — changed
    /// nothing until the six-hourly revival sweep.
    @ObservationIgnored var onApiKeyChanged: (@Sendable () -> Void)?

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
                retentionMaxBytes: retentionMaxBytes,
                coldStorageEnabled: coldStorageEnabled,
                coldStorageMinAgeDays: coldStorageMinAgeDays,
                transcriptsConfigured: transcriptsConfigured,
                backgroundCatchUp: backgroundCatchUp,
                cloudUploadNetwork: cloudUploadNetwork,
                remoteAiProvider: remoteAiProvider,
                systemSearchVisibility: systemSearchVisibility
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

    /// The capture intent to put back if the onboarding run that switched capture on never
    /// finishes.
    ///
    /// Step 1's "Connect Watch" writes `captureIntent = .active` (`LiveWatchPairingSource`), on
    /// purpose — it is the same path Today's Start takes, and a COMPLETED onboarding is meant to
    /// leave capture running. Until the flow finishes, though, that switch is PROVISIONAL, and
    /// only one exit ever undid it: the Cancel button on step 2. Someone who got past pairing and
    /// then walked away — backgrounded at the processing question, force-quit, or had the process
    /// reclaimed — came back to a live microphone they never agreed to. Onboarding is re-runnable
    /// from Settings → Diagnostics now, so "they deliberately had capture off before" is the
    /// ordinary case rather than a fresh-install curiosity.
    ///
    /// `nil` means no run is in flight. It is persisted because the exits that matter are exactly
    /// the ones that end the process.
    @ObservationIgnored private(set) var onboardingCaptureRestore: CaptureIntent?

    /// An OPT-IN timed pause (`CapturePauseSchedule`). `.none` — and nothing scheduled — is the
    /// default and stays the default: flipping the capture switch off writes `.off` with no
    /// timer and no notification, exactly as it always did. A schedule exists only after
    /// someone chose a duration from the "Pause for…" menu.
    ///
    /// Persisted in the App Group so a pause survives relaunch, and NOT mirrored into
    /// `RuntimeSettingsSnapshot`: the runtime is told about a pause the only way it has ever
    /// been told — by `captureIntent` — and a second channel for the same fact is a second
    /// thing that can disagree.
    var capturePause: CapturePauseSchedule {
        didSet {
            guard capturePause != oldValue else { return }
            defaults.set(NSNumber(value: capturePause.resumeAtMs), forKey: Keys.pauseResumeAtMs)
            defaults.set(NSNumber(value: capturePause.remindAtMs), forKey: Keys.pauseRemindAtMs)
        }
    }

    var transcriptionMode: TranscriptionMode {
        didSet {
            defaults.set(transcriptionMode.rawValue, forKey: Keys.transcriptionMode)
            mirrorToRuntime()
        }
    }

    /// When transcription is allowed to catch up while the app is not on screen. The default
    /// waits for a charger, which is free; Low Power Mode and a hot phone override it either way.
    var backgroundCatchUp: BackgroundCatchUp {
        didSet {
            defaults.set(backgroundCatchUp.rawValue, forKey: Keys.backgroundCatchUp)
            mirrorToRuntime()
        }
    }

    /// Which networks segment audio may be uploaded over. Wi-Fi only by default: the upload is
    /// the one genuinely large thing this app sends, and nothing is lost by waiting — the audio
    /// is spooled and the queue re-offers it the moment a permitted network appears. See
    /// `CloudUploadNetworkPolicy`. Read by the background uploader through the runtime box, which
    /// is installed once at the end of `init`.
    var cloudUploadNetwork: CloudUploadNetwork {
        didSet {
            defaults.set(cloudUploadNetwork.rawValue, forKey: Keys.cloudUploadNetwork)
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

    /// What the AI router's "remote" slot is: OpenAI with the user's key (historical), or Apple's
    /// Private Cloud Compute (iOS 27; no key, daily quota). The four `aiMode`s are unchanged —
    /// this only decides where "remote" goes, exactly as `cloudTranscriptionProvider` does for
    /// transcription. Persisted so the choice survives; absent key => OpenAI, which is what every
    /// existing install was using.
    var remoteAiProvider: RemoteAiProvider {
        didSet {
            defaults.set(remoteAiProvider.rawValue, forKey: Keys.remoteAiProvider)
            mirrorToRuntime()
        }
    }

    /// How much of each recording the OS search index (Spotlight / Siri) may see. Absent key =>
    /// `.full`, the historical behaviour, so nothing an existing install could already find in
    /// Spotlight disappears on update. See `SystemSearchVisibility`.
    var systemSearchVisibility: SystemSearchVisibility {
        didSet {
            defaults.set(systemSearchVisibility.rawValue, forKey: Keys.systemSearchVisibility)
            mirrorToRuntime()
        }
    }

    /// Whether Ask may add Spotlight's semantic ranking to its keyword ranking when a question's
    /// scope is too large to read whole and something has to be left out. Additive by design
    /// (a keyword match is never displaced by it); the switch exists so the two rankings can be
    /// compared on real questions. Absent key => on. App-side only: the Ask flow reads it on
    /// the main actor, nothing in the runtime does.
    var askSemanticRecallEnabled: Bool {
        didSet { defaults.set(askSemanticRecallEnabled, forKey: Keys.askSemanticRecall) }
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

    /// Total on-disk limit for stored audio, in bytes. **0 = no limit, and that is the default.**
    ///
    /// This was a hardcoded 2 GiB that no screen named and no user chose, applied on top of
    /// "Keep audio · N days" — so at the shipped bitrate it quietly pre-empted every retention
    /// choice past ~19 days of capture and took whole conversations with it. It is a real,
    /// user-set limit now: it evicts nothing unless someone asks it to, and the Storage screen
    /// states the rule. Device storage is still protected without deleting anything — retention's
    /// free-space floors raise LOW_STORAGE at 2 GB free and pause capture on the watch at
    /// 1 GB (`RetentionConfig`), both of which the user can see and undo.
    var retentionMaxBytes: Int64 {
        didSet {
            defaults.set(retentionMaxBytes, forKey: Keys.retentionMaxBytes)
            mirrorToRuntime()
        }
    }

    /// Whether fully transcribed audio older than `coldStorageMinAgeDays` leaves the phone for
    /// the app's iCloud Drive container (`ColdAudioTier`). Off until chosen: audio leaving the
    /// phone is a rule the person has to have seen. Turning it off moves nothing back on its
    /// own — the Storage screen offers that as its own action — so a toggle tapped twice is
    /// not two gigabytes of traffic.
    var coldStorageEnabled: Bool {
        didSet {
            defaults.set(coldStorageEnabled, forKey: Keys.coldStorageEnabled)
            mirrorToRuntime()
        }
    }

    /// How old audio must be before it moves to iCloud, in days. Default two months.
    var coldStorageMinAgeDays: Int {
        didSet {
            defaults.set(coldStorageMinAgeDays, forKey: Keys.coldStorageMinAgeDays)
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

    // ─── Onboarding's provisional capture switch ────────────────────────────

    /// Onboarding is about to switch capture on. Records what to put back.
    ///
    /// First writer wins, and that is the point: step 2 is retryable, so by the second attempt
    /// the stored intent is ALREADY `.active` — re-reading it would record "leave it on" and lose
    /// the real answer. (That is also why Cancel after a retry used to do nothing at all.)
    func beginOnboardingCaptureAttempt() {
        guard onboardingCaptureRestore == nil else { return }
        setOnboardingCaptureRestore(captureIntent)
    }

    /// The run ended WITHOUT finishing. Consumes the marker and returns the intent to put back,
    /// or nil when there is nothing to undo — no run in flight, or capture was already where the
    /// marker says it should be (someone who had it on before does not get it switched off).
    func takeOnboardingCaptureRestore() -> CaptureIntent? {
        let previous = onboardingCaptureRestore
        setOnboardingCaptureRestore(nil)
        guard let previous, previous != captureIntent else { return nil }
        return previous
    }

    /// The run FINISHED. Capture stays exactly where onboarding left it — that is what Connect
    /// Watch is for — so the marker is dropped without restoring anything.
    func onboardingCaptureAttemptCompleted() {
        setOnboardingCaptureRestore(nil)
    }

    private func setOnboardingCaptureRestore(_ intent: CaptureIntent?) {
        onboardingCaptureRestore = intent
        if let intent {
            defaults.set(intent.settingValue, forKey: Keys.onboardingCaptureRestore)
        } else {
            defaults.removeObject(forKey: Keys.onboardingCaptureRestore)
        }
    }

    /// Undoes a provisional "Connect Watch" that no completed onboarding ever ratified.
    ///
    /// Called once per process from `init`, which is the only hook that covers every way the flow
    /// can be abandoned — including a headless Core Bluetooth restoration launch, where there is
    /// no window, no `onAppear` and no scene phase. It also lands before `AppComposition` reads
    /// `settings.captureIntent` for the receiver's `initialIntent`, so the corrected value is what
    /// the runtime starts on: no second write, no extra actor hop, no widget flicker.
    ///
    /// It deliberately does NOT fire on `.background`. Stepping out to a password manager for an
    /// API key at the last step is a normal part of FINISHING onboarding, and switching capture
    /// off there would contradict the person's own tap and flap a recording already running on the
    /// watch (an off/on pair of commands, i.e. a real gap in the audio). The residual window is an
    /// app that stays resident, backgrounded, mid-flow: capture then stays on until the process
    /// next starts. That is the state the person's own tap plus their on-watch consent put it in,
    /// and the next launch corrects it.
    private func restoreCaptureIfOnboardingWasAbandoned() {
        guard !onboardingComplete, let previous = onboardingCaptureRestore else { return }
        onboardingCaptureRestore = nil
        defaults.removeObject(forKey: Keys.onboardingCaptureRestore)
        guard previous != captureIntent else { return }
        // Property observers do not fire during initialization, so the defaults write is explicit
        // (the same reason the `-onboarding.reset` staging block below writes both).
        captureIntent = previous
        defaults.set(previous.settingValue, forKey: Keys.captureIntent)
    }

    /// The approved "Keep audio" options (6.7).
    static let retentionOptions = [7, 14, 30, 90, 180, 365]

    /// The "Storage limit" options, in bytes; `0` is "No limit" and the default. Sourced from the
    /// kit so the picker can only ever store a value retention understands.
    static let retentionLimitOptions = RuntimeSettingsDefaults.retentionMaxBytesOptions
    /// The ages the iCloud rule offers, in days.
    static let coldStorageAgeOptions = RuntimeSettingsDefaults.coldStorageMinAgeOptions

    /// Row value for a storage limit — "No limit" or e.g. "5 GB". The options are exact
    /// gibibytes, so they are named as round numbers rather than run through a measured-size
    /// formatter that would render the chosen "2 GB" back as "2.0 GB".
    static func retentionLimitLabel(_ bytes: Int64) -> String {
        bytes <= 0 ? "No limit" : "\(bytes / (1 << 30)) GB"
    }

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
        defer {
            apiKeyRevision += 1
            onApiKeyChanged?()
        }
        return keychain.set(value, for: provider.keychainKey)
    }

    @discardableResult
    func removeApiKey(for provider: CloudProvider) -> Bool {
        defer {
            apiKeyRevision += 1
            onApiKeyChanged?()
        }
        return keychain.remove(provider.keychainKey)
    }

    /// The stored cloud model, after moving the OLD default to the new one exactly once.
    ///
    /// The default became GPT-6 Luna on 2026-09-30. A phone that has "gpt-5.6-luna" stored
    /// cannot say whether that was a choice or the default the old app wrote down (the
    /// migration importer copied it), and leaving it would make the new default reach nobody
    /// who already has the app. So the first launch after the change moves that one value, and
    /// records that it did: GPT-5.6 Luna stays in the picker, and picking it afterwards sticks.
    /// Any other stored model is a choice and is left alone.
    static func storedAiModel(_ defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: Keys.aiModel)
        guard !defaults.bool(forKey: Keys.aiModelMovedToGpt6Default) else {
            return stored ?? AiModels.defaultModelId
        }
        defaults.set(true, forKey: Keys.aiModelMovedToGpt6Default)
        guard stored == "gpt-5.6-luna" else { return stored ?? AiModels.defaultModelId }
        defaults.set(AiModels.defaultModelId, forKey: Keys.aiModel)
        return AiModels.defaultModelId
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
        onboardingCaptureRestore =
            defaults.string(forKey: Keys.onboardingCaptureRestore)
            .flatMap(CaptureIntent.init(settingValue:))
        capturePause = AppSettings.storedPauseSchedule(defaults)
        backgroundCatchUp =
            defaults.string(forKey: Keys.backgroundCatchUp).flatMap(BackgroundCatchUp.init)
            ?? .whileCharging
        // Absent key => Wi-Fi only. Existing installs land here too, which is the point: the
        // upload session had no network policy at all and was free to spend cellular data.
        cloudUploadNetwork =
            defaults.string(forKey: Keys.cloudUploadNetwork).flatMap(CloudUploadNetwork.init)
            ?? CloudUploadNetworkPolicy.default
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
        aiModel = AppSettings.storedAiModel(defaults)
        remoteAiProvider =
            defaults.string(forKey: Keys.remoteAiProvider).flatMap(RemoteAiProvider.init)
            ?? .default
        systemSearchVisibility =
            defaults.string(forKey: Keys.systemSearchVisibility)
            .flatMap(SystemSearchVisibility.init) ?? .default
        // Absent key => on (`bool(forKey:)` would read false).
        askSemanticRecallEnabled =
            (defaults.object(forKey: Keys.askSemanticRecall) as? Bool) ?? true
        automaticWavExportEnabled = defaults.bool(forKey: Keys.wavExport)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        let storedRetention = defaults.integer(forKey: Keys.retentionDays)
        retentionDays = AppSettings.retentionOptions.contains(storedRetention)
            ? storedRetention : 30
        // Absent key => 0 => no limit. Nobody has ever been offered this choice, so nobody's
        // audio may be evicted by it until they make one.
        let storedLimit = Int64(defaults.integer(forKey: Keys.retentionMaxBytes))
        retentionMaxBytes = AppSettings.retentionLimitOptions.contains(storedLimit) ? storedLimit : 0
        transcriptsConfigured = defaults.bool(forKey: Keys.transcriptsConfigured)
        // Absent key => false: the loss alert is opt-in, so a fresh install is silent.
        lossAlertsEnabled = defaults.bool(forKey: Keys.lossAlerts)
        coldStorageEnabled = defaults.bool(forKey: Keys.coldStorageEnabled)
        let storedColdAge = defaults.integer(forKey: Keys.coldStorageMinAgeDays)
        coldStorageMinAgeDays = AppSettings.coldStorageAgeOptions.contains(storedColdAge)
            ? storedColdAge : RuntimeSettingsDefaults.coldStorageMinAgeDays

        #if DEBUG
        // Simulator-automation staging: relaunching with these args re-enters/skips the
        // onboarding gate without a reinstall. DEBUG builds only.
        let args = ProcessInfo.processInfo.arguments
        // `-storage.seed` (see `StorageSeed`) fills eight months of recordings; the default
        // "Keep audio · 30 days" would sweep most of them on the first pass. Read here, before
        // the composition runs that pass.
        if args.contains("-storage.seed") {
            retentionDays = 365
            defaults.set(365, forKey: Keys.retentionDays)
        }
        if args.contains("-onboarding.reset") {
            onboardingComplete = false
            defaults.set(false, forKey: Keys.onboardingComplete)
        } else if args.contains("-onboarding.skip") {
            onboardingComplete = true
            defaults.set(true, forKey: Keys.onboardingComplete)
        }
        #endif

        // A "Connect Watch" that no completed onboarding ever ratified does not get to leave the
        // microphone on. Must precede `mirrorToRuntime()` — the runtime reads the mirror.
        restoreCaptureIfOnboardingWasAbandoned()

        // Property observers do not fire during initialization, so seed the mirror here.
        mirrorToRuntime()

        // Point the background uploader at the live setting. Registered here rather than in
        // `AppComposition` because the uploader is a process-wide singleton created long before
        // the runtime is assembled, and a background `URLSession` cannot be reconfigured once it
        // exists — so the policy has to be read per request, from a box that outlives both.
        let box = runtimeSettings
        URLSessionBackgroundUploader.shared.setNetworkPolicy { box.cloudUploadNetwork }
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
        capturePause = AppSettings.storedPauseSchedule(defaults)
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
        if let stored = defaults.string(forKey: Keys.remoteAiProvider)
            .flatMap(RemoteAiProvider.init)
        {
            remoteAiProvider = stored
        }
        if let stored = defaults.string(forKey: Keys.systemSearchVisibility)
            .flatMap(SystemSearchVisibility.init)
        {
            systemSearchVisibility = stored
        }
        if let stored = defaults.object(forKey: Keys.askSemanticRecall) as? Bool {
            askSemanticRecallEnabled = stored
        }
        automaticWavExportEnabled = defaults.bool(forKey: Keys.wavExport)
        let storedRetention = defaults.integer(forKey: Keys.retentionDays)
        if AppSettings.retentionOptions.contains(storedRetention) { retentionDays = storedRetention }
        let storedLimit = Int64(defaults.integer(forKey: Keys.retentionMaxBytes))
        if AppSettings.retentionLimitOptions.contains(storedLimit) { retentionMaxBytes = storedLimit }
        transcriptsConfigured = defaults.bool(forKey: Keys.transcriptsConfigured)
        // Absent key => false: the loss alert is opt-in, so a fresh install is silent.
        lossAlertsEnabled = defaults.bool(forKey: Keys.lossAlerts)
        coldStorageEnabled = defaults.bool(forKey: Keys.coldStorageEnabled)
        let storedColdAge = defaults.integer(forKey: Keys.coldStorageMinAgeDays)
        if AppSettings.coldStorageAgeOptions.contains(storedColdAge) {
            coldStorageMinAgeDays = storedColdAge
        }
        // Onboarding LAST: it is the one key that changes what the user sees immediately, and a
        // migrated "yes" must never be undone by a half-applied reload.
        if defaults.bool(forKey: Keys.onboardingComplete) { onboardingComplete = true }
    }

    /// Absent keys => 0 => nothing armed, which is what every install that has never used the
    /// "Pause for…" menu reads back.
    private static func storedPauseSchedule(_ defaults: UserDefaults) -> CapturePauseSchedule {
        CapturePauseSchedule(
            resumeAtMs: (defaults.object(forKey: Keys.pauseResumeAtMs) as? NSNumber)?.int64Value
                ?? 0,
            remindAtMs: (defaults.object(forKey: Keys.pauseRemindAtMs) as? NSNumber)?.int64Value
                ?? 0
        )
    }

    private enum Keys {
        static let captureIntent = "capture_intent"
        /// Present only while an onboarding run has capture switched on provisionally.
        static let onboardingCaptureRestore = "onboarding_capture_restore"
        static let pauseResumeAtMs = "capture_pause_resume_at_ms"
        static let pauseRemindAtMs = "capture_pause_remind_at_ms"
        static let transcriptionMode = "transcription_mode"
        static let backgroundCatchUp = "background_catch_up"
        static let cloudUploadNetwork = "cloud_upload_network"
        static let localModel = "local_transcription_model"
        static let cloudProvider = "cloud_transcription_provider"
        static let aiMode = "ai_mode"
        static let aiModel = "ai_model"
        static let aiModelMovedToGpt6Default = "ai_model_moved_to_gpt6_default"
        static let wavExport = "automatic_wav_export"
        static let onboardingComplete = "onboarding_complete"
        static let retentionDays = "retention_days"
        static let retentionMaxBytes = "retention_max_bytes"
        static let transcriptsConfigured = "transcripts_configured"
        static let lossAlerts = "loss_alerts_enabled"
        static let remoteAiProvider = "remote_ai_provider"
        static let systemSearchVisibility = "system_search_visibility"
        static let askSemanticRecall = "ask_semantic_recall"
        static let coldStorageEnabled = "cold_storage_enabled"
        static let coldStorageMinAgeDays = "cold_storage_min_age_days"
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
    /// AI "Local only" — same gate as `OpenAiChatAiProvider`'s consent closure. WHICH provider
    /// is `remoteAiProvider`: OpenAI, or (iOS 27) Apple Private Cloud Compute — named in full,
    /// because "text goes to Apple" would also describe the on-device model.
    var remoteAiDestination: String? {
        modes.remoteAiEnabled ? Copy.Privacy.remoteAiName(for: remoteAiProvider) : nil
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
