package dev.audiocompanion.transcription

/**
 * Lets the app release the heavy resident local-transcription model on demand.
 *
 * A local whisper-family model can hold tens to hundreds of MB resident. On iOS that resident
 * footprint makes the app a jetsam target, especially during the short Core Bluetooth background
 * wakes that are only meant for receiving audio. So instead of keeping the model loaded
 * indefinitely, callers load it for a bounded transcription window and release it on:
 *
 *  - backgrounding (no local transcription runs while backgrounded),
 *  - memory pressure (a system memory warning),
 *  - idle timeout (no transcription for a while),
 *  - selected-model change (the old model is no longer wanted).
 *
 * The tradeoff is cold-start latency before the next local transcription, which is far cheaper
 * than being killed. Releasing is always safe: the next [TranscriptionProvider.transcribe] reloads.
 */
interface LocalTranscriptionLifecycle {
    /** Immediately releases the loaded model, if any. No-op (and silent) when nothing is loaded. */
    suspend fun releaseModel(reason: String)

    /**
     * Releases the model only when it has been loaded but unused for at least [idleTimeoutMs],
     * measured against [nowMs]. A no-op while a transcription is recent or nothing is loaded.
     */
    suspend fun releaseModelIfIdle(nowMs: Long, idleTimeoutMs: Long)
}
