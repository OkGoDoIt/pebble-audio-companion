package dev.audiocompanion.storage

import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.protocol.WireReader
import dev.audiocompanion.protocol.WireWriter
import dev.audiocompanion.transport.GapRecord
import dev.audiocompanion.transport.SegmentCloseReason
import dev.audiocompanion.transport.SegmentFrame
import dev.audiocompanion.transport.SegmentProvenance
import dev.audiocompanion.transport.SegmentSink
import kotlinx.io.Sink
import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.json.Json

/** One decoded frame-log record (same shape as a STREAM_DATA frame entry). */
class FrameRecord(
    val sequence: UInt,
    val sampleIndex: ULong,
    val payload: ByteArray,
)

data class SegmentStoreConfig(
    /** Rotate the open segment after this much wall time (plan 6.2: 15 min). */
    val rotateAfterMs: Long = 15L * 60 * 1000,
    /** ... or after this many frame-log bytes (plan 6.2: 16 MB). */
    val rotateAfterBytes: Long = 16L * 1024 * 1024,
)

/**
 * File-backed segment storage (implementation plan Section 6.2, Decision E — encoded
 * retention). Layout under [root]:
 *
 * - `segments/<segment_id>.spxlog` — append-only frame log of
 *   `{u32 seq, u64 sample_index, u16 len, u8 speex[len]}` records, little-endian: the same
 *   record shape as the firmware spool and the STREAM_DATA frame entry.
 * - `segments/<segment_id>.meta.json` — written via temp file + [FileSystem.atomicMove].
 * - `quarantine/` — orphan files swept aside by [recover].
 *
 * Not thread-safe: one receiver session drives it from one coroutine, matching
 * AudioReceiverSession's sequential message handling.
 */
