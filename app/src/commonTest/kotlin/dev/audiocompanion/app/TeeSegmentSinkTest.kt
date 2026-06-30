package dev.audiocompanion.app

import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.storage.SegmentStoreConfig
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

@OptIn(ExperimentalCoroutinesApi::class)
class TeeSegmentSinkTest {
    private var clock = 1_000L

    @Test
    fun rotationEmitsLiveCloudCloseAndOpenBoundaries() = runTest {
        val root = Path(SystemTemporaryDirectory, "tee-sink-${Random.nextLong()}")
        SystemFileSystem.createDirectories(root)
        val store = SegmentStore(
            fileSystem = SystemFileSystem,
            root = root,
            nowMs = { clock },
            config = SegmentStoreConfig(rotateAfterBytes = 10),
        )
        val tap = LiveAudioTap()
        val events = mutableListOf<LiveAudioEvent>()
        val eventJob = launch {
            tap.events.collect { events += it }
        }
        runCurrent()

        var closedWakeups = 0
        val sink = TeeSegmentSink(
            store = store,
            monitor = LiveAudioMonitor(decoder = null, nowMs = { clock }),
            nowMs = { clock },
            tap = tap,
            onSegmentClosed = { closedWakeups += 1 },
        )

        sink.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val originalSegmentId = store.openSegmentId
        sink.appendFrames(streamId, frames(firstSequence = 0u, count = 1))
        val rotatedSegmentId = store.openSegmentId
        runCurrent()

        assertEquals(4, events.size)
        assertIs<LiveAudioEvent.SegmentOpened>(events[0])
        assertEquals(originalSegmentId, (events[0] as LiveAudioEvent.SegmentOpened).segmentId)
        assertIs<LiveAudioEvent.FramesAppended>(events[1])
        assertEquals(originalSegmentId, (events[1] as LiveAudioEvent.FramesAppended).segmentId)
        assertIs<LiveAudioEvent.SegmentClosed>(events[2])
        assertEquals(originalSegmentId, (events[2] as LiveAudioEvent.SegmentClosed).segmentId)
        assertIs<LiveAudioEvent.SegmentOpened>(events[3])
        assertEquals(rotatedSegmentId, (events[3] as LiveAudioEvent.SegmentOpened).segmentId)
        assertEquals(1, closedWakeups)

        eventJob.cancel()
    }

    private fun streamStart(id: UInt = streamId) = StreamStart(
        protocolVersion = 1,
        streamId = id,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16_000u,
        bitRateBps = 9_800u,
        frameDurationMs = 20,
        startTimeMs = 1_781_000_000_000u,
        startMonotonicMs = 86_400_123u,
        flags = 0u,
    )

    private fun frames(firstSequence: UInt, count: Int): List<SegmentFrame> =
        List(count) { index ->
            val sequence = firstSequence + index.toUInt()
            SegmentFrame(
                sequence = sequence,
                sampleIndex = sequence.toULong() * 320u,
                payload = ByteArray(25) { it.toByte() },
            )
        }

    private companion object {
        const val streamId: UInt = 7u
    }
}
