package dev.audiocompanion.storage

import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.transport.SegmentCloseReason
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class RetentionManagerTest {

    private var clock = 1_000_000L
    private var freeBytes = 10L * 1024 * 1024 * 1024

    private val freeSpace = object : FreeSpaceProvider {
        override fun freeBytes(): Long = freeBytes
    }

    private fun tempRoot(): Path {
        val dir = File.createTempFile("retention", null).apply { delete(); mkdirs() }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun streamStart(id: UInt) = StreamStart(
        protocolVersion = 1, streamId = id, codecIdRaw = 1, channels = 1, frameSamples = 320,
        sampleRateHz = 16000u, bitRateBps = 9800u, frameDurationMs = 20,
        startTimeMs = 0u, startMonotonicMs = 0u, flags = 0u,
    )

    /** Creates a closed segment with ~[recordCount] 39-byte records and returns its id. */
    private suspend fun SegmentStore.makeSegment(
        id: UInt,
        recordCount: Int = 10,
        transcribed: Boolean = false,
        close: Boolean = true,
    ): String {
        openSegment(streamStart(id), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(openSegmentId)
        appendFrames(id, List(recordCount) { i ->
            SegmentFrame(i.toUInt(), i.toULong() * 320u, ByteArray(25))
        })
        if (close) closeSegment(SegmentCloseReason.Interrupted)
        if (transcribed) updateTranscriptionState(segmentId, TranscriptionState.Complete)
        clock += 1_000
        return segmentId
    }

    @Test
    fun sizeCap_deletesOldestFullyTranscribedFirst() = runTest {
        val root = tempRoot()
        val store = SegmentStore(SystemFileSystem, root, { clock })
        val oldTranscribed = store.makeSegment(1u, transcribed = true)
        val newTranscribed = store.makeSegment(2u, transcribed = true)
        val oldRaw = store.makeSegment(3u)
        val newRaw = store.makeSegment(4u)

        // Cap fits roughly two segments (each is 390 bytes).
        val manager = RetentionManager(
            store, freeSpace, { clock },
            RetentionConfig(maxTotalBytes = 800),
        )
        val deleted = manager.enforce()

        assertEquals(listOf(oldTranscribed, newTranscribed), deleted)
        assertEquals(
            listOf(oldRaw, newRaw),
            store.listSegments().map { it.segmentId },
            "untranscribed audio must outlive transcribed audio",
        )
    }

    @Test
    fun sizeCap_fallsBackToOldestUntranscribed_butNeverOpenSegment() = runTest {
        val root = tempRoot()
        val store = SegmentStore(SystemFileSystem, root, { clock })
        val oldRaw = store.makeSegment(1u)
        val openSegment = store.makeSegment(2u, close = false)

        val manager = RetentionManager(
            store, freeSpace, { clock },
            RetentionConfig(maxTotalBytes = 1),
        )
        val deleted = manager.enforce()

        assertEquals(listOf(oldRaw), deleted)
        assertEquals(openSegment, store.openSegmentId)
        assertEquals(listOf(openSegment), store.listSegments().map { it.segmentId },
            "the open segment is never deleted, even over cap")
    }

    @Test
    fun ageCap_deletesExpiredSegments() = runTest {
        val root = tempRoot()
        val store = SegmentStore(SystemFileSystem, root, { clock })
        val ancient = store.makeSegment(1u)
        clock += 31L * 24 * 60 * 60 * 1000
        val recent = store.makeSegment(2u)

        val manager = RetentionManager(store, freeSpace, { clock }, RetentionConfig())
        val deleted = manager.enforce()
        assertEquals(listOf(ancient), deleted)
        assertEquals(listOf(recent), store.listSegments().map { it.segmentId })
    }

    @Test
    fun storageFloors_driveReceiverFlagsAndHint() {
        val root = tempRoot()
        val store = SegmentStore(SystemFileSystem, root, { clock })
        val manager = RetentionManager(store, freeSpace, { clock }, RetentionConfig())

        freeBytes = 10L * 1024 * 1024 * 1024
        assertEquals(0u, manager.receiverFlags())

        freeBytes = 400L * 1024 * 1024 // < 500 MB: low storage, no pause yet
        assertEquals(ProtocolConstants.RECEIVER_FLAG_LOW_STORAGE, manager.receiverFlags())
        assertTrue(manager.lowStorage)
        assertTrue(!manager.pauseRequested)

        freeBytes = 100L * 1024 * 1024 // < 200 MB: low storage + pause requested
        assertEquals(
            ProtocolConstants.RECEIVER_FLAG_LOW_STORAGE or ProtocolConstants.RECEIVER_FLAG_PAUSE_REQUESTED,
            manager.receiverFlags(),
        )
        assertEquals((100L * 1024).toUInt(), manager.freeStorageHintKb())

        // Hint saturates instead of wrapping for very large free space.
        freeBytes = 8L * 1024 * 1024 * 1024 * 1024
        assertEquals(UInt.MAX_VALUE, manager.freeStorageHintKb())
    }
}
