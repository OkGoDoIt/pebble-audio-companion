package dev.audiocompanion.app

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

/** A gap shown as a marker between two media-time positions. */
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
) {
    private var cachedKey: Pair<String, Long>? = null
    private var cachedValue: SegmentWaveform? = null

    suspend fun build(meta: SegmentMeta, frames: List<FrameRecord>): SegmentWaveform {
        val key = meta.segmentId to meta.frameCount
        cachedValue?.let { cached -> if (cachedKey == key) return cached }

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
            cachedKey = key
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
