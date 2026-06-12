package dev.audiocompanion.app

import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SegmentWaveformBuilderTest {

    private fun meta(frameCount: Long, gaps: List<GapMeta> = emptyList()) = SegmentMeta(
        segmentId = "seg-1",
        streamId = 7u,
        protocolVersion = 1,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16_000u,
        bitRateBps = 9_800u,
        frameDurationMs = 20,
        startTimeMs = 0u,
        startMonotonicMs = 0u,
        receivedAtMs = 0,
        frameCount = frameCount,
        gaps = gaps,
        closeReason = CloseReasonMeta.Rotated,
    )

    private fun frames(count: Int, firstSequence: UInt = 0u): List<FrameRecord> =
        List(count) { i ->
            FrameRecord(
                sequence = firstSequence + i.toUInt(),
                sampleIndex = (firstSequence + i.toUInt()).toULong() * 320u,
                payload = ByteArray(25),
            )
        }

    /** Deterministic decoder: loud for even frames, silent for odd ones. */
    private val decoder = LiveFrameDecoder { payloads ->
        val out = ShortArray(payloads.size * 320)
        payloads.forEachIndexed { index, _ ->
            if (index % 2 == 0) {
                for (s in 0 until 320) out[index * 320 + s] = 8_000
            }
        }
        out
    }

    @Test
    fun buildsBoundedBarsWithAmplitudeAndDuration() = runTest {
        val builder = SegmentWaveformBuilder(decoder = decoder, maxBars = 10)
        val wave = builder.build(meta(frameCount = 100), frames(100))
        assertEquals(10, wave.bars.size)
        assertEquals(100 * 20L, wave.mediaDurationMs)
        // Every bucket mixes loud and silent frames, so all are Recorded with amplitude > 0.
        assertTrue(wave.bars.all { it.state == WaveformBarState.Recorded && it.amplitude > 0f })
    }

    @Test
    fun silentAudioMarksSilenceBars() = runTest {
        val silent = LiveFrameDecoder { payloads -> ShortArray(payloads.size * 320) }
        val builder = SegmentWaveformBuilder(decoder = silent, maxBars = 4)
        val wave = builder.build(meta(frameCount = 40), frames(40))
        assertTrue(wave.bars.all { it.state == WaveformBarState.Silence })
    }

    @Test
    fun gapMarkersLandAtTheMediaPositionOfTheLoss() = runTest {
        // 50 stored frames, then 100 missing (seq 50..149), then 50 more stored (150..199).
        val stored = frames(50) + frames(50, firstSequence = 150u)
        val gap = GapMeta(
            firstMissingSequence = 50u,
            missingFrameCount = 100u,
            firstMissingSampleIndex = 50uL * 320u,
            origin = GapMeta.ORIGIN_WATCH,
            reasonRaw = 2,
        )
        val builder = SegmentWaveformBuilder(decoder = decoder, maxBars = 10)
        val wave = builder.build(meta(frameCount = 100, gaps = listOf(gap)), stored)
        val marker = wave.gapMarkers.single()
        assertEquals(0.5f, marker.fraction)
        assertEquals(2_000L, marker.approxDurationMs)
    }

    @Test
    fun emptySegmentYieldsNoBars() = runTest {
        val builder = SegmentWaveformBuilder(decoder = decoder)
        val wave = builder.build(meta(frameCount = 0), emptyList())
        assertTrue(wave.bars.isEmpty())
        assertTrue(wave.gapMarkers.isEmpty())
        assertEquals(0L, wave.mediaDurationMs)
    }
}
