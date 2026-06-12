package dev.audiocompanion.app

import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.transcription.TranscriptionMode
import kotlinx.coroutines.flow.StateFlow

data class AudioCompanionSettings(
    val backgroundReceiverEnabled: Boolean = false,
    val retentionDays: Int = 30,
    val retentionMaxBytes: Long = 2L * 1024 * 1024 * 1024,
    val transcriptionMode: TranscriptionMode = TranscriptionMode.LocalFirst,
    val cloudTranscriptionConsent: Boolean = false,
    val openAiApiKey: String = "",
    val aiMode: AiProcessingMode = AiProcessingMode.LocalOnly,
    val remoteAiConsent: Boolean = false,
    val diagnosticsIncludeContent: Boolean = false,
)

interface AudioCompanionSettingsRepository {
    val settings: StateFlow<AudioCompanionSettings>

    fun setBackgroundReceiverEnabled(enabled: Boolean)
    fun setRetentionDays(days: Int)
    fun setTranscriptionMode(mode: TranscriptionMode)
    fun setCloudTranscriptionConsent(consented: Boolean)
    fun setOpenAiApiKey(apiKey: String)
    fun setAiMode(mode: AiProcessingMode)
    fun setRemoteAiConsent(consented: Boolean)
    fun setDiagnosticsIncludeContent(includeContent: Boolean)
}
