package dev.audiocompanion.storage

import dev.audiocompanion.protocol.GapReason
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
    /** Reattach a RESUME stream to a recently interrupted Library segment within this window. */
    val continueInterruptedWithinMs: Long = 10L * 60 * 1000,
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
    private val log: (String) -> Unit = {},
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
        var framesSinceMetaWrite: Int = 0,
    )

    private var current: OpenSegment? = null
    private var segmentCounter = 0

    /**
     * Process-lifetime in-memory index of segment metadata, keyed by id. The read source of truth;
     * the `*.meta.json` files are the durable mirror. Without this, `listSegments()`/`readMeta()`
     * re-list the directory and re-parse every sidecar from disk on every call — and they are
     * called constantly (diagnostics refresh, the UI durable reload, RESUME continuation lookups),
     * which makes launch and steady-state O(library)-file-reads and starves the app.
     *
     * Held as a copy-on-write immutable map reassigned wholesale, so a concurrent reader on the
     * background pool always observes a complete map (matching the store's existing lock-free
     * shared-`current` posture; a lost write self-heals on the next sidecar flush, and disk is
     * always authoritative). Entries mirror the last-flushed sidecar, so the open segment's live
     * counters appear on its periodic meta flush — the same visibility callers had when reads hit
     * disk.
     */
    private var metaIndex: Map<String, SegmentMeta>? = null

    /** Segment id of the currently open segment, or null. */
    val openSegmentId: String? get() = current?.meta?.segmentId

    // --- paths ----------------------------------------------------------------------------------

    private fun logPath(segmentId: String) = Path(segmentsDir, "$segmentId.spxlog")
    private fun metaPath(segmentId: String) = Path(segmentsDir, "$segmentId.meta.json")

    // --- SegmentSink ---------------------------------------------------------------------------

    override suspend fun openSegment(start: StreamStart, receivedAtMs: Long, provenance: SegmentProvenance?) {
        val resume = (start.flags and ProtocolConstants.STREAM_START_FLAG_RESUME) != 0u
        val open = current
        if (resume && open != null && open.meta.streamId == start.streamId) {
            if (canContinue(open.meta, start, provenance)) {
                // The live stream was re-announced without the phone ever seeing the segment
                // close (a receiver-side reattach after a transport blip). Keep appending to the
                // open segment; superseding it here would make reattachment impossible, because
                // only Interrupted segments are continuation candidates.
                return
            }
            log(
                "audio-companion: RESUME for open stream ${start.streamId} cannot continue in " +
                    "place (${describeContinueMismatch(open.meta, start, provenance)}); superseding",
            )
        }
        closeSegment(SegmentCloseReason.Superseded)
        if (tryContinueInterruptedSegment(start, receivedAtMs, provenance)) return
        openSegmentInternal(start, receivedAtMs, provenance)
    }

    private fun tryContinueInterruptedSegment(
        start: StreamStart,
        receivedAtMs: Long,
        provenance: SegmentProvenance?,
    ): Boolean {
        val resume = (start.flags and ProtocolConstants.STREAM_START_FLAG_RESUME) != 0u
        if (!resume) return false
        if (!fileSystem.exists(segmentsDir)) {
            log("audio-companion: RESUME for stream ${start.streamId} found no stored segments; opening a new segment")
            return false
        }
        val recentlyInterrupted = listSegments()
            .asReversed()
            .filter { meta ->
                val closedAt = meta.closedAtMs ?: return@filter false
                meta.closeReason?.kind == CloseReasonMeta.KIND_INTERRUPTED &&
                    receivedAtMs >= closedAt &&
                    receivedAtMs - closedAt <= config.continueInterruptedWithinMs
            }
        val candidate = recentlyInterrupted.firstOrNull { canContinue(it, start, provenance) }
        if (candidate == null) {
            // Every failed reattach becomes a new Library row, so always say why it failed.
            val reason = recentlyInterrupted.firstOrNull()
                ?.let { describeContinueMismatch(it, start, provenance) }
                ?: "no segment interrupted within ${config.continueInterruptedWithinMs} ms"
            log("audio-companion: RESUME for stream ${start.streamId} could not reattach ($reason); opening a new segment")
            return false
        }

        val continued = candidate.copy(
            closeReason = null,
            closedAtMs = null,
            // The segment is recording again, so any transcript made from its interrupted prefix
            // is stale. Reset to Pending; enqueueClosedSegments requeues the terminal queue task
            // after the final close (a terminal task would otherwise block re-transcription).
            transcriptionState = TranscriptionState.Pending,
        )
        writeMetaAtomically(continued)
        current = OpenSegment(
            meta = continued,
            sink = fileSystem.sink(logPath(continued.segmentId), append = true).buffered(),
            logBytes = logSizeBytes(continued.segmentId),
            // Keep the original rotation budget: a blip-prone stream that reattaches every few
            // minutes must still wall-rotate at 15 min from first open, matching the in-place
            // continuation path (which keeps its original OpenSegment).
            openedAtMs = candidate.receivedAtMs,
            start = start,
            provenance = provenance,
        )
        return true
    }

    /**
     * Stream identity for reattachment is the stream id plus the codec/protocol contract and
     * provenance. `startTimeMs`/`startMonotonicMs` are deliberately NOT compared: the watch
     * recomputed them at send time on every RESUME re-announcement (fixed in firmware to resend
     * the stream-birth values, but firmware already in the field still sends fresh ones), so
     * comparing them made reattachment structurally impossible — every transport blip minted a
     * new segment. The stored meta keeps the original stream-birth timestamps either way.
     */
    private fun canContinue(
        meta: SegmentMeta,
        start: StreamStart,
        provenance: SegmentProvenance?,
    ): Boolean =
        meta.streamId == start.streamId &&
            meta.protocolVersion == start.protocolVersion &&
            meta.codecIdRaw == start.codecIdRaw &&
            meta.channels == start.channels &&
            meta.frameSamples == start.frameSamples &&
            meta.sampleRateHz == start.sampleRateHz &&
            meta.bitRateBps == start.bitRateBps &&
            meta.frameDurationMs == start.frameDurationMs &&
            meta.provenance == provenance?.let {
                ProvenanceMeta(it.fwVersionPacked, it.protocolVersion)
            }

    /** Names the first field that blocks continuation, for the reattach-failure log line. */
    private fun describeContinueMismatch(
        meta: SegmentMeta,
        start: StreamStart,
        provenance: SegmentProvenance?,
    ): String {
        val expectedProvenance = provenance?.let { ProvenanceMeta(it.fwVersionPacked, it.protocolVersion) }
        return when {
            meta.streamId != start.streamId ->
                "streamId ${meta.streamId} != ${start.streamId}"
            meta.protocolVersion != start.protocolVersion ->
                "protocolVersion ${meta.protocolVersion} != ${start.protocolVersion}"
            meta.codecIdRaw != start.codecIdRaw ->
                "codecId ${meta.codecIdRaw} != ${start.codecIdRaw}"
            meta.channels != start.channels ->
                "channels ${meta.channels} != ${start.channels}"
            meta.frameSamples != start.frameSamples ->
                "frameSamples ${meta.frameSamples} != ${start.frameSamples}"
            meta.sampleRateHz != start.sampleRateHz ->
                "sampleRateHz ${meta.sampleRateHz} != ${start.sampleRateHz}"
            meta.bitRateBps != start.bitRateBps ->
                "bitRateBps ${meta.bitRateBps} != ${start.bitRateBps}"
            meta.frameDurationMs != start.frameDurationMs ->
                "frameDurationMs ${meta.frameDurationMs} != ${start.frameDurationMs}"
            meta.provenance != expectedProvenance ->
                "provenance ${meta.provenance} != $expectedProvenance"
            else -> "no field mismatch"
        }
    }

    private fun openSegmentInternal(
        start: StreamStart,
        receivedAtMs: Long,
        provenance: SegmentProvenance?,
        dedupeFloorSequence: UInt? = null,
    ) {
        fileSystem.createDirectories(segmentsDir)
        segmentCounter += 1
        val segmentId = "seg-$receivedAtMs-${start.streamId.toString(16).padStart(8, '0')}-$segmentCounter"
        // The StreamStart carries the stream-BIRTH wall clock, which can be 15 minutes (rotation
        // successor) to hours (RESUME outside the reattach window) old by the time a mid-stream
        // segment is minted. Anchor those at receive time so the timeline/recap files them when
        // they actually happened; only a segment that begins at the stream's birth keeps it.
        val resume = (start.flags and ProtocolConstants.STREAM_START_FLAG_RESUME) != 0u ||
            dedupeFloorSequence != null
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
            startTimeMs = if (resume) receivedAtMs.toULong() else start.startTimeMs,
            startMonotonicMs = start.startMonotonicMs,
            receivedAtMs = receivedAtMs,
            provenance = provenance?.let { ProvenanceMeta(it.fwVersionPacked, it.protocolVersion) },
            dedupeFloorSequence = dedupeFloorSequence,
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

    override suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>): List<SegmentFrame> {
        val segment = current ?: return emptyList()
        if (segment.meta.streamId != streamId) return emptyList()

        // A reattached stream rewinds its spool to the last checkpoint, so the first batches
        // after a RESUME can re-send frames already persisted here (the flushed-but-not-yet-
        // checkpointed tail). Drop those exact re-sends instead of appending duplicate audio —
        // EXCEPT frames that fall inside a recorded loss gap: the watch deliberately retained
        // those for exactly this recovery, so they are appended (out of file order; readFrames
        // sorts) and the gap record shrinks accordingly.
        val floor = segment.meta.lastSequence ?: segment.meta.dedupeFloorSequence
        val accepted = if (floor == null) {
            frames
        } else {
            frames.filter { f ->
                f.sequence > floor || segment.meta.gaps.any { it.containsSequence(f.sequence) }
            }
        }
        if (accepted.isEmpty()) return emptyList()

        val writer = WireWriter(accepted.sumOf { it.payload.size + RECORD_HEADER_BYTES })
        for (frame in accepted) {
            writer.u32(frame.sequence)
            writer.u64(frame.sampleIndex)
            writer.u16(frame.payload.size)
            writer.bytes(frame.payload)
        }
        val bytes = writer.toByteArray()
        segment.sink.write(bytes)
        segment.sink.flush() // durability point: the session checkpoints only what is flushed
        segment.logBytes += bytes.size

        val refilled = if (floor == null) emptyList() else accepted.filter { it.sequence <= floor }
        val newGaps = if (refilled.isEmpty()) {
            segment.meta.gaps
        } else {
            segment.meta.gaps.withRefilledSequences(
                refilled.map { it.sequence },
                segment.meta.frameSamples.toULong(),
            )
        }

        // Refills can land below the persisted range (a leading gap), so first* take minimums.
        val minSequence = accepted.minOf { it.sequence }
        val maxSequence = accepted.maxOf { it.sequence }
        val minSampleIndex = accepted.minOf { it.sampleIndex }
        val maxSampleEndExclusive = accepted.maxOf { it.sampleIndex } + segment.meta.frameSamples.toULong()
        segment.meta = segment.meta.copy(
            firstSequence = segment.meta.firstSequence?.let { minOf(it, minSequence) } ?: minSequence,
            lastSequence = segment.meta.lastSequence?.let { maxOf(it, maxSequence) } ?: maxSequence,
            firstSampleIndex = segment.meta.firstSampleIndex?.let { minOf(it, minSampleIndex) }
                ?: minSampleIndex,
            lastSampleIndexExclusive = maxOf(
                segment.meta.lastSampleIndexExclusive ?: 0u,
                maxSampleEndExclusive,
            ),
            frameCount = segment.meta.frameCount + accepted.size,
            logBytes = segment.logBytes,
            gaps = newGaps,
        )

        // Keep the on-disk meta fresh while recording: readers (UI durations/sizes, the live
        // transcript preview) only see the sidecar file, and without periodic writes an open
        // segment's frame counters would stay at their last gap/rotate values for minutes.
        // A gap refill flushes immediately, like recordGap does for the gap it shrinks.
        segment.framesSinceMetaWrite += accepted.size
        if (refilled.isNotEmpty() || segment.framesSinceMetaWrite >= OPEN_META_FLUSH_FRAMES) {
            segment.framesSinceMetaWrite = 0
            writeMetaAtomically(segment.meta)
        }

        maybeRotate(segment)
        return accepted
    }

    private fun GapMeta.containsSequence(sequence: UInt): Boolean =
        missingFrameCount > 0u &&
            sequence >= firstMissingSequence &&
            sequence.toULong() < endExclusive()

    /**
     * Subtracts refilled (re-delivered and now persisted) sequences from the recorded loss gaps,
     * splitting a gap when the refill covers its middle. [refilled] is ascending (frames within a
     * wire batch are consecutive); gaps keep their reason/origin metadata on both split halves.
     */
    private fun List<GapMeta>.withRefilledSequences(
        refilled: List<UInt>,
        frameSamples: ULong,
    ): List<GapMeta> {
        if (refilled.isEmpty()) return this
        // Collapse the refill list into maximal contiguous [start, endExclusive) runs.
        val runs = mutableListOf<Pair<ULong, ULong>>()
        var runStart = refilled.first().toULong()
        var previous = runStart
        for (sequence in refilled.drop(1).map { it.toULong() }) {
            if (sequence == previous + 1u) {
                previous = sequence
                continue
            }
            runs += runStart to previous + 1u
            runStart = sequence
            previous = sequence
        }
        runs += runStart to previous + 1u

        return flatMap { gap ->
            if (gap.missingFrameCount == 0u) return@flatMap listOf(gap)
            var pieces = listOf(gap.firstMissingSequence.toULong() to gap.endExclusive())
            for ((refillStart, refillEnd) in runs) {
                pieces = pieces.flatMap { (gapStart, gapEnd) ->
                    when {
                        refillEnd <= gapStart || refillStart >= gapEnd -> listOf(gapStart to gapEnd)
                        else -> buildList {
                            if (refillStart > gapStart) add(gapStart to refillStart)
                            if (refillEnd < gapEnd) add(refillEnd to gapEnd)
                        }
                    }
                }
            }
            pieces.map { (pieceStart, pieceEnd) ->
                gap.copy(
                    firstMissingSequence = pieceStart.toUInt(),
                    missingFrameCount = (pieceEnd - pieceStart).toUInt(),
                    firstMissingSampleIndex = gap.firstMissingSampleIndex +
                        (pieceStart - gap.firstMissingSequence.toULong()) * frameSamples,
                )
            }
        }
    }

    /**
     * Records genuinely-lost audio. A durable gap means audio the receiver could not recover: a
     * disconnection long enough that the watch's buffer overflowed, an explicit watch pause/
     * interruption, or a dropped notification. Two things keep `gaps` informative and sparse
     * instead of one record per dropped packet:
     *
     *  - Silence-suppressed spans are deliberately-skipped quiet, not lost audio, so they are
     *    never persisted as loss (the live waveform still renders them as quiet while active).
     *  - A loss overlapping or contiguous (in sequence) with the previous gap extends that record's
     *    total dropped duration rather than appending a new one — so one period of lost audio is one
     *    gap noting the total time, however many packets it spanned.
     */
    override suspend fun recordGap(streamId: UInt, gap: GapRecord) {
        val segment = current ?: return
        if (segment.meta.streamId != streamId) return
        val incoming = GapMeta.from(gap).takeIf { it.shouldPersistAsLoss() } ?: return
        val updated = segment.meta.gaps.withSparseLossGap(incoming)
        segment.meta = segment.meta.copy(gaps = updated)
        writeMetaAtomically(segment.meta)
    }

    private fun GapMeta.shouldPersistAsLoss(): Boolean =
        reasonRaw?.let { GapReason.fromRaw(it)?.isSilence } != true

    private fun List<GapMeta>.withSparseLossGap(incoming: GapMeta): List<GapMeta> {
        val last = lastOrNull()
        if (last == null || !last.shouldPersistAsLoss() || !last.overlapsOrTouches(incoming)) {
            return this + incoming
        }
        val mergedEnd = maxOf(last.endExclusive(), incoming.endExclusive())
        return dropLast(1) + last.copy(
            missingFrameCount = (mergedEnd - last.firstMissingSequence.toULong()).toUInt(),
            watchDropCounter = incoming.watchDropCounter ?: last.watchDropCounter,
        )
    }

    private fun GapMeta.overlapsOrTouches(next: GapMeta): Boolean =
        missingFrameCount > 0u &&
            next.missingFrameCount > 0u &&
            next.firstMissingSequence.toULong() <= endExclusive()

    private fun GapMeta.endExclusive(): ULong =
        firstMissingSequence.toULong() + missingFrameCount.toULong()

    override suspend fun closeSegment(reason: SegmentCloseReason) {
        closeSegmentInternal(CloseReasonMeta.from(reason))
    }

    private fun closeSegmentInternal(reason: CloseReasonMeta) {
        val segment = current ?: return
        current = null
        segment.sink.close()
        segment.meta = segment.meta.copy(closeReason = reason, closedAtMs = nowMs())
        writeMetaAtomically(segment.meta)
    }

    /** Rotation (plan 6.2): close at 15 min or 16 MB; the stream continues in a new segment. */
    private fun maybeRotate(segment: OpenSegment) {
        val tooOld = nowMs() - segment.openedAtMs >= config.rotateAfterMs
        val tooBig = segment.logBytes >= config.rotateAfterBytes
        if (!tooOld && !tooBig) return
        val start = segment.start
        val provenance = segment.provenance
        // The successor's dedupe floor: a post-RESUME rewind can re-send the predecessor's tail
        // (its own lastSequence is still null while empty), which must not be re-appended.
        val floor = segment.meta.lastSequence ?: segment.meta.dedupeFloorSequence
        closeSegmentInternal(CloseReasonMeta.Rotated)
        openSegmentInternal(start, nowMs(), provenance, dedupeFloorSequence = floor)
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
        // Keep the in-memory index coherent. No-op until the index is built (recover() rebuilds it
        // at the end, so reconcile-writes during recovery don't each trigger a disk scan).
        metaIndex?.let { metaIndex = it + (meta.segmentId to meta) }
    }

    /** Marks transcription progress for a closed segment (used by :core:transcription's queue). */
    fun updateTranscriptionState(segmentId: String, state: TranscriptionState) {
        val meta = readMeta(segmentId) ?: return
        writeMetaAtomically(meta.copy(transcriptionState = state))
        current?.let { if (it.meta.segmentId == segmentId) it.meta = it.meta.copy(transcriptionState = state) }
    }

    // --- reading ----------------------------------------------------------------------------------

    // Served from the index, which is the last-flushed sidecar state — identical to what reading
    // the on-disk `*.meta.json` returned before, just without the disk I/O. The open segment's
    // live counters become visible on its periodic meta flush, exactly as they did before.
    fun readMeta(segmentId: String): SegmentMeta? = ensureIndex()[segmentId]

    fun listSegments(): List<SegmentMeta> =
        ensureIndex().values.sortedBy { it.receivedAtMs }

    /** Lazily builds the metadata index from disk on first read (recover() rebuilds it explicitly). */
    private fun ensureIndex(): Map<String, SegmentMeta> =
        metaIndex ?: buildIndexFromDisk().also { metaIndex = it }

    private fun buildIndexFromDisk(): Map<String, SegmentMeta> {
        if (!fileSystem.exists(segmentsDir)) return emptyMap()
        val map = LinkedHashMap<String, SegmentMeta>()
        fileSystem.list(segmentsDir)
            .filter { it.name.endsWith(META_SUFFIX) }
            .forEach { path ->
                val id = path.name.removeSuffix(META_SUFFIX)
                readMetaFromDisk(id)?.let { map[id] = it.withNormalizedGaps() }
            }
        return map
    }

    private fun readMetaFromDisk(segmentId: String): SegmentMeta? {
        val path = metaPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SegmentMeta.serializer(), text) }.getOrNull()
    }

    private fun SegmentMeta.withNormalizedGaps(): SegmentMeta {
        val normalized = normalizeSparseLossGaps(gaps)
        return if (normalized == gaps) this else copy(gaps = normalized)
    }

    private fun normalizeSparseLossGaps(gaps: List<GapMeta>): List<GapMeta> {
        if (gaps.isEmpty()) return emptyList()
        val watchRanges = gaps.filter { it.origin == GapMeta.ORIGIN_WATCH && it.missingFrameCount > 0u }
        fun coveredByWatch(gap: GapMeta): Boolean =
            watchRanges.any { it.covers(gap) }

        val sorted = gaps.asSequence()
            .filter { it.shouldPersistAsLoss() }
            .filterNot { it.origin == GapMeta.ORIGIN_SEQUENCE_SKIP && coveredByWatch(it) }
            .sortedWith(
                compareBy<GapMeta> { it.firstMissingSequence.toULong() }
                    .thenBy { if (it.origin == GapMeta.ORIGIN_WATCH) 0 else 1 }
            )
            .toList()
        return sorted.fold(emptyList()) { acc, gap -> acc.withSparseLossGap(gap) }
    }

    private fun GapMeta.covers(other: GapMeta): Boolean =
        missingFrameCount > 0u &&
            other.missingFrameCount > 0u &&
            firstMissingSequence <= other.firstMissingSequence &&
            endExclusive() >= other.endExclusive()

    fun logSizeBytes(segmentId: String): Long =
        fileSystem.metadataOrNull(logPath(segmentId))?.size ?: 0L

    fun readFrames(segmentId: String): List<FrameRecord> {
        val path = logPath(segmentId)
        if (!fileSystem.exists(path)) return emptyList()
        val bytes = fileSystem.source(path).buffered().use { it.readByteArray() }
        // Gap refills append after later frames, so the log is not strictly ordered on disk;
        // every consumer (playback, waveform, transcription decode, export) wants stream order.
        return parseRecords(bytes).records.sortedBy { it.sequence }
    }

    fun deleteSegment(segmentId: String) {
        check(segmentId != openSegmentId) { "refusing to delete the open segment $segmentId" }
        fileSystem.delete(logPath(segmentId), mustExist = false)
        fileSystem.delete(metaPath(segmentId), mustExist = false)
        metaIndex = metaIndex?.minus(segmentId)
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
            val meta = readMetaFromDisk(segmentId)
            if (meta == null) {
                quarantine(log)
                continue
            }
            val logBytes = fileSystem.metadataOrNull(log)?.size ?: 0L
            if (!needsRecoveryParse(meta, logBytes)) {
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
            reconcileMeta(meta, parsed.records, parsed.validBytes.toLong())
        }
        normalizeGapSidecars()
        // Build the authoritative index once, after all reconcile-writes, so subsequent reads
        // (diagnostics, UI, RESUME continuation) never touch disk.
        metaIndex = buildIndexFromDisk()
    }

    private fun normalizeGapSidecars() {
        fileSystem.list(segmentsDir)
            .filter { it.name.endsWith(META_SUFFIX) }
            .forEach { path ->
                val segmentId = path.name.removeSuffix(META_SUFFIX)
                val meta = readMetaFromDisk(segmentId) ?: return@forEach
                val normalized = meta.withNormalizedGaps()
                if (normalized != meta) writeMetaAtomically(normalized)
            }
    }

    private fun needsRecoveryParse(meta: SegmentMeta, logBytes: Long): Boolean =
        // Open-at-crash segments need frame-log reconciliation so they become explicit
        // interrupted segments and their counters match the flushed durable audio.
        meta.closeReason == null ||
            // Closed segments normally wrote a final sidecar after the log closed. If the log size
            // still matches that sidecar, launch can trust the metadata instead of reparsing every
            // historical audio byte. Size drift means an append/truncate raced the final metadata
            // write, so we pay the parse cost and reconcile.
            meta.logBytes != logBytes

    private fun reconcileMeta(meta: SegmentMeta, records: List<FrameRecord>, logBytes: Long) {
        val reconciled = meta.copy(
            // min/max, not first/last: gap refills make the on-disk record order non-monotonic.
            firstSequence = records.minOfOrNull { it.sequence },
            lastSequence = records.maxOfOrNull { it.sequence },
            firstSampleIndex = records.minOfOrNull { it.sampleIndex },
            lastSampleIndexExclusive = records.maxOfOrNull { it.sampleIndex + meta.frameSamples.toULong() },
            frameCount = records.size.toLong(),
            logBytes = logBytes,
            // A meta still marked open means we died with the segment open: it was interrupted.
            closeReason = meta.closeReason ?: CloseReasonMeta.Interrupted,
            // Stamp the close time (recovery time is the best bound) — the RESUME reattach
            // window keys off closedAtMs, and a crash-interrupted segment must be able to
            // reattach when the watch re-announces after the app relaunches.
            closedAtMs = meta.closedAtMs ?: nowMs(),
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

        /** Flush the open segment's sidecar meta every ~5 s of audio (250 × 20 ms frames). */
        const val OPEN_META_FLUSH_FRAMES = 250
    }
}
