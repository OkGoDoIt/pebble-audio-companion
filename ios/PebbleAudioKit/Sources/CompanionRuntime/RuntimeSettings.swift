import Foundation
import Intelligence
import Receiver
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
    /// Total on-disk cap for stored audio, wired into `RetentionManager`. Defaulted so callers
    /// that only expose "Keep audio for N days" need not declare it.
    var retentionMaxBytes: Int64 { get }
    /// False until the user picks a transcription mode ("Later" in onboarding leaves it false).
    var transcriptsConfigured: Bool { get }
}

extension RuntimeSettings {
    public var retentionMaxBytes: Int64 { RuntimeSettingsDefaults.retentionMaxBytes }

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

    /// The retention policy this settings state implies.
    public var retentionConfig: RetentionConfigInputs {
        RetentionConfigInputs(
            maxAgeMs: Int64(max(1, retentionDays)) * 24 * 60 * 60 * 1000,
            maxTotalBytes: retentionMaxBytes
        )
    }
}

public enum RuntimeSettingsDefaults {
    public static let retentionMaxBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let retentionDays = 30
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
    public var transcriptsConfigured: Bool { value.transcriptsConfigured }
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
    public var transcriptsConfigured: Bool

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
        transcriptsConfigured: Bool = false
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
        self.transcriptsConfigured = transcriptsConfigured
    }
}
