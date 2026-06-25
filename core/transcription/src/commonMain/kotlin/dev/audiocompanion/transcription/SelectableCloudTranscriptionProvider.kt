package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The cloud speech-to-text backends the user can choose between. */
enum class CloudProvider {
    OpenAi,
    Soniox,
}

/**
 * A [TranscriptionProvider] that delegates to whichever cloud backend the user has selected, so the
 * rest of the pipeline (router, processor, live transcriber) stays provider-agnostic. The active
 * provider is resolved per call from [selected], so changing the setting takes effect immediately
 * without rebuilding the runtime.
 */
class SelectableCloudTranscriptionProvider(
    private val selected: () -> CloudProvider,
    private val openAi: TranscriptionProvider,
    private val soniox: TranscriptionProvider,
) : TranscriptionProvider {
    override val id: String get() = active().id
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)

    override suspend fun isAvailable(): Boolean = active().isAvailable()

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult = active().transcribe(pcmChunks, sampleRateHz)

    private fun active(): TranscriptionProvider = when (selected()) {
        CloudProvider.OpenAi -> openAi
        CloudProvider.Soniox -> soniox
    }
}
