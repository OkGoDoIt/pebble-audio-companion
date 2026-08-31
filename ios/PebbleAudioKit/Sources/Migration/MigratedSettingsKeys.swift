import Foundation

/// The UserDefaults vocabulary on both sides of the migration (plan Part 4.8 / 6.4).
///
/// OLD side: the KMP app persisted settings in the STANDARD defaults under
/// `IosAudioCompanionSettingsRepository`'s key names, and the receiver identity under
/// `receiver_id_v1` (`IosAudioCompanionRuntimeFactory`).
///
/// NEW side: the SwiftUI app reads the app-group suite `group.dev.audiocompanion` under the
/// key names in `ios/App/Services/AppSettings.swift` (its `Keys` enum is private, so they are
/// duplicated here — change only together). Most names survive unchanged; the two mappings:
/// `background_enabled` (Bool) becomes `capture_intent` ("active"/"off" — the old app had no
/// paused state), and a migrated `transcription_mode` also sets `transcripts_configured` so a
/// migrated user is not shown the "Transcripts are off" first-run card for a choice they
/// already made.
public enum MigratedSettingsKeys {
    /// New app-group defaults suite (`AppSettings.suiteName`).
    public static let appGroupSuite = "group.dev.audiocompanion"

    // ── Old keys, standard defaults ─────────────────────────────────────────
    public static let oldReceiverId = "receiver_id_v1"
    public static let oldBackgroundEnabled = "background_enabled"
    public static let oldTranscriptionMode = "transcription_mode"
    public static let oldLocalTranscriptionModel = "local_transcription_model"
    public static let oldCloudTranscriptionProvider = "cloud_transcription_provider"
    public static let oldOpenAiApiKey = "openai_api_key"
    public static let oldSonioxApiKey = "soniox_api_key"
    public static let oldAiMode = "ai_mode"
    public static let oldAiModel = "ai_model"
    public static let oldRetentionDays = "retention_days"
    public static let oldAutomaticWavExport = "automatic_wav_export"
    public static let oldOnboardingComplete = "onboarding_complete"

    // ── New keys, app-group suite (match AppSettings.Keys) ──────────────────
    public static let newCaptureIntent = "capture_intent"
    public static let newTranscriptionMode = "transcription_mode"
    public static let newLocalTranscriptionModel = "local_transcription_model"
    public static let newCloudTranscriptionProvider = "cloud_transcription_provider"
    public static let newAiMode = "ai_mode"
    public static let newAiModel = "ai_model"
    public static let newRetentionDays = "retention_days"
    public static let newAutomaticWavExport = "automatic_wav_export"
    public static let newOnboardingComplete = "onboarding_complete"
    public static let newTranscriptsConfigured = "transcripts_configured"

    /// `capture_intent` encodings (must match `CaptureIntent.settingValue` in AppSettings).
    public static let captureIntentActive = "active"
    public static let captureIntentOff = "off"
}
