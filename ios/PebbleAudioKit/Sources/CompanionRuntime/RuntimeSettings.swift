import Foundation
import Intelligence
import Receiver
import SearchKit
import Transcription

// The settings truth table (plan Part 4.6). Everything here is WIRED — no placebo controls.
// The app's `AppSettings` is the production implementation; its property names are mirrored
// exactly so conformance is declaration-only.

/// The settings surface the runtime reads. Read-only by design: `AppSettings` is the only
/// writer of user preferences, and the runtime never writes back.
///
/// Derived semantics (kept from the KMP truth table) live in the extension below, so no caller
/// re-derives `mode != .localOnly` by hand.
public protocol RuntimeSettings: Sendable {
    /// Plan 6.1 tri-state. `active`/`paused` are the Pause toggle; `off` is Background Audio.
    var captureIntent: CaptureIntent { get }
    var transcriptionMode: TranscriptionMode { get }
    var localTranscriptionModelId: String { get }
    var cloudTranscriptionProvider: CloudProvider { get }
    var aiMode: AiProcessingMode { get }
    var aiModel: String { get }
    var automaticWavExportEnabled: Bool { get }
    var onboardingComplete: Bool { get }
    /// REAL (the KMP one was placebo): days of audio kept, wired into `RetentionManager`.
    var retentionDays: Int { get }
    /// Total on-disk cap for stored audio, wired into `RetentionManager`. **`0` means no limit.**
    /// Defaulted so callers that only expose "Keep audio for N days" need not declare it.
    var retentionMaxBytes: Int64 { get }
    /// Whether fully transcribed audio older than `coldStorageMinAgeDays` leaves the phone for
    /// the app's iCloud Drive container (`ColdAudioTier`). Defaulted off: nothing leaves the
    /// phone until the person turns it on and sees the rule.
    var coldStorageEnabled: Bool { get }
    /// How old audio must be before it is moved. Defaulted so callers that do not care need
    /// not declare it.
    var coldStorageMinAgeDays: Int { get }
    /// False until the user picks a transcription mode ("Later" in onboarding leaves it false).
    var transcriptsConfigured: Bool { get }
    /// When expensive catch-up (local transcription, AI) may run while the app is not on screen.
    /// Defaulted so callers that do not care need not declare it. See `BackgroundWorkPolicy`.
    var backgroundCatchUp: BackgroundCatchUp { get }
    /// Which networks segment audio may be uploaded over. Defaulted so callers that do not care
    /// need not declare it. See `CloudUploadNetworkPolicy`.
    var cloudUploadNetwork: CloudUploadNetwork { get }
    /// Which remote model the AI router's remote slot is (OpenAI with the user's key, or Apple's
    /// Private Cloud Compute). Defaulted so callers that do not care need not declare it.
    var remoteAiProvider: RemoteAiProvider { get }
    /// How much of each recording the OS search index may see. Defaulted so callers that do not
    /// care need not declare it. See `SystemSearchVisibility`.
    var systemSearchVisibility: SystemSearchVisibility { get }
    /// Which Pebble Audio server this phone is linked to, and whether it syncs to it now.
    /// Defaulted (not linked) so callers that do not care need not declare it. The device token
    /// is in the Keychain, never here.
    var archiveSync: ArchiveSyncSettings { get }
}

extension RuntimeSettings {
    public var retentionMaxBytes: Int64 { RuntimeSettingsDefaults.retentionMaxBytes }
    public var coldStorageEnabled: Bool { RuntimeSettingsDefaults.coldStorageEnabled }
    public var coldStorageMinAgeDays: Int { RuntimeSettingsDefaults.coldStorageMinAgeDays }

    /// The age audio actually moves to iCloud at, given "Keep audio"; nil when Keep audio is too
    /// short for any offered age. See `RuntimeSettingsDefaults.effectiveColdStorageMinAgeDays`.
    public var effectiveColdStorageMinAgeDays: Int? {
        RuntimeSettingsDefaults.effectiveColdStorageMinAgeDays(
            chosen: coldStorageMinAgeDays, retentionDays: retentionDays)
    }

