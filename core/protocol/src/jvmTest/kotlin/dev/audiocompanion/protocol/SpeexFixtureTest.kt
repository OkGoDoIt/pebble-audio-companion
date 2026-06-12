package dev.audiocompanion.protocol

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Structural checks for the real-firmware Speex codec fixture (spec/fixtures/speex_frames_v1*).
 * Full decode happens on device targets where the native Speex library exists; this JVM test
 * locks the record framing, frame geometry, and byte content hash so silent fixture drift is
 * caught in CI everywhere.
 */
class SpeexFixtureTest {

    private val fixturesDir: File = run {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "spec/fixtures")
            if (candidate.isDirectory) return@run candidate
            dir = dir.parentFile
        }
        fail("Could not locate spec/fixtures above ${System.getProperty("user.dir")}")
    }

    @Test
    fun frameLogHasFiftyConstantSizeRecords() {
        val bytes = File(fixturesDir, "speex_frames_v1.bin").readBytes()
        assertEquals(1350, bytes.size)

        var offset = 0
        var frames = 0
        while (offset < bytes.size) {
            val len = (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
            assertEquals(25, len, "frame $frames length")
            offset += 2 + len
            frames += 1
        }
        assertEquals(50, frames)
        assertEquals(bytes.size, offset)
    }

    @Test
    fun fixtureBytesMatchFirmwareGoldenHash() {
        val bytes = File(fixturesDir, "speex_frames_v1.bin").readBytes()
        // Same FNV-1a as PebbleOS test_audio_companion_speex.c GOLDEN_STREAM_FNV1A.
        var hash = 0x811C9DC5.toInt()
        for (b in bytes) {
            hash = (hash xor (b.toInt() and 0xFF)) * 16777619
        }
        assertEquals(0x490aea30, hash)
    }

    @Test
    fun inputPcmIsOneSecondMono16k() {
        val pcm = File(fixturesDir, "speex_frames_v1_input.pcm").readBytes()
        assertEquals(16_000 * 2, pcm.size) // 1 s of s16le @ 16 kHz
        // Not silence: at least some samples have meaningful amplitude.
        var loud = 0
        var i = 0
        while (i < pcm.size) {
            val sample = ((pcm[i].toInt() and 0xFF) or (pcm[i + 1].toInt() shl 8)).toShort().toInt()
            if (sample > 2000 || sample < -2000) loud += 1
            i += 2
        }
        assertTrue(loud > 1000, "input PCM looks silent: $loud loud samples")
    }
}
