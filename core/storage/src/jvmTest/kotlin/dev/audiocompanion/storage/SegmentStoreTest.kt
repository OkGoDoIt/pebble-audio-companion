package dev.audiocompanion.storage

import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.transport.GapOrigin
import dev.audiocompanion.transport.GapRecord
import dev.audiocompanion.transport.SegmentCloseReason
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.serialization.json.Json
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class SegmentStoreTest {

    private val streamId = 0x5EED0001u
    private var clock = 1_000_000L
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }

    private fun tempRoot(): Path {
        val dir = File.createTempFile("segstore", null).apply { delete(); mkdirs() }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun store(root: Path, config: SegmentStoreConfig = SegmentStoreConfig()) =
        SegmentStore(SystemFileSystem, root, { clock }, config)

    private fun streamStart(id: UInt = streamId, flags: UInt = 0u) = StreamStart(
        protocolVersion = 1,
        streamId = id,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16000u,
        bitRateBps = 9800u,
        frameDurationMs = 20,
        startTimeMs = 1_781_000_000_000u,
        startMonotonicMs = 86_400_123u,
        flags = flags,
    )

    private fun frames(firstSequence: UInt, count: Int, len: Int = 25): List<SegmentFrame> =
        List(count) { i ->
            SegmentFrame(
                sequence = firstSequence + i.toUInt(),
                sampleIndex = (firstSequence + i.toUInt()).toULong() * 320u,
                payload = ByteArray(len) { b -> ((firstSequence.toInt() + i + b) and 0xFF).toByte() },
            )
        }

    private fun gap(
        firstSequence: UInt,
        count: UInt,
        origin: GapOrigin = GapOrigin.SequenceSkip,
    ) = GapRecord(
        firstMissingSequence = firstSequence,
        missingFrameCount = count,
        firstMissingSampleIndex = firstSequence.toULong() * 320u,
        origin = origin,
    )

    private fun segmentsDir(root: Path) = File(root.toString(), "segments")

    private fun metaFile(root: Path, segmentId: String) =
        File(segmentsDir(root), "$segmentId${SegmentStore.META_SUFFIX}")

    private fun assertNoTempFiles(root: Path) {
        val leftovers = segmentsDir(root).listFiles().orEmpty().filter { it.name.endsWith(".tmp") }
        assertTrue(leftovers.isEmpty(), "temp files left behind: $leftovers")
    }

    // ------------------------------------------------------------------------------------------

    @Test
    fun appendAndReopenRoundTrip() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        val written = frames(0u, 8) + frames(8u, 4, len = 60)
        store.appendFrames(streamId, written.take(8))
        store.appendFrames(streamId, written.drop(8))
        store.recordGap(
            streamId,
            GapRecord(12u, 4u, 12uL * 320u, GapOrigin.WatchReported(reasonRaw = 1, watchDropCounter = 4u)),
        )
        store.closeSegment(SegmentCloseReason.Stopped(reasonRaw = 1, finalSequence = 11u, finalSampleIndex = 3840u))

        // Fresh instance, as after process restart.
        val reopened = store(root)
        reopened.recover()
        val read = reopened.readFrames(segmentId)
        assertEquals(written.size, read.size)
        written.zip(read).forEach { (w, r) ->
            assertEquals(w.sequence, r.sequence)
            assertEquals(w.sampleIndex, r.sampleIndex)
            assertContentEquals(w.payload, r.payload)
        }
        val meta = assertNotNull(reopened.readMeta(segmentId))
        assertEquals(0u, meta.firstSequence)
        assertEquals(11u, meta.lastSequence)
        assertEquals(12uL * 320u, meta.lastSampleIndexExclusive)
        assertEquals(12L, meta.frameCount)
        assertEquals(CloseReasonMeta.KIND_STOPPED, meta.closeReason?.kind)
        assertEquals(1, meta.closeReason?.stopReasonRaw)
        val gap = meta.gaps.single()
        assertEquals(12u, gap.firstMissingSequence)
        assertEquals(GapMeta.ORIGIN_WATCH, gap.origin)
        assertNoTempFiles(root)
    }

    @Test
    fun openSegmentMetaIsFlushedPeriodicallyWhileRecording() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        // Below the flush threshold: on-disk sidecar still has the open-time counters.
        store.appendFrames(streamId, frames(0u, SegmentStore.OPEN_META_FLUSH_FRAMES - 1))
        assertEquals(0L, assertNotNull(store.readMeta(segmentId)).frameCount)

        // Crossing the threshold flushes the live counters without closing the segment.
        store.appendFrames(streamId, frames((SegmentStore.OPEN_META_FLUSH_FRAMES - 1).toUInt(), 2))
        val flushed = assertNotNull(store.readMeta(segmentId))
        assertEquals((SegmentStore.OPEN_META_FLUSH_FRAMES + 1).toLong(), flushed.frameCount)
        assertTrue(flushed.isOpen, "periodic flush must not close the segment")
        assertNoTempFiles(root)
    }

    @Test
    fun readsAreServedFromTheInMemoryIndexNotDiskEachCall() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 4))
        store.closeSegment(
            SegmentCloseReason.Stopped(reasonRaw = 1, finalSequence = 3u, finalSampleIndex = 4uL * 320u),
        )

        // Prime the index, then delete the on-disk sidecar behind the store's back. Before the
        // in-memory index, every read re-listed and re-parsed the directory, so the segment would
        // disappear here — and that per-call full-library disk re-parse is what starved iOS launch.
        assertEquals(1, store.listSegments().size)
        assertTrue(File(segmentsDir(root), "$segmentId.meta.json").delete())
        assertEquals(1, store.listSegments().size, "reads must come from the in-memory index")
        assertNotNull(store.readMeta(segmentId))

        // deleteSegment evicts from the index as well.
        store.deleteSegment(segmentId)
        assertTrue(store.listSegments().isEmpty())
    }

    @Test
    fun silenceSuppressedGapsAreNotPersistedAsDurableLoss() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        store.recordGap(
            streamId,
            gap(
                20u,
                150u,
                GapOrigin.WatchReported(
                    reasonRaw = GapReason.SilenceSuppressed.raw,
                    watchDropCounter = 0u,
                ),
            ),
        )

        assertTrue(assertNotNull(store.readMeta(segmentId)).gaps.isEmpty())
        store.closeSegment(SegmentCloseReason.Interrupted)

        val reopened = store(root)
        reopened.recover()
        assertTrue(assertNotNull(reopened.readMeta(segmentId)).gaps.isEmpty())
    }

    @Test
    fun contiguousSequenceSkipsCoalesceIntoOneDurableLossPeriod() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        store.recordGap(streamId, gap(10u, 1u))
        store.recordGap(streamId, gap(11u, 1u))
        store.recordGap(streamId, gap(12u, 3u))

        val stored = assertNotNull(store.readMeta(segmentId)).gaps.single()
        assertEquals(10u, stored.firstMissingSequence)
        assertEquals(5u, stored.missingFrameCount)
        assertEquals(GapMeta.ORIGIN_SEQUENCE_SKIP, stored.origin)
    }

    @Test
    fun contiguousWatchLossCoalescesAndKeepsNewestDropCounter() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        store.recordGap(
            streamId,
            gap(50u, 4u, GapOrigin.WatchReported(GapReason.SpoolOverflow.raw, watchDropCounter = 4u)),
        )
        store.recordGap(
            streamId,
            gap(54u, 6u, GapOrigin.WatchReported(GapReason.SpoolOverflow.raw, watchDropCounter = 10u)),
        )

        val stored = assertNotNull(store.readMeta(segmentId)).gaps.single()
        assertEquals(50u, stored.firstMissingSequence)
        assertEquals(10u, stored.missingFrameCount)
        assertEquals(GapMeta.ORIGIN_WATCH, stored.origin)
        assertEquals(GapReason.SpoolOverflow.raw, stored.reasonRaw)
        assertEquals(10u, stored.watchDropCounter)
    }

    @Test
    fun overlappingRepeatedLossCoalescesIntoOneDurablePeriod() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        store.recordGap(
            streamId,
            gap(100u, 50u, GapOrigin.WatchReported(GapReason.TransportReset.raw, watchDropCounter = 20u)),
        )
        store.recordGap(streamId, gap(100u, 55u))
        store.recordGap(streamId, gap(100u, 60u))

        val stored = assertNotNull(store.readMeta(segmentId)).gaps.single()
        assertEquals(100u, stored.firstMissingSequence)
        assertEquals(60u, stored.missingFrameCount)
        assertEquals(GapMeta.ORIGIN_WATCH, stored.origin)
        assertEquals(GapReason.TransportReset.raw, stored.reasonRaw)
    }

    @Test
    fun recoverNormalizesLegacyGapMetadata() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.closeSegment(SegmentCloseReason.Interrupted)

        val sidecar = metaFile(root, segmentId)
        val closed = json.decodeFromString(SegmentMeta.serializer(), sidecar.readText())
        val polluted = closed.copy(
            gaps = listOf(
                GapMeta(
                    firstMissingSequence = 10u,
                    missingFrameCount = 5u,
                    firstMissingSampleIndex = 10uL * 320u,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.SilenceSuppressed.raw,
                    watchDropCounter = 0u,
                ),
                GapMeta(
                    firstMissingSequence = 10u,
                    missingFrameCount = 5u,
                    firstMissingSampleIndex = 10uL * 320u,
                    origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
                ),
                GapMeta(
                    firstMissingSequence = 100u,
                    missingFrameCount = 50u,
                    firstMissingSampleIndex = 100uL * 320u,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.TransportReset.raw,
                    watchDropCounter = 50u,
                ),
                GapMeta(
                    firstMissingSequence = 100u,
                    missingFrameCount = 60u,
                    firstMissingSampleIndex = 100uL * 320u,
                    origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
                ),
                GapMeta(
                    firstMissingSequence = 200u,
                    missingFrameCount = 5u,
                    firstMissingSampleIndex = 200uL * 320u,
                    origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
                ),
            )
        )
        sidecar.writeText(json.encodeToString(SegmentMeta.serializer(), polluted))

        val reopened = store(root)
        reopened.recover()

        val gaps = assertNotNull(reopened.readMeta(segmentId)).gaps
        assertEquals(2, gaps.size)
        assertEquals(100u, gaps[0].firstMissingSequence)
        assertEquals(60u, gaps[0].missingFrameCount)
        assertEquals(GapMeta.ORIGIN_WATCH, gaps[0].origin)
        assertEquals(GapReason.TransportReset.raw, gaps[0].reasonRaw)
        assertEquals(200u, gaps[1].firstMissingSequence)
        assertEquals(5u, gaps[1].missingFrameCount)
        assertEquals(GapMeta.ORIGIN_SEQUENCE_SKIP, gaps[1].origin)

        val persisted = json.decodeFromString(SegmentMeta.serializer(), sidecar.readText())
        assertEquals(gaps, persisted.gaps)
    }

    @Test
    fun nonContiguousLossRemainsSeparateDurablePeriods() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)

        store.recordGap(streamId, gap(10u, 2u))
        store.recordGap(streamId, gap(13u, 2u))

        val gaps = assertNotNull(store.readMeta(segmentId)).gaps
        assertEquals(2, gaps.size)
        assertEquals(10u, gaps[0].firstMissingSequence)
        assertEquals(2u, gaps[0].missingFrameCount)
        assertEquals(13u, gaps[1].firstMissingSequence)
        assertEquals(2u, gaps[1].missingFrameCount)
    }

    @Test
    fun resumedLegacySilenceGapDoesNotAbsorbLaterLoss() = runTest {
        val root = tempRoot()
        val store = store(root)
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.closeSegment(SegmentCloseReason.Interrupted)

        val sidecar = metaFile(root, segmentId)
        val closed = json.decodeFromString(SegmentMeta.serializer(), sidecar.readText())
        val legacy = closed.copy(
            gaps = listOf(
                GapMeta(
                    firstMissingSequence = 100u,
                    missingFrameCount = 5u,
                    firstMissingSampleIndex = 100uL * 320u,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.SilenceSuppressed.raw,
                    watchDropCounter = 0u,
                )
            )
        )
        sidecar.writeText(json.encodeToString(SegmentMeta.serializer(), legacy))

        clock += 1_000
        val resumed = store(root)
        resumed.recover()
        resumed.openSegment(
            start.copy(flags = ProtocolConstants.STREAM_START_FLAG_RESUME),
            receivedAtMs = clock,
            provenance = null,
        )
        assertEquals(segmentId, resumed.openSegmentId)

        resumed.recordGap(
            streamId,
            gap(105u, 2u, GapOrigin.WatchReported(GapReason.SpoolOverflow.raw, watchDropCounter = 2u)),
        )

        val gaps = assertNotNull(resumed.readMeta(segmentId)).gaps
        assertEquals(1, gaps.size)
        assertEquals(105u, gaps[0].firstMissingSequence)
        assertEquals(2u, gaps[0].missingFrameCount)
        assertEquals(GapReason.SpoolOverflow.raw, gaps[0].reasonRaw)
    }

    @Test
    fun killMidAppend_truncatesToLastGoodRecord() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 3))
        val goodSize = store.logSizeBytes(segmentId)

        // Simulate power loss mid-append: a partial record lands at the end of the log
        // (header claims 25 payload bytes, only 5 made it to disk).
        val log = File(segmentsDir(root), "$segmentId.spxlog")
        val partial = byteArrayOf(3, 0, 0, 0) + ByteArray(8) + byteArrayOf(25, 0) + ByteArray(5)
        log.appendBytes(partial)

        val reopened = store(root)
        reopened.recover()
        assertEquals(goodSize, reopened.logSizeBytes(segmentId), "log must be truncated to the last good record")
        val read = reopened.readFrames(segmentId)
        assertEquals(3, read.size)
        assertEquals(2u, read.last().sequence)
        // Meta written while open is reconciled against the surviving log.
        val meta = assertNotNull(reopened.readMeta(segmentId))
        assertEquals(3L, meta.frameCount)
        assertEquals(2u, meta.lastSequence)
        assertEquals(CloseReasonMeta.KIND_INTERRUPTED, meta.closeReason?.kind)
    }

    @Test
    fun recoverTruncatesGarbageLengthField() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 2))
        val goodSize = store.logSizeBytes(segmentId)

        // Record header with a length beyond MAX_ENCODED_FRAME_BYTES (corrupt bit flip).
        val log = File(segmentsDir(root), "$segmentId.spxlog")
        log.appendBytes(byteArrayOf(9, 0, 0, 0) + ByteArray(8) + byteArrayOf(0xFF.toByte(), 0x7F) + ByteArray(40))

        val reopened = store(root)
        reopened.recover()
        assertEquals(goodSize, reopened.logSizeBytes(segmentId))
        assertEquals(2, reopened.readFrames(segmentId).size)
    }

    @Test
    fun atomicMeta_neverLeavesTempBehind_andRecoverSweepsStaleTemp() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        store.appendFrames(streamId, frames(0u, 4))
        store.recordGap(streamId, GapRecord(4u, 1u, 1280u, GapOrigin.SequenceSkip))
        store.closeSegment(SegmentCloseReason.Interrupted)
        assertNoTempFiles(root)

        // A stale temp from a crash mid-meta-write must be swept by recovery.
        val stale = File(segmentsDir(root), "seg-bogus.meta.json.tmp")
        stale.writeText("{ partial")
        val reopened = store(root)
        reopened.recover()
        assertFalse(stale.exists())
        assertNoTempFiles(root)
    }

    @Test
    fun resumeStartWithinContinuationWindowReopensInterruptedSegment() = runTest {
        val root = tempRoot()
        val store = store(root)
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 3))
        clock += 2_000
        store.closeSegment(SegmentCloseReason.Interrupted)

        clock += 45_000
        store.openSegment(
            start.copy(flags = ProtocolConstants.STREAM_START_FLAG_RESUME),
            receivedAtMs = clock,
            provenance = null,
        )

        assertEquals(segmentId, store.openSegmentId)
        store.appendFrames(streamId, frames(3u, 2))
        val reopenedMeta = assertNotNull(store.readMeta(segmentId))
        assertTrue(reopenedMeta.isOpen, "continued segment should be open again")
        assertEquals(null, reopenedMeta.closedAtMs)
        store.closeSegment(SegmentCloseReason.Interrupted)
        val closedMeta = assertNotNull(store.readMeta(segmentId))
        assertEquals(5L, closedMeta.frameCount)
        assertEquals(4u, closedMeta.lastSequence)
        assertEquals(5, store.readFrames(segmentId).size)
    }

    @Test
    fun resumeStartAfterContinuationWindowOpensNewSegment() = runTest {
        val root = tempRoot()
        val store = store(root, SegmentStoreConfig(continueInterruptedWithinMs = 60_000))
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val firstId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 1))
        store.closeSegment(SegmentCloseReason.Interrupted)

        clock += 60_001
        store.openSegment(
            start.copy(flags = ProtocolConstants.STREAM_START_FLAG_RESUME),
            receivedAtMs = clock,
            provenance = null,
        )

        val secondId = assertNotNull(store.openSegmentId)
        assertTrue(secondId != firstId, "long interruptions should remain separate Library rows")
        assertEquals(CloseReasonMeta.KIND_INTERRUPTED, store.readMeta(firstId)?.closeReason?.kind)
    }

    @Test
    fun resumeStartWithChangedTimestampsStillReattaches() = runTest {
        // Firmware re-announcements historically recomputed start_time_ms/start_monotonic_ms at
        // send time, so reattachment must not depend on them matching the original STREAM_START.
        val root = tempRoot()
        val store = store(root)
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 3))
        clock += 2_000
        store.closeSegment(SegmentCloseReason.Interrupted)

        clock += 30_000
        store.openSegment(
            start.copy(
                flags = ProtocolConstants.STREAM_START_FLAG_RESUME,
                startTimeMs = start.startTimeMs + 32_000u,
                startMonotonicMs = start.startMonotonicMs + 32_000u,
            ),
            receivedAtMs = clock,
            provenance = null,
        )

        assertEquals(segmentId, store.openSegmentId, "fresh re-announce timestamps must not block reattach")
        val meta = assertNotNull(store.readMeta(segmentId))
        assertEquals(start.startTimeMs, meta.startTimeMs, "the meta keeps the stream-birth wall clock")
        assertEquals(start.startMonotonicMs, meta.startMonotonicMs)
    }

    @Test
    fun resumeStartForOpenStreamContinuesInPlace() = runTest {
        // A RESUME re-announcement can arrive while the segment is still open (the phone never
        // saw the link drop). That must continue the open segment, not supersede it.
        val root = tempRoot()
        val store = store(root)
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 3))

        clock += 5_000
        store.openSegment(
            start.copy(
                flags = ProtocolConstants.STREAM_START_FLAG_RESUME,
                startTimeMs = start.startTimeMs + 5_000u,
                startMonotonicMs = start.startMonotonicMs + 5_000u,
            ),
            receivedAtMs = clock,
            provenance = null,
        )

        assertEquals(segmentId, store.openSegmentId, "in-place RESUME must not supersede the open segment")
        store.appendFrames(streamId, frames(3u, 2))
        store.closeSegment(SegmentCloseReason.Stopped(reasonRaw = 1, finalSequence = 4u, finalSampleIndex = 1600u))

        val meta = assertNotNull(store.readMeta(segmentId))
        assertEquals(5L, meta.frameCount)
        assertEquals(4u, meta.lastSequence)
        assertEquals(CloseReasonMeta.KIND_STOPPED, meta.closeReason?.kind)
        assertEquals(1, store.listSegments().size, "no superseded twin segment may appear")
    }

    @Test
    fun resumeRewindDoesNotDuplicatePersistedFrames() = runTest {
        // After a reattach the watch rewinds its spool to the last checkpoint, re-sending frames
        // the phone may already have persisted. Those exact re-sends must be dropped, while new
        // frames past the persisted high-water mark append normally.
        val root = tempRoot()
        val store = store(root)
        val start = streamStart()
        store.openSegment(start, receivedAtMs = clock, provenance = null)
        val segmentId = assertNotNull(store.openSegmentId)
        store.appendFrames(streamId, frames(0u, 5))

        store.openSegment(
            start.copy(flags = ProtocolConstants.STREAM_START_FLAG_RESUME),
            receivedAtMs = clock,
            provenance = null,
        )
        // Rewound batch: sequences 3..6 — 3 and 4 are duplicates, 5 and 6 are new.
        store.appendFrames(streamId, frames(3u, 4))
        store.closeSegment(SegmentCloseReason.Interrupted)

        val read = store.readFrames(segmentId)
        assertEquals((0u until 7u).map { it }, read.map { it.sequence }, "no duplicate sequences in the log")
        val meta = assertNotNull(store.readMeta(segmentId))
        assertEquals(7L, meta.frameCount)
        assertEquals(6u, meta.lastSequence)
    }

    @Test
    fun resumeStartForOpenStreamWithChangedCodecSupersedes() = runTest {
        // Same stream id but a different codec contract cannot continue in place: the open
        // segment closes as superseded and a fresh segment takes over.
        val root = tempRoot()
        val logged = mutableListOf<String>()
        val storeWithLog = SegmentStore(SystemFileSystem, root, { clock }, SegmentStoreConfig(), logged::add)
        val start = streamStart()
        storeWithLog.openSegment(start, receivedAtMs = clock, provenance = null)
        val firstId = assertNotNull(storeWithLog.openSegmentId)
        storeWithLog.appendFrames(streamId, frames(0u, 2))

        storeWithLog.openSegment(
            start.copy(flags = ProtocolConstants.STREAM_START_FLAG_RESUME, frameSamples = 160),
            receivedAtMs = clock,
            provenance = null,
        )

        val secondId = assertNotNull(storeWithLog.openSegmentId)
        assertTrue(secondId != firstId)
        assertEquals(CloseReasonMeta.KIND_SUPERSEDED, storeWithLog.readMeta(firstId)?.closeReason?.kind)
        assertTrue(
            logged.any { it.contains("frameSamples") },
            "the failing field must be logged, got: $logged",
        )
    }

    @Test
    fun freshStreamStartDoesNotReopenInterruptedSegment() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val firstId = assertNotNull(store.openSegmentId)
        store.closeSegment(SegmentCloseReason.Interrupted)

        clock += 10_000
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)

        assertTrue(store.openSegmentId != firstId)
    }

    @Test
    fun rotationBySize() = runTest {
        val root = tempRoot()
        // 25-byte payloads -> 39-byte records; 3 records cross the 100-byte cap.
        val store = store(root, SegmentStoreConfig(rotateAfterBytes = 100))
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val firstId = assertNotNull(store.openSegmentId)

        store.appendFrames(streamId, frames(0u, 3))
        val secondId = assertNotNull(store.openSegmentId)
        assertTrue(firstId != secondId, "size cap must rotate to a new segment")

        val firstMeta = assertNotNull(store.readMeta(firstId))
        assertEquals(CloseReasonMeta.KIND_ROTATED, firstMeta.closeReason?.kind)
        assertEquals(3L, firstMeta.frameCount)

        // The stream continues in the new segment with the same stream metadata.
        store.appendFrames(streamId, frames(3u, 1))
        val secondMeta = assertNotNull(store.readMeta(secondId))
        assertEquals(streamId, secondMeta.streamId)
        assertEquals(3u, assertNotNull(store.readFrames(secondId)).single().sequence)
    }

    @Test
    fun rotationByTime() = runTest {
        val root = tempRoot()
        val store = store(root, SegmentStoreConfig(rotateAfterMs = 15 * 60 * 1000))
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        val firstId = assertNotNull(store.openSegmentId)

        store.appendFrames(streamId, frames(0u, 2))
        assertEquals(firstId, store.openSegmentId, "no rotation before the time cap")

        clock += 15 * 60 * 1000 + 1
        store.appendFrames(streamId, frames(2u, 2))
        assertTrue(store.openSegmentId != firstId, "time cap must rotate")
        assertEquals(CloseReasonMeta.KIND_ROTATED, store.readMeta(firstId)?.closeReason?.kind)
    }

    @Test
    fun orphanLogIsQuarantined() = runTest {
        val root = tempRoot()
        val store = store(root)
        store.openSegment(streamStart(), receivedAtMs = clock, provenance = null)
        store.appendFrames(streamId, frames(0u, 1))
        store.closeSegment(SegmentCloseReason.Interrupted)

        val orphan = File(segmentsDir(root), "seg-orphan.spxlog")
        orphan.writeBytes(ByteArray(10) { 1 })

        val reopened = store(root)
        reopened.recover()
        assertFalse(orphan.exists(), "orphan must be moved out of segments/")
        assertTrue(File(root.toString(), "quarantine/seg-orphan.spxlog").exists())
        // The healthy segment is untouched.
        assertEquals(1, reopened.listSegments().size)
    }

    @Test
    fun resumeStateRoundTrip() = runTest {
        val root = tempRoot()
        val store = FileReceiverResumeStore(SystemFileSystem, root)
        assertEquals(null, store.load())

        val state = dev.audiocompanion.transport.ReceiverResumeState(
            lastStreamId = streamId,
            lastContiguousSequence = 4999u,
            lastSampleIndex = 1_600_000u,
        )
        store.save(state)
        assertEquals(state, FileReceiverResumeStore(SystemFileSystem, root).load())

        // Overwrite with a nothing-persisted state.
        val empty = dev.audiocompanion.transport.ReceiverResumeState(
            lastStreamId = 7u,
            lastContiguousSequence = null,
            lastSampleIndex = 0u,
        )
        store.save(empty)
        assertEquals(empty, FileReceiverResumeStore(SystemFileSystem, root).load())
        assertFalse(File(root.toString(), "receiver_state.json.tmp").exists())

        store.clear()
        assertEquals(null, store.load())
    }
}