    /// The cold-storage rule this settings state implies. Its age is the EFFECTIVE one, never
    /// the raw choice: the raw "2 months" under the default "Keep audio · 30 days" was a rule
    /// that could never fire, because retention deleted every recording first.
    public var coldStoragePolicy: ColdStoragePolicy {
        let days = effectiveColdStorageMinAgeDays
        return ColdStoragePolicy(
            enabled: coldStorageEnabled && days != nil,
            minAgeMs: Int64(max(1, days ?? coldStorageMinAgeDays)) * 24 * 60 * 60 * 1000)
    }
    public var backgroundCatchUp: BackgroundCatchUp { .whileCharging }
    public var cloudUploadNetwork: CloudUploadNetwork { CloudUploadNetworkPolicy.default }
    public var remoteAiProvider: RemoteAiProvider { .default }
    public var systemSearchVisibility: SystemSearchVisibility { .default }
    public var archiveSync: ArchiveSyncSettings { ArchiveSyncSettings() }

    // --- Derived semantics (Part 4.6) ---------------------------------------------------------

    /// Cloud transcription is reachable in this mode. Also gates speaker labels and live cloud
    /// streaming — all three are the same predicate in the ported truth table.
    public var cloudTranscriptionEnabled: Bool { transcriptionMode != .localOnly }
    public var speakerLabelsEnabled: Bool { cloudTranscriptionEnabled }
    public var liveCloudEnabled: Bool { cloudTranscriptionEnabled }
    /// The REAL remote-AI gate (the KMP `remoteAiConsent` flag was dead weight).
    public var remoteAiEnabled: Bool { aiMode != .localOnly }
    /// Cloud is the *primary* path, so pending work should be handed to the background uploader
    /// on background entry rather than parked for the foreground.
    public var cloudIsPrimaryTranscription: Bool {
        transcriptionMode == .remoteOnly || transcriptionMode == .remoteFirst
    }

    /// The settings whose change could rescue a transcription that was given up on — see
    /// `TranscriptionRecoveryKey`.
    public var transcriptionRecoveryKey: TranscriptionRecoveryKey {
        TranscriptionRecoveryKey(
            transcriptionMode: transcriptionMode,
            localTranscriptionModelId: localTranscriptionModelId,
            cloudTranscriptionProvider: cloudTranscriptionProvider,
            cloudUploadNetwork: cloudUploadNetwork
        )
    }

    /// The settings whose change could rescue an AI job that failed — see `AiRecoveryKey`.
    public var aiRecoveryKey: AiRecoveryKey {
        AiRecoveryKey(aiMode: aiMode, remoteAiProvider: remoteAiProvider, aiModel: aiModel)
    }

    /// The retention policy this settings state implies.
    public var retentionConfig: RetentionConfigInputs {
        RetentionConfigInputs(
            maxAgeMs: Int64(max(1, retentionDays)) * 24 * 60 * 60 * 1000,
            // 0 (and anything below it) is "no size limit", not "delete everything on the next
            // sweep" — which is what a literal 0 would have meant to `RetentionManager`.
            maxTotalBytes: retentionMaxBytes > 0 ? retentionMaxBytes : .max
        )
    }
}

/// The settings a failed transcription can be rescued by changing: which engine runs, which
/// on-device model, which cloud, and which networks may carry the audio. (API keys are the other
/// rescue, and are not settings — `AppSettings` reports a key write on its own.)
///
/// Only a change in one of these revives given-up transcriptions. Everything else — the capture
/// switch, retention, AI settings, and above all the charger and thermal state, which change
/// dozens of times a day — only wakes the pipeline. On 2026-09-29 every one of those revived ~350
/// segments refused for an empty cloud account, each with a fresh eight-attempt ladder and, per
/// attempt, a full re-upload.
public struct TranscriptionRecoveryKey: Equatable, Sendable {
    public var transcriptionMode: TranscriptionMode
    public var localTranscriptionModelId: String
    public var cloudTranscriptionProvider: CloudProvider
    public var cloudUploadNetwork: CloudUploadNetwork
}

