package dev.audiocompanion.transcription

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class OpenAiRealtimeAccumulatorTest {

    @Test
    fun deltasFormPartialAndCompletedFinalizes() {
        val acc = OpenAiRealtimeAccumulator()

        assertEquals("Hello", acc.delta("Hello").partialText)
        val withMore = acc.delta(", wor")
        assertEquals("Hello, wor", withMore.partialText)
        assertEquals("", withMore.finalText)

        val done = acc.completed("Hello, world")
        assertEquals("Hello, world", done.finalText)
        assertEquals("", done.partialText)

        // A second item appends to the stable transcript.
        val next = acc.completed("Goodbye")
        assertEquals("Hello, world Goodbye", next.finalText)
    }
}

class PcmResamplerTest {

    private fun samples(vararg values: Int): ByteArray {
        val out = ByteArray(values.size * 2)
        values.forEachIndexed { i, v ->
            out[i * 2] = (v and 0xFF).toByte()
            out[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }

    private fun readSamples(pcm: ByteArray): List<Int> = (0 until pcm.size / 2).map { i ->
        val lo = pcm[i * 2].toInt() and 0xFF
        val hi = pcm[i * 2 + 1].toInt()
        (hi shl 8) or lo
    }

    @Test
    fun upsamples16kTo24kByRatio() {
        // 4 input samples at 16k -> 6 output samples at 24k (ratio 3/2).
        val input = samples(0, 600, 1200, 1800)
        val out = PcmResampler.resampleLinearMono16(input, 16_000, 24_000)
        assertEquals(6, out.size / 2)
        val s = readSamples(out)
        // Endpoints preserved; values monotonically increase across the interpolation.
        assertEquals(0, s.first())
        assertTrue(s.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test
    fun sameRateIsIdentity() {
        val input = samples(1, 2, 3)
        assertTrue(PcmResampler.resampleLinearMono16(input, 16_000, 16_000).contentEquals(input))
    }
}
