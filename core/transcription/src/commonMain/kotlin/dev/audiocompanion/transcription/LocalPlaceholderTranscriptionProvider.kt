package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Temporary local provider used until a native speech model is wired in.
 *
 * This is intentionally not a fake queue shortcut: it consumes the same bounded PCM stream that
 * a real local STT provider will receive, so durable storage, Speex decode, retry, provenance, and
 * privacy behavior are exercised end-to-end. Replace this with the Cactus/whisper-family provider
 * without changing [TranscriptionProcessor].
 */
class LocalPlaceholderTranscriptionProvider : TranscriptionProvider {
    override val id: String = "local-placeholder"
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)

    override suspend fun isAvailable(): Boolean = true

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult {
        var bytes = 0L
        var nonZero = false
        pcmChunks.collect { chunk ->
            bytes += chunk.size
            if (!nonZero) {
                nonZero = chunk.any { it != 0.toByte() }
            }
        }
        if (bytes == 0L || !nonZero) {
            throw TranscriptionException.NoSpeechDetected("no non-silent PCM in segment")
        }
        val tenths = bytes * 10 / (sampleRateHz * Short.SIZE_BYTES)
        return TranscriptionResult(
            text = "Local transcription placeholder captured ${tenths / 10}.${tenths % 10} " +
                "seconds of watch audio.",
            providerId = id,
            modelUsed = "placeholder-v1",
        )
    }
}
