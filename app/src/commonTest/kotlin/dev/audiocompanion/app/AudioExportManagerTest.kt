package dev.audiocompanion.app

import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.SegmentMeta
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlinx.io.readByteArray
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AudioExportManagerTest {
    private fun meta(segmentId: String = "seg-1", closed: Boolean = true) = SegmentMeta(
        segmentId = segmentId,
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
        receivedAtMs = 1234,
        frameCount = 2,
        closeReason = if (closed) CloseReasonMeta.Rotated else null,
    )

    private fun frames() = listOf(
        FrameRecord(0u, 0u, byteArrayOf(1)),
        FrameRecord(1u, 320u, byteArrayOf(2)),
    )

    @Test
    fun exportSegmentWritesStandardWavFile() = runTest {
        val segment = meta()
        val frameRecords = frames()
        val root = Path(SystemTemporaryDirectory, "audio-export-${Random.nextLong()}")
        val manager = AudioExportManager(
            fileSystem = SystemFileSystem,
            exportRoot = root,
            listSegments = { listOf(segment) },
            readMeta = { segment },
            readFrames = { frameRecords },
            decodePcm = { meta, records ->
                flowOf(ByteArray(meta.frameSamples * Short.SIZE_BYTES * records.size) { 7 })
            },
        )

        val result = manager.exportSegment(segment.segmentId)

        assertEquals(1, result.fileCount)
        val exported = result.files.single()
        assertTrue(exported.path.endsWith(".wav"))
        val bytes = SystemFileSystem.source(Path(exported.path)).buffered().use { it.readByteArray() }
        assertEquals("RIFF", bytes.decodeToString(0, 4))
        assertEquals("WAVE", bytes.decodeToString(8, 12))
        assertEquals(44 + segment.frameSamples * Short.SIZE_BYTES * frameRecords.size, bytes.size)
    }

    @Test
    fun exportAllSkipsOpenSegments() = runTest {
        val closed = meta(segmentId = "closed", closed = true)
        val open = meta(segmentId = "open", closed = false)
        val root = Path(SystemTemporaryDirectory, "audio-export-${Random.nextLong()}")
        val manager = AudioExportManager(
            fileSystem = SystemFileSystem,
            exportRoot = root,
            listSegments = { listOf(closed, open) },
            readMeta = { id -> listOf(closed, open).firstOrNull { it.segmentId == id } },
            readFrames = { frames() },
            decodePcm = { meta, records ->
                flowOf(ByteArray(meta.frameSamples * Short.SIZE_BYTES * records.size))
            },
        )

        val result = manager.exportAllClosedSegments()

        assertEquals(1, result.fileCount)
        assertEquals(1, result.skippedOpenSegments)
        assertEquals("closed", result.files.single().segmentId)
    }
}