/// The settings a failed AI job can be rescued by changing: the mode (which provider runs
/// first, and whether the cloud may run at all), which remote provider, and which model. (The
/// OpenAI key is the other rescue; `AppSettings` reports a key write on its own.)
///
/// Only a change in one of these resets the AI retry budgets (`AiRetryPolicy`). Anything else
/// — the charger, the thermal state, the capture switch — must not, for the same reason the
/// transcription key exists: those change dozens of times a day, and a reset on each of them is
/// a full retry of every failed job on each.
public struct AiRecoveryKey: Equatable, Sendable {
    public var aiMode: AiProcessingMode
    public var remoteAiProvider: RemoteAiProvider
    public var aiModel: String
}

public enum RuntimeSettingsDefaults {
    /// Total-bytes cap for stored audio. **0 = no limit, and that is the default.**
    ///
    /// It used to be a hard 2 GiB that no screen named and no user chose. At the shipped Speex
    /// bitrate that is roughly 19 days of continuous capture, so it silently PRE-EMPTED the one
    /// retention rule the user actually picked: "Keep audio · 30 days" already lost audio to it,
    /// and "365 days" was off by more than an order of magnitude. Conversations vanished with no
    /// screen, no warning and no trace — and the retention sweep moved from once per launch to
    /// every 15 minutes, so the exposure went up, not down.
    ///
    /// The device is already protected without deleting anything: `RetentionConfig`'s free-space
    /// floors raise LOW_STORAGE at 2 GB free and ask the watch to PAUSE capture at 1 GB. That
    /// is a reversible, surfaced, user-visible response; deleting the user's only copy of a
    /// conversation is neither. So the byte cap is now opt-in: it evicts nothing unless the user
    /// set a limit themselves, which is the only way "no audio disappears without you having been
    /// told the rule" can actually hold.
    public static let retentionMaxBytes: Int64 = 0

    /// The limits the Settings picker offers, in bytes; `0` is the "No limit" row and the default.
    /// Lives here so the kit and the app cannot drift on what the picker may store.
    public static let retentionMaxBytesOptions: [Int64] = [
        0,
        2 * 1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        10 * 1024 * 1024 * 1024,
        25 * 1024 * 1024 * 1024,
        50 * 1024 * 1024 * 1024,
    ]

    public static let retentionDays = 30

    /// Off until chosen: audio leaving the phone is a rule the person has to have seen.
    public static let coldStorageEnabled = false
    /// Two months. Old enough that the audio has been transcribed, read and forgotten; young
    /// enough that the phone never holds more than a season of recordings.
    public static let coldStorageMinAgeDays = 60
    /// The ages the Storage screen offers, in days. Lives here so the kit and the app cannot
    /// drift on what the picker may store.
    public static let coldStorageMinAgeOptions = [14, 30, 60, 90, 180, 365]

    /// The cold-storage age that can actually take effect under "Keep audio · `retentionDays`".
    ///
    /// "Keep audio" deletes a recording — its audio from iCloud too — once it passes that age,
    /// and the retention stage runs before the cold-storage stage. So audio only ever moves if
    /// the move age is strictly YOUNGER than Keep audio. Until 2026-10-20 nothing enforced that,
    /// and the two defaults (move at 60 days, delete at 30) made the iCloud switch a control
    /// that did nothing at all: not one recording ever reached the age.
    ///
    /// The rule: the choice stands when it is younger than Keep audio; otherwise the oldest
    /// offered age that still is — the closest thing to what was asked for that can happen;
    /// nil when no offered age is (Keep audio at 14 days or less), and the Storage screen says
    /// why. The choice itself is not overwritten, so raising Keep audio again restores it.
    public static func effectiveColdStorageMinAgeDays(chosen: Int, retentionDays: Int) -> Int? {
        if chosen < retentionDays { return chosen }
        return coldStorageMinAgeOptions.filter { $0 < retentionDays }.max()
    }
}

