package dev.audiocompanion.app

import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import kotlin.math.min
import kotlin.math.sqrt

/** One bucket of a stored segment's waveform, in media time (stored frames only). */
data class SegmentWaveformBar(
    /** 0..1 display amplitude (sqrt-compressed RMS). */
    val amplitude: Float,
    val state: WaveformBarState,
)

/** A marker at the media-time position where genuine audio loss occurred. */
data class SegmentGapMarker(
    /** 0..1 position within the stored audio where the missing audio would have been. */
    val fraction: Float,
    val approxDurationMs: Long,
)

data class SegmentWaveform(
    val bars: List<SegmentWaveformBar>,
    val gapMarkers: List<SegmentGapMarker>,
    /** Duration of the stored audio (gaps excluded) — matches playback positions. */
    val mediaDurationMs: Long,
)

/**
 * Builds the color-codable waveform of one stored segment from its durable frame log.
 *
 * The bar axis is media time (stored frames only), so the playback cursor and tap-to-seek map
 * linearly onto it; missing audio is shown as gap markers at the position where it occurred
 * (the ux plan's "scrubber with gap markers"), not as fake silent time.
 */
class SegmentWaveformBuilder(
    private val decoder: LiveFrameDecoder?,
    private val frameDurationMs: Long = 20,
    private val maxBars: Int = 240,
    private val decodeBatchFrames: Int = 200,
    /**
     * While a segment is still recording its meta refreshes every few seconds; only re-read and
     * re-decode once this much new audio exists (500 frames = 10 s), not on every refresh.
     */
    private val minRebuildDeltaFrames: Long = 500,
) {
    private var cachedSegmentId: String? = null
    private var cachedFrameCount: Long = -1
    private var cachedValue: SegmentWaveform? = null

    suspend fun build(
        meta: SegmentMeta,
        framesProvider: () -> List<FrameRecord>,
    ): SegmentWaveform {
        cachedValue?.let { cached ->
            if (cachedSegmentId == meta.segmentId) {
                val delta = meta.frameCount - cachedFrameCount
                val fresh = delta == 0L ||
                    (meta.isOpen && delta in 0 until minRebuildDeltaFrames)
                if (fresh) return cached
            }
        }
        val frames = framesProvider()

        val mediaDurationMs = frames.size * frameDurationMs
        val framesPerBar = ((frames.size + maxBars - 1) / maxBars).coerceAtLeast(1)
        val barCount = if (frames.isEmpty()) 0 else (frames.size + framesPerBar - 1) / framesPerBar

        val sumSquares = DoubleArray(barCount)
        val sampleCounts = IntArray(barCount)

        var index = 0
        while (index < frames.size) {
            val end = min(index + decodeBatchFrames, frames.size)
            val batch = frames.subList(index, end)
            val pcm = decoder?.decode(batch.map { it.payload }) ?: ShortArray(0)
            if (pcm.isEmpty()) {
                // No decoder (tests): count frame presence so bars still render.
                for (i in index until end) {
                    val bar = i / framesPerBar
                    sampleCounts[bar] += 1
                }
            } else {
                val samplesPerFrame = pcm.size / batch.size
                for (i in batch.indices) {
                    val bar = (index + i) / framesPerBar
                    val from = i * samplesPerFrame
                    val to = min(from + samplesPerFrame, pcm.size)
                    for (s in from until to) {
                        val sample = pcm[s].toDouble()
                        sumSquares[bar] += sample * sample
                    }
                    sampleCounts[bar] += (to - from)
                }
            }
            index = end
        }

        val bars = List(barCount) { bar ->
            val rms = if (sampleCounts[bar] > 0) sqrt(sumSquares[bar] / sampleCounts[bar]) else 0.0
            SegmentWaveformBar(
                amplitude = sqrt((rms / Short.MAX_VALUE).coerceIn(0.0, 1.0)).toFloat(),
                state = if (rms < LiveAudioMonitor.SILENCE_RMS) {
                    WaveformBarState.Silence
                } else {
                    WaveformBarState.Recorded
                },
            )
        }

        val markers = meta.gaps.mapNotNull { gap -> gapMarker(gap, meta, frames) }
        return SegmentWaveform(bars, markers, mediaDurationMs).also {
            cachedSegmentId = meta.segmentId
            cachedFrameCount = maxOf(meta.frameCount, frames.size.toLong())
            cachedValue = it
        }
    }

    /** Media-time position of a gap: the share of stored frames before its first missing seq. */
    private fun gapMarker(
        gap: GapMeta,
        meta: SegmentMeta,
        frames: List<FrameRecord>,
    ): SegmentGapMarker? {
        if (frames.isEmpty()) return null
        // Silence-suppressed spans are known-quiet audio the watch skipped, not loss: the stored
        // audio simply continues across them, so they get no marker. Drawing one would imply
        // something went wrong where the watch was only saving power during quiet.
        if (GapReason.fromRaw(gap.reasonRaw ?: -1)?.isSilence == true) return null
        var low = 0
        var high = frames.size
        while (low < high) {
            val mid = (low + high) / 2
            if (frames[mid].sequence < gap.firstMissingSequence) low = mid + 1 else high = mid
        }
        return SegmentGapMarker(
            fraction = low.toFloat() / frames.size,
            approxDurationMs = gap.missingFrameCount.toLong() * meta.frameDurationMs,
        )
    }
}
