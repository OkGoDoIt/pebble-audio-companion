package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * Routing modes, mirroring the four upstream modes of
 * mobileapp's CactusTranscriptionService (Rebble modes excluded — they are routed
 * before reaching that service and have no equivalent here).
 */
enum class TranscriptionMode {
    LocalOnly,
    RemoteOnly,
    LocalFirst,
    RemoteFirst,
}

enum class ProviderStatus {
    /** Not usable yet (e.g. model not downloaded, no credentials). */
    NotReady,
    Initializing,
    Ready,
    Error,
}

data class TranscriptionResult(
    val text: String,
    val providerId: String,
    /** Model/version identifier for provenance records. */
    val modelUsed: String?,
)

sealed class TranscriptionException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {

    /** Valid terminal outcome, not a provider failure: routers must NOT fall back on it. */
    class NoSpeechDetected(reason: String) : TranscriptionException(reason)

    class ProviderUnavailable(providerId: String) :
        TranscriptionException("provider unavailable: $providerId")

    class TranscriptionFailed(message: String, cause: Throwable? = null) :
        TranscriptionException(message, cause)
}

/**
 * One speech-to-text backend (local whisper-family or cloud). Real providers come later
 * (plan 6.5); this module currently ships interfaces, the mode router, and the durable queue.
 */
interface TranscriptionProvider {
    val id: String

    val status: StateFlow<ProviderStatus>

    suspend fun isAvailable(): Boolean

    /**
     * Transcribes 16 kHz mono PCM16 audio supplied in bounded chunks (never whole-segment
     * buffers). Throws [TranscriptionException.NoSpeechDetected] when the audio contains no
     * usable speech and other [TranscriptionException]s on failure.
     */
    suspend fun transcribe(pcmChunks: Flow<ByteArray>, sampleRateHz: Int): TranscriptionResult
}
