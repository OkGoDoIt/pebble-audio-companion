package dev.audiocompanion.app

import android.content.Context
import dev.audiocompanion.ai.AiModels
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.transcription.CloudProvider
import dev.audiocompanion.transcription.TranscriptionMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class AndroidAudioCompanionSettingsRepository(
    context: Context,
) : AudioCompanionSettingsRepository {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
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

    override fun setLocalTranscriptionModel(modelId: String) {
        val selected = LocalTranscriptionModels.byId(modelId)
        update { it.copy(localTranscriptionModelId = selected.id) }
    }

    override fun setCloudTranscriptionProvider(provider: CloudProvider) {
        update { it.copy(cloudTranscriptionProvider = provider) }
    }

    override fun setOpenAiApiKey(apiKey: String) {
        update { it.copy(openAiApiKey = apiKey.trim()) }
    }

    override fun setSonioxApiKey(apiKey: String) {
        update { it.copy(sonioxApiKey = apiKey.trim()) }
    }

    override fun setAiMode(mode: AiProcessingMode) {
        update { it.copy(aiMode = mode) }
    }

    override fun setAiModel(modelId: String) {
        update { it.copy(aiModel = AiModels.byId(modelId).id) }
    }

    override fun setRemoteAiConsent(consented: Boolean) {
        update { it.copy(remoteAiConsent = consented) }
    }

    override fun setAutomaticWavExportEnabled(enabled: Boolean) {
        update { it.copy(automaticWavExportEnabled = enabled) }
    }

    override fun setDiagnosticsIncludeContent(includeContent: Boolean) {
        update { it.copy(diagnosticsIncludeContent = includeContent) }
    }

    override fun setOnboardingComplete(complete: Boolean) {
        update { it.copy(onboardingComplete = complete) }
    }

    private fun update(transform: (AudioCompanionSettings) -> AudioCompanionSettings) {
        val updated = transform(_settings.value)
        persist(updated)
        _settings.value = updated
    }

    private fun load(): AudioCompanionSettings = AudioCompanionSettings(
        backgroundReceiverEnabled = prefs.getBoolean(KEY_BACKGROUND_ENABLED, false),
        retentionDays = prefs.getInt(KEY_RETENTION_DAYS, 30),
        transcriptionMode = enumValueOrDefault(
            prefs.getString(KEY_TRANSCRIPTION_MODE, null),
            TranscriptionMode.LocalFirst,
        ),
        localTranscriptionModelId = LocalTranscriptionModels
            .byId(prefs.getString(KEY_LOCAL_TRANSCRIPTION_MODEL, null).orEmpty())
            .id,
        cloudTranscriptionProvider = enumValueOrDefault(
            prefs.getString(KEY_CLOUD_PROVIDER, null),
            CloudProvider.OpenAi,
        ),
        openAiApiKey = prefs.getString(KEY_OPENAI_API_KEY, null).orEmpty(),
        sonioxApiKey = prefs.getString(KEY_SONIOX_API_KEY, null).orEmpty(),
        aiMode = enumValueOrDefault(prefs.getString(KEY_AI_MODE, null), AiProcessingMode.LocalOnly),
        aiModel = AiModels.byId(prefs.getString(KEY_AI_MODEL, null)).id,
        remoteAiConsent = prefs.getBoolean(KEY_REMOTE_AI_CONSENT, false),
        automaticWavExportEnabled = prefs.getBoolean(KEY_AUTOMATIC_WAV_EXPORT, false),
        diagnosticsIncludeContent = prefs.getBoolean(KEY_DIAGNOSTICS_INCLUDE_CONTENT, false),
        onboardingComplete = prefs.getBoolean(KEY_ONBOARDING_COMPLETE, false),
    )

    private fun persist(settings: AudioCompanionSettings) {
        prefs.edit()
            .putBoolean(KEY_BACKGROUND_ENABLED, settings.backgroundReceiverEnabled)
            .putInt(KEY_RETENTION_DAYS, settings.retentionDays)
            .putString(KEY_TRANSCRIPTION_MODE, settings.transcriptionMode.name)
            .putString(KEY_LOCAL_TRANSCRIPTION_MODEL, settings.localTranscriptionModelId)
            .putString(KEY_CLOUD_PROVIDER, settings.cloudTranscriptionProvider.name)
            .putString(KEY_OPENAI_API_KEY, settings.openAiApiKey)
            .putString(KEY_SONIOX_API_KEY, settings.sonioxApiKey)
            .putString(KEY_AI_MODE, settings.aiMode.name)
            .putString(KEY_AI_MODEL, settings.aiModel)
            .putBoolean(KEY_REMOTE_AI_CONSENT, settings.remoteAiConsent)
            .putBoolean(KEY_AUTOMATIC_WAV_EXPORT, settings.automaticWavExportEnabled)
            .putBoolean(KEY_DIAGNOSTICS_INCLUDE_CONTENT, settings.diagnosticsIncludeContent)
            .putBoolean(KEY_ONBOARDING_COMPLETE, settings.onboardingComplete)
            .apply()
    }

    private inline fun <reified T : Enum<T>> enumValueOrDefault(raw: String?, default: T): T =
        raw?.let { runCatching { enumValueOf<T>(it) }.getOrNull() } ?: default

    companion object {
        private const val PREFS_NAME = "audio_companion_settings"
        private const val KEY_BACKGROUND_ENABLED = "background_enabled"
        private const val KEY_RETENTION_DAYS = "retention_days"
        private const val KEY_TRANSCRIPTION_MODE = "transcription_mode"
        private const val KEY_LOCAL_TRANSCRIPTION_MODEL = "local_transcription_model"
        private const val KEY_CLOUD_PROVIDER = "cloud_transcription_provider"
        private const val KEY_OPENAI_API_KEY = "openai_api_key"
        private const val KEY_SONIOX_API_KEY = "soniox_api_key"
        private const val KEY_AI_MODE = "ai_mode"
        private const val KEY_AI_MODEL = "ai_model"
        private const val KEY_REMOTE_AI_CONSENT = "remote_ai_consent"
        private const val KEY_AUTOMATIC_WAV_EXPORT = "automatic_wav_export"
        private const val KEY_DIAGNOSTICS_INCLUDE_CONTENT = "diagnostics_include_content"
        private const val KEY_ONBOARDING_COMPLETE = "onboarding_complete"
    }
}