/// The two retention knobs the runtime derives from settings; `RetentionService` turns these into
/// a `SegmentStore.RetentionConfig` (keeping the free-space floors at their ported defaults).
public struct RetentionConfigInputs: Equatable, Sendable {
    public var maxAgeMs: Int64
    public var maxTotalBytes: Int64

    public init(maxAgeMs: Int64, maxTotalBytes: Int64) {
        self.maxAgeMs = maxAgeMs
        self.maxTotalBytes = maxTotalBytes
    }
}

/// A thread-safe, mutable `RuntimeSettings` box.
///
/// The app's `AppSettings` is `@MainActor @Observable`; rather than force its stored properties
/// across the isolation boundary on every read from a background pass, the app mirrors changes
/// into this box (`box.apply { $0.captureIntent = ... }` in a `didSet`/`onChange`), and the
/// runtime reads the box. Tests use it directly as the fake.
public final class RuntimeSettingsBox: RuntimeSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: RuntimeSettingsSnapshot

    public init(_ snapshot: RuntimeSettingsSnapshot = RuntimeSettingsSnapshot()) {
        self.snapshot = snapshot
    }

    public var value: RuntimeSettingsSnapshot { lock.withLock { snapshot } }

    public func set(_ newValue: RuntimeSettingsSnapshot) {
        lock.withLock { snapshot = newValue }
    }

    public func apply(_ mutate: (inout RuntimeSettingsSnapshot) -> Void) {
        lock.withLock { mutate(&snapshot) }
    }

    public var captureIntent: CaptureIntent { value.captureIntent }
    public var transcriptionMode: TranscriptionMode { value.transcriptionMode }
    public var localTranscriptionModelId: String { value.localTranscriptionModelId }
    public var cloudTranscriptionProvider: CloudProvider { value.cloudTranscriptionProvider }
    public var aiMode: AiProcessingMode { value.aiMode }
    public var aiModel: String { value.aiModel }
    public var automaticWavExportEnabled: Bool { value.automaticWavExportEnabled }
    public var onboardingComplete: Bool { value.onboardingComplete }
    public var retentionDays: Int { value.retentionDays }
    public var retentionMaxBytes: Int64 { value.retentionMaxBytes }
    public var coldStorageEnabled: Bool { value.coldStorageEnabled }
    public var coldStorageMinAgeDays: Int { value.coldStorageMinAgeDays }
    public var transcriptsConfigured: Bool { value.transcriptsConfigured }
    // These two forwards are not optional, even though the protocol extension supplies a default
    // for both: WITHOUT them the box silently answers with the default and ignores the snapshot
    // the app just wrote into it. That is exactly what had happened to `backgroundCatchUp` — the
    // app mirrored the user's choice into `RuntimeSettingsSnapshot` on every change, the runtime
    // read it back through this box, and got `.whileCharging` regardless, so "Always" and "Only
    // When Open" did nothing at all. A protocol-extension default is a fallback for conformers
    // that have no such value; a box that HAS one must forward it.
    public var backgroundCatchUp: BackgroundCatchUp { value.backgroundCatchUp }
    public var cloudUploadNetwork: CloudUploadNetwork { value.cloudUploadNetwork }
    public var remoteAiProvider: RemoteAiProvider { value.remoteAiProvider }
    public var systemSearchVisibility: SystemSearchVisibility { value.systemSearchVisibility }
    public var archiveSync: ArchiveSyncSettings { value.archiveSync }
}

