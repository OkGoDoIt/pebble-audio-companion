package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow

/**
 * Real-time streaming provider that delegates to the user-selected cloud backend, so the live
 * transcriber stays provider-agnostic (mirrors [SelectableCloudTranscriptionProvider] for the batch
 * path). The active backend is resolved per call from [selected].
 */
class SelectableStreamingTranscriptionProvider(
    private val selected: () -> CloudProvider,
    private val openAi: StreamingTranscriptionProvider,
    private val soniox: StreamingTranscriptionProvider,
) : StreamingTranscriptionProvider {
    override val id: String get() = active().id

    override suspend fun isAvailable(): Boolean = active().isAvailable()

    override fun transcribeStream(
        pcm: Flow<ByteArray>,
        sampleRateHz: Int,
    ): Flow<StreamingTranscriptUpdate> = active().transcribeStream(pcm, sampleRateHz)

    private fun active(): StreamingTranscriptionProvider = when (selected()) {
        CloudProvider.OpenAi -> openAi
        CloudProvider.Soniox -> soniox
    }
}
