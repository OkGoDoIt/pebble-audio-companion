package dev.audiocompanion.transcription

import kotlin.math.roundToInt

/**
 * Linear-interpolation resampler for 16-bit signed little-endian mono PCM. Used to feed providers
 * that require a fixed input rate (e.g. OpenAI realtime wants 24 kHz) from the watch's 16 kHz audio.
 * Linear interpolation is adequate for speech transcription and cheap enough for the live path.
 */
object PcmResampler {
    fun resampleLinearMono16(pcm: ByteArray, fromRate: Int, toRate: Int): ByteArray {
        if (fromRate == toRate || fromRate <= 0 || toRate <= 0) return pcm
        val inSamples = pcm.size / 2
        if (inSamples == 0) return ByteArray(0)
        val outSamples = (inSamples.toLong() * toRate / fromRate).toInt().coerceAtLeast(1)
        val out = ByteArray(outSamples * 2)
        for (i in 0 until outSamples) {
            val srcPos = i.toDouble() * fromRate / toRate
            val idx = srcPos.toInt()
            val frac = srcPos - idx
            val s0 = sampleAt(pcm, idx, inSamples)
            val s1 = sampleAt(pcm, idx + 1, inSamples)
            val value = (s0 + (s1 - s0) * frac).roundToInt().coerceIn(-32768, 32767)
            out[i * 2] = (value and 0xFF).toByte()
            out[i * 2 + 1] = ((value shr 8) and 0xFF).toByte()
        }
        return out
    }

    private fun sampleAt(pcm: ByteArray, index: Int, count: Int): Int {
        val i = index.coerceIn(0, count - 1)
        val lo = pcm[i * 2].toInt() and 0xFF
        val hi = pcm[i * 2 + 1].toInt()
        return (hi shl 8) or lo
    }
}