class SegmentStore(
    private val fileSystem: FileSystem,
    private val root: Path,
    private val nowMs: () -> Long,
    private val config: SegmentStoreConfig = SegmentStoreConfig(),
) : SegmentSink {

    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }

    private val segmentsDir = Path(root, "segments")
    private val quarantineDir = Path(root, "quarantine")

    private class OpenSegment(
        var meta: SegmentMeta,
        val sink: Sink,
        var logBytes: Long,
        val openedAtMs: Long,
        val start: StreamStart,
        val provenance: SegmentProvenance?,
    )

    private var current: OpenSegment? = null
    private var segmentCounter = 0

    /** Segment id of the currently open segment, or null. */
    val openSegmentId: String? get() = current?.meta?.segmentId

    // --- paths ----------------------------------------------------------------------------------

    private fun logPath(segmentId: String) = Path(segmentsDir, "$segmentId.spxlog")
    private fun metaPath(segmentId: String) = Path(segmentsDir, "$segmentId.meta.json")

    // --- SegmentSink ---------------------------------------------------------------------------

    override suspend fun openSegment(start: StreamStart, receivedAtMs: Long, provenance: SegmentProvenance?) {
        closeSegment(SegmentCloseReason.Superseded)
        openSegmentInternal(start, receivedAtMs, provenance)
    }

    private fun openSegmentInternal(start: StreamStart, receivedAtMs: Long, provenance: SegmentProvenance?) {
        fileSystem.createDirectories(segmentsDir)
        segmentCounter += 1
        val segmentId = "seg-$receivedAtMs-${start.streamId.toString(16).padStart(8, '0')}-$segmentCounter"
        val meta = SegmentMeta(
            segmentId = segmentId,
            streamId = start.streamId,
            protocolVersion = start.protocolVersion,
            codecIdRaw = start.codecIdRaw,
            channels = start.channels,
            frameSamples = start.frameSamples,
            sampleRateHz = start.sampleRateHz,
            bitRateBps = start.bitRateBps,
            frameDurationMs = start.frameDurationMs,
            startTimeMs = start.startTimeMs,
            startMonotonicMs = start.startMonotonicMs,
            receivedAtMs = receivedAtMs,
            provenance = provenance?.let { ProvenanceMeta(it.fwVersionPacked, it.protocolVersion) },
        )
        writeMetaAtomically(meta)
        val sink = fileSystem.sink(logPath(segmentId), append = true).buffered()
        current = OpenSegment(
            meta = meta,
            sink = sink,
            logBytes = 0,
            openedAtMs = nowMs(),
            start = start,
            provenance = provenance,
        )
    }

    override suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>) {
        val segment = current ?: return
        if (segment.meta.streamId != streamId) return

        val writer = WireWriter(frames.sumOf { it.payload.size + RECORD_HEADER_BYTES })
        for (frame in frames) {
            writer.u32(frame.sequence)
            writer.u64(frame.sampleIndex)
            writer.u16(frame.payload.size)
            writer.bytes(frame.payload)
        }
        val bytes = writer.toByteArray()
        segment.sink.write(bytes)
        segment.sink.flush() // durability point: the session checkpoints only what is flushed
        segment.logBytes += bytes.size

        val first = frames.first()
        val last = frames.last()
        segment.meta = segment.meta.copy(
            firstSequence = segment.meta.firstSequence ?: first.sequence,
            lastSequence = maxOf(segment.meta.lastSequence ?: 0u, last.sequence),
            firstSampleIndex = segment.meta.firstSampleIndex ?: first.sampleIndex,
            lastSampleIndexExclusive = maxOf(
                segment.meta.lastSampleIndexExclusive ?: 0u,
                last.sampleIndex + segment.meta.frameSamples.toULong(),
            ),
            frameCount = segment.meta.frameCount + frames.size,
        )

        maybeRotate(segment)
    }

    override suspend fun recordGap(streamId: UInt, gap: GapRecord) {
        val segment = current ?: return
        if (segment.meta.streamId != streamId) return
        segment.meta = segment.meta.copy(gaps = segment.meta.gaps + GapMeta.from(gap))
        writeMetaAtomically(segment.meta)
    }

    override suspend fun closeSegment(reason: SegmentCloseReason) {
        closeSegmentInternal(CloseReasonMeta.from(reason))
    }

    private fun closeSegmentInternal(reason: CloseReasonMeta) {
        val segment = current ?: return
        current = null
        segment.sink.close()
        segment.meta = segment.meta.copy(closeReason = reason)
        writeMetaAtomically(segment.meta)
    }

    /** Rotation (plan 6.2): close at 15 min or 16 MB; the stream continues in a new segment. */
    private fun maybeRotate(segment: OpenSegment) {
        val tooOld = nowMs() - segment.openedAtMs >= config.rotateAfterMs
        val tooBig = segment.logBytes >= config.rotateAfterBytes
        if (!tooOld && !tooBig) return
        val start = segment.start
        val provenance = segment.provenance
        closeSegmentInternal(CloseReasonMeta.Rotated)
        openSegmentInternal(start, nowMs(), provenance)
    }

    // --- meta persistence ------------------------------------------------------------------------

    private fun writeMetaAtomically(meta: SegmentMeta) {
        fileSystem.createDirectories(segmentsDir)
        val final = metaPath(meta.segmentId)
        val tmp = Path(segmentsDir, "${meta.segmentId}.meta.json.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(SegmentMeta.serializer(), meta).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, final)
    }

    /** Marks transcription progress for a closed segment (used by :core:transcription's queue). */
    fun updateTranscriptionState(segmentId: String, state: TranscriptionState) {
        val meta = readMeta(segmentId) ?: return
        writeMetaAtomically(meta.copy(transcriptionState = state))
        current?.let { if (it.meta.segmentId == segmentId) it.meta = it.meta.copy(transcriptionState = state) }
    }

    // --- reading ----------------------------------------------------------------------------------

    fun readMeta(segmentId: String): SegmentMeta? {
        val path = metaPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SegmentMeta.serializer(), text) }.getOrNull()
    }

    fun listSegments(): List<SegmentMeta> {
        if (!fileSystem.exists(segmentsDir)) return emptyList()
        return fileSystem.list(segmentsDir)
            .filter { it.name.endsWith(META_SUFFIX) }
            .mapNotNull { readMeta(it.name.removeSuffix(META_SUFFIX)) }
            .sortedBy { it.receivedAtMs }
    }

    fun logSizeBytes(segmentId: String): Long =
        fileSystem.metadataOrNull(logPath(segmentId))?.size ?: 0L

    fun readFrames(segmentId: String): List<FrameRecord> {
        val path = logPath(segmentId)
        if (!fileSystem.exists(path)) return emptyList()
        val bytes = fileSystem.source(path).buffered().use { it.readByteArray() }
        return parseRecords(bytes).records
    }

    fun deleteSegment(segmentId: String) {
        check(segmentId != openSegmentId) { "refusing to delete the open segment $segmentId" }
        fileSystem.delete(logPath(segmentId), mustExist = false)
        fileSystem.delete(metaPath(segmentId), mustExist = false)
    }

    // --- corruption recovery -----------------------------------------------------------------------

    /**
     * Validates the on-disk state (plan 6.2): leftover temp files are removed, frame logs with
     * invalid framing are truncated at the first bad record, metas are reconciled with their log
     * (open segments become interrupted), and orphan logs are swept to `quarantine/`.
     * Call once on startup before opening new segments.
     */
    fun recover() {
        check(current == null) { "recover() must run before any segment is opened" }
        if (!fileSystem.exists(segmentsDir)) return
        val entries = fileSystem.list(segmentsDir).toList()

        // Leftover atomic-write temps: the final file either exists (rename happened) or the
        // write never completed; either way the temp is garbage.
        entries.filter { it.name.endsWith(".tmp") }
            .forEach { fileSystem.delete(it, mustExist = false) }

        val logs = entries.filter { it.name.endsWith(LOG_SUFFIX) }
        for (log in logs) {
            val segmentId = log.name.removeSuffix(LOG_SUFFIX)
            val meta = readMeta(segmentId)
            if (meta == null) {
                quarantine(log)
                continue
            }
            val bytes = fileSystem.source(log).buffered().use { it.readByteArray() }
            val parsed = parseRecords(bytes)
            if (parsed.validBytes < bytes.size) {
                // Truncate at the first bad record via temp + atomic rename.
                val tmp = Path(segmentsDir, "$segmentId$LOG_SUFFIX.tmp")
                fileSystem.sink(tmp).buffered().use { it.write(bytes, 0, parsed.validBytes) }
                fileSystem.atomicMove(tmp, log)
            }
            reconcileMeta(meta, parsed.records)
        }
    }

    private fun reconcileMeta(meta: SegmentMeta, records: List<FrameRecord>) {
        val reconciled = meta.copy(
            firstSequence = records.firstOrNull()?.sequence,
            lastSequence = records.maxOfOrNull { it.sequence },
            firstSampleIndex = records.firstOrNull()?.sampleIndex,
            lastSampleIndexExclusive = records.maxOfOrNull { it.sampleIndex + meta.frameSamples.toULong() },
            frameCount = records.size.toLong(),
            // A meta still marked open means we died with the segment open: it was interrupted.
            closeReason = meta.closeReason ?: CloseReasonMeta.Interrupted,
        )
        if (reconciled != meta) writeMetaAtomically(reconciled)
    }

    private fun quarantine(path: Path) {
        fileSystem.createDirectories(quarantineDir)
        fileSystem.atomicMove(path, Path(quarantineDir, path.name))
    }

    private class ParseResult(val records: List<FrameRecord>, val validBytes: Int)

    private fun parseRecords(bytes: ByteArray): ParseResult {
        val records = mutableListOf<FrameRecord>()
        var offset = 0
        val reader = WireReader(bytes)
        while (true) {
            if (reader.remaining < RECORD_HEADER_BYTES) break
            val sequence = reader.u32()
            val sampleIndex = reader.u64()
            val len = reader.u16()
            if (len > ProtocolConstants.MAX_ENCODED_FRAME_BYTES || reader.remaining < len) break
            records.add(FrameRecord(sequence, sampleIndex, reader.bytes(len)))
            offset += RECORD_HEADER_BYTES + len
        }
        return ParseResult(records, offset)
    }

    companion object {
        const val LOG_SUFFIX = ".spxlog"
        const val META_SUFFIX = ".meta.json"

        /** u32 seq + u64 sample_index + u16 len. */
        const val RECORD_HEADER_BYTES = 14
    }
}
