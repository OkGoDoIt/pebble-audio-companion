package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow

/**
 * One incremental update from a real-time (streaming) transcription session.
 *
 * [finalText] is the stable, recognized-so-far transcript; [partialText] is the volatile current
 * tail that may still change. [segments] carry finalized spans with speaker labels (diarization).
 */
data class StreamingTranscriptUpdate(
    val finalText: String,
    val partialText: String = "",
    val segments: List<TranscriptSegment> = emptyList(),
    val isFinal: Boolean = false,
) {
    /** Best-effort display text: stable transcript plus the volatile tail. */
    val displayText: String get() = listOf(finalText, partialText).filter { it.isNotBlank() }.joinToString(" ")
}

/**
 * A real-time transcription backend: audio is streamed in continuously and partial/final transcript
 * updates stream back. Distinct from the batch [TranscriptionProvider] (whole closed segments) and
 * only usable while the app is in the foreground (a live socket cannot survive iOS suspension).
 */
interface StreamingTranscriptionProvider {
    val id: String

    suspend fun isAvailable(): Boolean

    /**
     * Streams updates while [pcm] (16-bit signed little-endian mono PCM at [sampleRateHz]) flows.
     * The returned flow completes when the session ends and throws [TranscriptionException] on
     * failure. Collect it on the foreground; cancel the collection to stop streaming.
     */
    fun transcribeStream(pcm: Flow<ByteArray>, sampleRateHz: Int): Flow<StreamingTranscriptUpdate>
}
