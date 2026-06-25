package dev.audiocompanion.app

import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.transcription.CloudProvider
import dev.audiocompanion.transcription.TranscriptionMode
import kotlinx.coroutines.flow.StateFlow

data class AudioCompanionSettings(
    val backgroundReceiverEnabled: Boolean = false,
    val retentionDays: Int = 30,
    val retentionMaxBytes: Long = 2L * 1024 * 1024 * 1024,
    val transcriptionMode: TranscriptionMode = TranscriptionMode.LocalFirst,
    val localTranscriptionModelId: String = LocalTranscriptionModels.DEFAULT_MODEL_ID,
    val cloudTranscriptionConsent: Boolean = false,
    /** Which cloud speech-to-text backend the user has selected. */
    val cloudTranscriptionProvider: CloudProvider = CloudProvider.OpenAi,
    val openAiApiKey: String = "",
    val sonioxApiKey: String = "",
    /** Opt-in speaker diarization for cloud transcription (provider-dependent). */
    val diarizationEnabled: Boolean = false,
    val aiMode: AiProcessingMode = AiProcessingMode.LocalOnly,
    val remoteAiConsent: Boolean = false,
    /** When enabled, closed segments are decoded into WAV files in the platform export folder. */
    val automaticWavExportEnabled: Boolean = false,
    val diagnosticsIncludeContent: Boolean = false,
    /** True once the user has finished the onboarding wizard (ux plan Section 7). */
    val onboardingComplete: Boolean = false,
)

interface AudioCompanionSettingsRepository {
    val settings: StateFlow<AudioCompanionSettings>

    fun setBackgroundReceiverEnabled(enabled: Boolean)
    fun setRetentionDays(days: Int)
    fun setTranscriptionMode(mode: TranscriptionMode)
    fun setLocalTranscriptionModel(modelId: String)
    fun setCloudTranscriptionConsent(consented: Boolean)
    fun setCloudTranscriptionProvider(provider: CloudProvider)
    fun setOpenAiApiKey(apiKey: String)
    fun setSonioxApiKey(apiKey: String)
    fun setDiarizationEnabled(enabled: Boolean)
    fun setAiMode(mode: AiProcessingMode)
    fun setRemoteAiConsent(consented: Boolean)
    fun setAutomaticWavExportEnabled(enabled: Boolean)
    fun setDiagnosticsIncludeContent(includeContent: Boolean)
    fun setOnboardingComplete(complete: Boolean)
}
