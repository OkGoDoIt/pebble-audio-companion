package dev.audiocompanion.app

import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.TranscriptionException
import dev.audiocompanion.transcription.TranscriptionModeRouter
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.min

/** Rolling transcript preview of a still-recording segment. */
data class LiveTranscriptPreview(
    val segmentId: String,
    val text: String,
    /** Frame-log records consumed so far (index into readFrames, not a sequence number). */
    val transcribedFrameCount: Int,
    val updatedAtMs: Long,
)

/**
 * Incremental transcription of the currently open (still recording) segment.
 *
 * The durable transcription queue only processes closed segments; this class fills the gap the
 * user sees while a recording is ongoing: every time the open segment has accumulated at least
 * [minChunkFrames] new stored frames, the new tail is decoded and transcribed as one chunk and
 * appended to an in-memory rolling preview. The preview is intentionally not durable — when the
 * segment closes, the normal queue produces the authoritative full-segment transcript and the
 * preview is dropped ([prune]).
 *
 * Chunk boundaries can split words, so the preview may differ slightly from the final
 * transcript; that is an accepted preview tradeoff. Runs on the runtime's single transcription
 * loop, so it never races the closed-segment work for a (possibly single-instance) native model.
 *
 * Cost note: callers should pass a router restricted to the LOCAL provider. Routing the preview
 * through a cloud provider would mean one network call per chunk (~110 per 15-minute segment)
 * instead of one per closed segment — surprise cost and audio leaving the device far more often
 * than the user consented to for normal transcription cadence.
 */
class LiveTranscriber(
    private val openSegmentId: () -> String?,
    private val readMeta: (segmentId: String) -> SegmentMeta?,
    private val readFrames: (segmentId: String) -> List<FrameRecord>,
    private val router: TranscriptionModeRouter,
    private val nowMs: () -> Long,
    private val decodePcm: suspend (SegmentMeta, List<FrameRecord>) -> Flow<ByteArray> =
        { meta, frames ->
            SpeexFrameDecoder(
                sampleRateHz = meta.sampleRateHz.toInt(),
                bitRateBps = meta.bitRateBps.toInt(),
                frameSamples = meta.frameSamples,
            ).decode(flow { frames.forEach { emit(it.payload) } })
        },
    /** ~8 s of audio at 20 ms frames: short enough to feel live, long enough for context. */
    private val minChunkFrames: Int = 400,
    /** Bounds one pass (catch-up after app restart processes the backlog chunk by chunk). */
    private val maxChunkFrames: Int = 3_000,
    private val failureBackoffMs: Long = 30_000,
    /** Open segment + a couple of just-closed segments awaiting their final transcript. */
    private val maxEntries: Int = 3,
) {
    private val _previews = MutableStateFlow<Map<String, LiveTranscriptPreview>>(emptyMap())
    val previews: StateFlow<Map<String, LiveTranscriptPreview>> = _previews.asStateFlow()

    private var lastFailureAtMs: Long = 0

    fun textFor(segmentId: String): String? =
        _previews.value[segmentId]?.text?.takeIf { it.isNotBlank() }

    /** True when the open segment has enough new audio for another pass (drives loop cadence). */
    fun hasPendingWork(): Boolean {
        val segmentId = openSegmentId() ?: return false
        val meta = readMeta(segmentId) ?: return false
        val done = _previews.value[segmentId]?.transcribedFrameCount ?: 0
        return meta.frameCount - done >= minChunkFrames
    }

    /**
     * Transcribes at most one new chunk of the open segment. Returns true when the preview
     * advanced (more chunks may be pending). Provider failures back off instead of looping hot.
     */
    suspend fun processOnce(): Boolean {
        val segmentId = openSegmentId() ?: return false
        val meta = readMeta(segmentId) ?: return false
        if (nowMs() - lastFailureAtMs < failureBackoffMs && lastFailureAtMs != 0L) return false

        val existing = _previews.value[segmentId]
        val done = existing?.transcribedFrameCount ?: 0
        if (meta.frameCount - done < minChunkFrames) return false
        if (!router.isAvailable()) return false

        val frames = readFrames(segmentId)
        if (frames.size - done < minChunkFrames) return false
        val chunk = frames.subList(done, min(frames.size, done + maxChunkFrames))

        val chunkText = try {
            router.transcribe(decodePcm(meta, chunk), meta.sampleRateHz.toInt()).text.trim()
        } catch (e: CancellationException) {
            throw e
        } catch (_: TranscriptionException.NoSpeechDetected) {
            "" // Quiet audio is a valid outcome: advance past it without text.
        } catch (_: Exception) {
            lastFailureAtMs = nowMs()
            return false
        }
        lastFailureAtMs = 0

        val combined = listOfNotNull(existing?.text, chunkText.takeIf { it.isNotBlank() })
            .joinToString(" ")
            .trim()
        update(
            LiveTranscriptPreview(
                segmentId = segmentId,
                text = combined,
                transcribedFrameCount = done + chunk.size,
                updatedAtMs = nowMs(),
            ),
        )
        return true
    }

    /**
     * Drops previews that are no longer needed: the segment now has a durable transcript, or it
     * no longer exists. Call alongside transcription-loop passes.
     */
    fun prune(hasFinalTranscript: (segmentId: String) -> Boolean) {
        val current = _previews.value
        val kept = current.filter { (segmentId, _) ->
            readMeta(segmentId) != null && !hasFinalTranscript(segmentId)
        }
        if (kept.size != current.size) _previews.value = kept
    }

    private fun update(preview: LiveTranscriptPreview) {
        val next = (_previews.value + (preview.segmentId to preview)).toMutableMap()
        while (next.size > maxEntries) {
            val oldest = next.values.minByOrNull { it.updatedAtMs } ?: break
            next.remove(oldest.segmentId)
        }
        _previews.value = next
    }
}