/// Plain value mirror of the truth table.
public struct RuntimeSettingsSnapshot: RuntimeSettings, Equatable, Sendable {
    public var captureIntent: CaptureIntent
    public var transcriptionMode: TranscriptionMode
    public var localTranscriptionModelId: String
    public var cloudTranscriptionProvider: CloudProvider
    public var aiMode: AiProcessingMode
    public var aiModel: String
    public var automaticWavExportEnabled: Bool
    public var onboardingComplete: Bool
    public var retentionDays: Int
    public var retentionMaxBytes: Int64
    public var coldStorageEnabled: Bool
    public var coldStorageMinAgeDays: Int
    public var transcriptsConfigured: Bool
    public var backgroundCatchUp: BackgroundCatchUp
    public var cloudUploadNetwork: CloudUploadNetwork
    public var remoteAiProvider: RemoteAiProvider
    public var systemSearchVisibility: SystemSearchVisibility
    public var archiveSync: ArchiveSyncSettings

    public init(
        captureIntent: CaptureIntent = .off,
        transcriptionMode: TranscriptionMode = .remoteFirst,
        localTranscriptionModelId: String = "",
        cloudTranscriptionProvider: CloudProvider = .soniox,
        aiMode: AiProcessingMode = .remoteFirst,
        aiModel: String = "",
        automaticWavExportEnabled: Bool = false,
        onboardingComplete: Bool = false,
        retentionDays: Int = RuntimeSettingsDefaults.retentionDays,
        retentionMaxBytes: Int64 = RuntimeSettingsDefaults.retentionMaxBytes,
        coldStorageEnabled: Bool = RuntimeSettingsDefaults.coldStorageEnabled,
        coldStorageMinAgeDays: Int = RuntimeSettingsDefaults.coldStorageMinAgeDays,
        transcriptsConfigured: Bool = false,
        backgroundCatchUp: BackgroundCatchUp = .whileCharging,
        cloudUploadNetwork: CloudUploadNetwork = CloudUploadNetworkPolicy.default,
        remoteAiProvider: RemoteAiProvider = .default,
        systemSearchVisibility: SystemSearchVisibility = .default,
        archiveSync: ArchiveSyncSettings = ArchiveSyncSettings()
    ) {
        self.captureIntent = captureIntent
        self.transcriptionMode = transcriptionMode
        self.localTranscriptionModelId = localTranscriptionModelId
        self.cloudTranscriptionProvider = cloudTranscriptionProvider
        self.aiMode = aiMode
        self.aiModel = aiModel
        self.automaticWavExportEnabled = automaticWavExportEnabled
        self.onboardingComplete = onboardingComplete
        self.retentionDays = retentionDays
        self.retentionMaxBytes = retentionMaxBytes
        self.coldStorageEnabled = coldStorageEnabled
        self.coldStorageMinAgeDays = coldStorageMinAgeDays
        self.transcriptsConfigured = transcriptsConfigured
        self.backgroundCatchUp = backgroundCatchUp
        self.cloudUploadNetwork = cloudUploadNetwork
        self.remoteAiProvider = remoteAiProvider
        self.systemSearchVisibility = systemSearchVisibility
        self.archiveSync = archiveSync
    }
}

/// The archive sync's preferences (`ArchiveSyncService`): the server this phone is linked to
/// and its id there, and the switch. The device token is in the Keychain
/// (`KeychainStore.Key.archiveDeviceToken`).
public struct ArchiveSyncSettings: Equatable, Sendable {
    /// The server's origin (`https://pebbleaudio.okgodoit.com`); nil when not linked.
    public var origin: String?
    /// This phone's id on that server.
    public var deviceId: String?
    /// Whether to sync now. Linking turns it on; turning it off keeps the link and the changes
    /// waiting, and sends them when it is turned back on.
    public var enabled: Bool

    public init(origin: String? = nil, deviceId: String? = nil, enabled: Bool = true) {
        self.origin = origin
        self.deviceId = deviceId
        self.enabled = enabled
    }

    public var isLinked: Bool { origin != nil && deviceId != nil }
}
