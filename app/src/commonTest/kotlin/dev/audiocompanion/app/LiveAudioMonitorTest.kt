package dev.audiocompanion.app

import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.test.runTest
import kotlin.math.PI
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Fake decoder: byte value of the frame's first byte selects loud sine vs silence. */
private val fakeDecoder = LiveFrameDecoder { frames ->
    val out = ShortArray(frames.size * 320)
    frames.forEachIndexed { frameIndex, payload ->
        val loud = payload.isNotEmpty() && payload[0].toInt() != 0
        for (i in 0 until 320) {
            out[frameIndex * 320 + i] =
                if (loud) (sin(2 * PI * i / 32.0) * 8000).toInt().toShort() else 0
        }
    }
    out
}

private val lowSpeechDecoder = LiveFrameDecoder { frames ->
    val out = ShortArray(frames.size * 320)
    frames.forEachIndexed { frameIndex, _ ->
        for (i in 0 until 320) {
            out[frameIndex * 320 + i] = 120
        }
    }
    out
}

private fun frames(count: Int, loud: Boolean): List<SegmentFrame> = List(count) { index ->
    SegmentFrame(
        sequence = index.toUInt(),
        sampleIndex = (index * 320).toULong(),
        payload = ByteArray(25) { if (loud) 1 else 0 },
    )
}

class LiveAudioMonitorTest {

    @Test
    fun loudFramesBecomeRecordedBars() = runTest {
        val monitor = LiveAudioMonitor(decoder = fakeDecoder, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(25, loud = true), receivedAtMs = 100_000)

        monitor.processPending()

        val bars = monitor.bars.value
        assertTrue(bars.isNotEmpty(), "expected bars from 25 frames (500 ms)")
        assertTrue(bars.all { it.state == WaveformBarState.Recorded })
        assertTrue(bars.all { it.amplitude > 0.1f })
        assertEquals("seg-1", bars.first().segmentId)
    }

    @Test
    fun quietFramesBecomeSilenceBars() = runTest {
        val monitor = LiveAudioMonitor(decoder = fakeDecoder, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(25, loud = false), receivedAtMs = 100_000)

        monitor.processPending()

        assertTrue(monitor.bars.value.all { it.state == WaveformBarState.Silence })
    }

    @Test
    fun lowLevelSpeechStillLooksRecordedAndVisible() = runTest {
        val monitor = LiveAudioMonitor(decoder = lowSpeechDecoder, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(25, loud = true), receivedAtMs = 100_000)

        monitor.processPending()

        val bars = monitor.bars.value
        assertTrue(bars.isNotEmpty())
        assertTrue(bars.all { it.state == WaveformBarState.Recorded })
        assertTrue(bars.all { it.amplitude in 0.08f..0.2f })
        assertTrue(LiveAudioMonitor.displayAmplitude(120.0) < LiveAudioMonitor.displayAmplitude(1_000.0))
        assertTrue(LiveAudioMonitor.displayAmplitude(1_000.0) < LiveAudioMonitor.displayAmplitude(8_000.0))
    }

    @Test
    fun gapsMarkBarsAcrossTheirDuration() = runTest {
        val monitor = LiveAudioMonitor(decoder = fakeDecoder, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 100_000)
        // Gaps are reported at their trailing edge, so the span fills backward from there.
        monitor.onGap(receivedAtMs = 102_000, approxDurationMs = 1_000)

        monitor.processPending()

        val gapBars = monitor.bars.value.filter { it.state == WaveformBarState.Gap }
        assertEquals(4, gapBars.size) // 1000 ms / 250 ms per bar
        assertTrue(gapBars.all { it.timeMs in 101_000 until 102_000 })
    }

    @Test
    fun suppressedSilenceRendersAsQuietNotGap() = runTest {
        val monitor = LiveAudioMonitor(decoder = fakeDecoder, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 100_000)
        // Voice-activity silence the watch skipped, reported at the resume edge: it must fill the
        // span that just ended (backward) as a quiet tick — never an amber gap or empty space.
        monitor.onGap(receivedAtMs = 102_000, approxDurationMs = 1_000, silence = true)

        monitor.processPending()

        val bars = monitor.bars.value
        assertTrue(bars.none { it.state == WaveformBarState.Gap }, "silence must not show amber gap bars")
        val quietBars = bars.filter { it.timeMs in 101_000 until 102_000 }
        assertEquals(4, quietBars.size) // 1000 ms / 250 ms per bar
        assertTrue(quietBars.all { it.state == WaveformBarState.SuppressedSilence })
    }

    @Test
    fun barsOutsideTheWindowAreTrimmed() = runTest {
        val monitor = LiveAudioMonitor(decoder = fakeDecoder, nowMs = { 0 })
        monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 10_000)
        monitor.processPending()
        assertTrue(monitor.bars.value.isNotEmpty())

        // 10 minutes later more audio arrives; the old bars fall out of the 60 s window.
        monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 610_000)
        monitor.processPending()

        assertTrue(monitor.bars.value.all { it.timeMs >= 610_000 - monitor.windowMs })
    }

    @Test
    fun framesAccumulateWhileInactiveAndDecodeInOneBatch() = runTest {
        var decodeCalls = 0
        val countingDecoder = LiveFrameDecoder { frames ->
            decodeCalls += 1
            fakeDecoder.decode(frames)
        }
        val monitor = LiveAudioMonitor(decoder = countingDecoder, nowMs = { 100_000 })

        // 4 batches arrive while the UI is hidden: no decode happens.
        repeat(4) { batch ->
            monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 100_000L + batch * 260)
        }
        assertEquals(0, decodeCalls)

        // One catch-up decode covers the whole backlog.
        monitor.processPending()
        assertEquals(1, decodeCalls)
        assertTrue(monitor.bars.value.isNotEmpty())
    }

    @Test
    fun missingDecoderStillRendersPresence() = runTest {
        val monitor = LiveAudioMonitor(decoder = null, nowMs = { 100_000 })
        monitor.onFrames("seg-1", frames(13, loud = true), receivedAtMs = 100_000)

        monitor.processPending()

        // Amplitude is zero (no decode) so bars read as silence, but presence is visible.
        assertTrue(monitor.bars.value.isNotEmpty())
    }
}
