package dev.audiocompanion.app

import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.transcription.TranscriptionMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import platform.Foundation.NSUserDefaults

class IosAudioCompanionSettingsRepository(
    private val defaults: NSUserDefaults = NSUserDefaults.standardUserDefaults,
) : AudioCompanionSettingsRepository {
    private val _settings = MutableStateFlow(load())
    override val settings: StateFlow<AudioCompanionSettings> = _settings.asStateFlow()

    override fun setBackgroundReceiverEnabled(enabled: Boolean) {
        update { it.copy(backgroundReceiverEnabled = enabled) }
    }

    override fun setRetentionDays(days: Int) {
        update { it.copy(retentionDays = days.coerceIn(1, 365)) }
    }

    override fun setTranscriptionMode(mode: TranscriptionMode) {
        update { it.copy(transcriptionMode = mode) }
    }

    override fun setCloudTranscriptionConsent(consented: Boolean) {
        update { it.copy(cloudTranscriptionConsent = consented) }
    }

    override fun setOpenAiApiKey(apiKey: String) {
        update { it.copy(openAiApiKey = apiKey.trim()) }
    }

    override fun setAiMode(mode: AiProcessingMode) {
        update { it.copy(aiMode = mode) }
    }

    override fun setRemoteAiConsent(consented: Boolean) {
        update { it.copy(remoteAiConsent = consented) }
    }

    override fun setDiagnosticsIncludeContent(includeContent: Boolean) {
        update { it.copy(diagnosticsIncludeContent = includeContent) }
    }

    private fun update(transform: (AudioCompanionSettings) -> AudioCompanionSettings) {
        val updated = transform(_settings.value)
        persist(updated)
        _settings.value = updated
    }

    private fun load(): AudioCompanionSettings = AudioCompanionSettings(
        backgroundReceiverEnabled = defaults.boolForKey(KEY_BACKGROUND_ENABLED),
        retentionDays = defaults.integerForKey(KEY_RETENTION_DAYS).takeIf { it > 0 }?.toInt() ?: 30,
        transcriptionMode = enumValueOrDefault(
            defaults.stringForKey(KEY_TRANSCRIPTION_MODE),
            TranscriptionMode.LocalFirst,
        ),
        cloudTranscriptionConsent = defaults.boolForKey(KEY_CLOUD_TRANSCRIPTION_CONSENT),
        openAiApiKey = defaults.stringForKey(KEY_OPENAI_API_KEY).orEmpty(),
        aiMode = enumValueOrDefault(defaults.stringForKey(KEY_AI_MODE), AiProcessingMode.LocalOnly),
        remoteAiConsent = defaults.boolForKey(KEY_REMOTE_AI_CONSENT),
        diagnosticsIncludeContent = defaults.boolForKey(KEY_DIAGNOSTICS_INCLUDE_CONTENT),
    )

    private fun persist(settings: AudioCompanionSettings) {
        defaults.setBool(settings.backgroundReceiverEnabled, forKey = KEY_BACKGROUND_ENABLED)
        defaults.setInteger(settings.retentionDays.toLong(), forKey = KEY_RETENTION_DAYS)
        defaults.setObject(settings.transcriptionMode.name, forKey = KEY_TRANSCRIPTION_MODE)
        defaults.setBool(settings.cloudTranscriptionConsent, forKey = KEY_CLOUD_TRANSCRIPTION_CONSENT)
        defaults.setObject(settings.openAiApiKey, forKey = KEY_OPENAI_API_KEY)
        defaults.setObject(settings.aiMode.name, forKey = KEY_AI_MODE)
        defaults.setBool(settings.remoteAiConsent, forKey = KEY_REMOTE_AI_CONSENT)
        defaults.setBool(settings.diagnosticsIncludeContent, forKey = KEY_DIAGNOSTICS_INCLUDE_CONTENT)
    }

    private inline fun <reified T : Enum<T>> enumValueOrDefault(raw: String?, default: T): T =
        raw?.let { runCatching { enumValueOf<T>(it) }.getOrNull() } ?: default

    companion object {
        private const val KEY_BACKGROUND_ENABLED = "background_enabled"
        private const val KEY_RETENTION_DAYS = "retention_days"
        private const val KEY_TRANSCRIPTION_MODE = "transcription_mode"
        private const val KEY_CLOUD_TRANSCRIPTION_CONSENT = "cloud_transcription_consent"
        private const val KEY_OPENAI_API_KEY = "openai_api_key"
        private const val KEY_AI_MODE = "ai_mode"
        private const val KEY_REMOTE_AI_CONSENT = "remote_ai_consent"
        private const val KEY_DIAGNOSTICS_INCLUDE_CONTENT = "diagnostics_include_content"
    }
}
