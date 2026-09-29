import Foundation
import WireProtocol

// Port of `core/storage/.../SegmentStore.kt` (line-by-line behavioral port; the KMP class was
// single-writer with suspend entry points — here the actor provides the same serialization).

/// One decoded frame-log record (same shape as a STREAM_DATA frame entry).
public struct FrameRecord: Equatable, Sendable {
    public let sequence: UInt32
    public let sampleIndex: UInt64
    public let payload: [UInt8]

    public init(sequence: UInt32, sampleIndex: UInt64, payload: [UInt8]) {
        self.sequence = sequence
        self.sampleIndex = sampleIndex
        self.payload = payload
    }
}

/// Refusals the store must never answer with a quiet no-op, because the receiver reads "nothing
/// happened" as "already durable" and checkpoints on it.
public enum SegmentStoreError: Error, Equatable {
    /// Frames or a gap arrived with no segment open to hold them.
    case noOpenSegment(streamId: UInt32)
    /// Frames or a gap arrived for a different stream than the open segment's.
    case streamMismatch(expected: UInt32, got: UInt32)
}

public struct SegmentStoreConfig: Sendable {
    /// Rotate the open segment after this much wall time (plan 6.2: 15 min).
    public var rotateAfterMs: Int64
    /// ... or after this many frame-log bytes (plan 6.2: 16 MB).
    public var rotateAfterBytes: Int64
    /// Reattach a RESUME stream to a recently interrupted Library segment within this window.
    public var continueInterruptedWithinMs: Int64

    public init(
        rotateAfterMs: Int64 = 15 * 60 * 1000,
        rotateAfterBytes: Int64 = 16 * 1024 * 1024,
        continueInterruptedWithinMs: Int64 = 10 * 60 * 1000
    ) {
        self.rotateAfterMs = rotateAfterMs
        self.rotateAfterBytes = rotateAfterBytes
        self.continueInterruptedWithinMs = continueInterruptedWithinMs
    }
}

/// File-backed segment storage (implementation plan Section 6.2, Decision E — encoded
/// retention). Layout under `root`:
///
/// - `segments/<segment_id>.spxlog` — append-only frame log of
///   `{u32 seq, u64 sample_index, u16 len, u8 speex[len]}` records, little-endian: the same
///   record shape as the firmware spool and the STREAM_DATA frame entry.
/// - `segments/<segment_id>.meta.json` — written via temp file + atomic rename.
/// - `quarantine/` — orphan files swept aside by `recover()`.
/// - `segments_index.json` — the recovery index: every sidecar as `recover()` last left it, with
///   the size and modification time of the sidecar and the size of its log. The next launch
///   trusts an entry only while both files are exactly as recorded, and reads everything else.
///   A cache, never the truth: absent, unreadable or stale, recovery reads the sidecars.
///
/// Single-writer: one receiver session drives it, matching ReceiverSession's sequential
/// message handling; the actor serializes cross-task reads.
public actor SegmentStore: SegmentSink {

    public static let logSuffix = ".spxlog"
    public static let metaSuffix = ".meta.json"

    /// u32 seq + u64 sample_index + u16 len.
    public static let recordHeaderBytes = 14

    /// Flush the open segment's sidecar meta every ~5 s of audio (250 × 20 ms frames).
    public static let openMetaFlushFrames = 250

    private let fm = FileManager.default
    private let root: URL
    private let nowMs: @Sendable () -> Int64
    private let config: SegmentStoreConfig
    private let log: @Sendable (String) -> Void

    private let segmentsDir: URL
    private let quarantineDir: URL

    private final class OpenSegment {
        var meta: SegmentMeta
        let handle: FileHandle
        var logBytes: Int64
        let openedAtMs: Int64
        let start: StreamStart
        let provenance: SegmentProvenance?
        var framesSinceMetaWrite: Int = 0

        init(
            meta: SegmentMeta,
            handle: FileHandle,
            logBytes: Int64,
            openedAtMs: Int64,
            start: StreamStart,
            provenance: SegmentProvenance?
        ) {
            self.meta = meta
            self.handle = handle
            self.logBytes = logBytes
            self.openedAtMs = openedAtMs
            self.start = start
            self.provenance = provenance
        }
    }

    private var current: OpenSegment?
    private var segmentCounter = 0

    /// Process-lifetime in-memory index of segment metadata, keyed by id. The read source of
    /// truth; the `*.meta.json` files are the durable mirror. Without this, `listSegments()`/
    /// `readMeta()` re-list the directory and re-parse every sidecar from disk on every call —
    /// and they are called constantly (diagnostics refresh, the UI durable reload, RESUME
    /// continuation lookups), which makes launch and steady-state O(library)-file-reads and
    /// starves the app. Nil until first built (lazily on first read, or by `recover()`).
    private var metaIndex: [String: SegmentMeta]?

    public init(
        root: URL,
        nowMs: @escaping @Sendable () -> Int64,
        config: SegmentStoreConfig = SegmentStoreConfig(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.root = root
        self.nowMs = nowMs
        self.config = config
        self.log = log
        self.segmentsDir = root.appendingPathComponent("segments", isDirectory: true)
        self.quarantineDir = root.appendingPathComponent("quarantine", isDirectory: true)
    }

    /// Segment id of the currently open segment, or nil.
    public var openSegmentId: String? { current?.meta.segmentId }

    // --- paths --------------------------------------------------------------------------------

    private func logURL(_ segmentId: String) -> URL {
        segmentsDir.appendingPathComponent("\(segmentId)\(Self.logSuffix)", isDirectory: false)
    }

    private func metaURL(_ segmentId: String) -> URL {
        segmentsDir.appendingPathComponent("\(segmentId)\(Self.metaSuffix)", isDirectory: false)
    }

    // --- SegmentSink --------------------------------------------------------------------------

    public func openSegment(
        start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?
    ) throws {
        let resume = (start.flags & ProtocolConstants.streamStartFlagResume) != 0
        if resume, let open = current, open.meta.streamId == start.streamId {
            if canContinue(open.meta, start: start, provenance: provenance) {
                // The live stream was re-announced without the phone ever seeing the segment
                // close (a receiver-side reattach after a transport blip). Keep appending to the
                // open segment; superseding it here would make reattachment impossible, because
                // only Interrupted segments are continuation candidates.
                return
            }
            log(
                "audio-companion: RESUME for open stream \(start.streamId) cannot continue in "
                    + "place (\(describeContinueMismatch(open.meta, start: start, provenance: provenance))); superseding"
            )
        }
        try closeSegmentInternal(.from(.superseded))
        if try tryContinueInterruptedSegment(
            start: start, receivedAtMs: receivedAtMs, provenance: provenance
        ) { return }
        try openSegmentInternal(start: start, receivedAtMs: receivedAtMs, provenance: provenance)
    }

    private func tryContinueInterruptedSegment(
        start: StreamStart,
        receivedAtMs: Int64,
        provenance: SegmentProvenance?
    ) throws -> Bool {
        let resume = (start.flags & ProtocolConstants.streamStartFlagResume) != 0
        if !resume { return false }
        if !fm.fileExists(atPath: segmentsDir.path) {
            log(
                "audio-companion: RESUME for stream \(start.streamId) found no stored segments; "
                    + "opening a new segment")
            return false
        }
        let recentlyInterrupted = listSegments().reversed().filter { meta -> Bool in
            guard let closedAt = meta.closedAtMs else { return false }
            return meta.closeReason?.kind == CloseReasonMeta.kindInterrupted
                && receivedAtMs >= closedAt
                && receivedAtMs - closedAt <= config.continueInterruptedWithinMs
        }
        guard
            let candidate = recentlyInterrupted.first(where: {
                canContinue($0, start: start, provenance: provenance)
            })
        else {
            // Every failed reattach becomes a new Library row, so always say why it failed.
            let reason = recentlyInterrupted.first
                .map { describeContinueMismatch($0, start: start, provenance: provenance) }
                ?? "no segment interrupted within \(config.continueInterruptedWithinMs) ms"
            log(
                "audio-companion: RESUME for stream \(start.streamId) could not reattach "
                    + "(\(reason)); opening a new segment")
            return false
        }

        var continued = candidate
        continued.closeReason = nil
        continued.closedAtMs = nil
        // The segment is recording again, so any transcript made from its interrupted prefix
        // is stale. Reset to Pending; enqueueClosedSegments requeues the terminal queue task
        // after the final close (a terminal task would otherwise block re-transcription).
        continued.transcriptionState = .pending
        try writeMetaAtomically(continued)
        current = OpenSegment(
            meta: continued,
            handle: try openLogForAppend(continued.segmentId),
            logBytes: logSizeBytes(continued.segmentId),
            // Keep the original rotation budget: a blip-prone stream that reattaches every few
            // minutes must still wall-rotate at 15 min from first open, matching the in-place
            // continuation path (which keeps its original OpenSegment).
            openedAtMs: candidate.receivedAtMs,
            start: start,
            provenance: provenance
        )
        return true
    }

    /// Stream identity for reattachment is the stream id plus the codec/protocol contract and
    /// provenance. `startTimeMs`/`startMonotonicMs` are deliberately NOT compared: the watch
    /// recomputed them at send time on every RESUME re-announcement (fixed in firmware to resend
    /// the stream-birth values, but firmware already in the field still sends fresh ones), so
    /// comparing them made reattachment structurally impossible — every transport blip minted a
    /// new segment. The stored meta keeps the original stream-birth timestamps either way.
    private func canContinue(
        _ meta: SegmentMeta,
        start: StreamStart,
        provenance: SegmentProvenance?
    ) -> Bool {
        meta.streamId == start.streamId
            && meta.protocolVersion == start.protocolVersion
            && meta.codecIdRaw == start.codecIdRaw
            && meta.channels == start.channels
            && meta.frameSamples == start.frameSamples
            && meta.sampleRateHz == start.sampleRateHz
            && meta.bitRateBps == start.bitRateBps
            && meta.frameDurationMs == start.frameDurationMs
            && meta.provenance == provenance.map {
                ProvenanceMeta(fwVersionPacked: $0.fwVersionPacked, protocolVersion: $0.protocolVersion)
            }
    }

    /// Names the first field that blocks continuation, for the reattach-failure log line.
    private func describeContinueMismatch(
        _ meta: SegmentMeta,
        start: StreamStart,
        provenance: SegmentProvenance?
    ) -> String {
        let expectedProvenance = provenance.map {
            ProvenanceMeta(fwVersionPacked: $0.fwVersionPacked, protocolVersion: $0.protocolVersion)
        }
        switch true {
        case meta.streamId != start.streamId:
            return "streamId \(meta.streamId) != \(start.streamId)"
        case meta.protocolVersion != start.protocolVersion:
            return "protocolVersion \(meta.protocolVersion) != \(start.protocolVersion)"
        case meta.codecIdRaw != start.codecIdRaw:
            return "codecId \(meta.codecIdRaw) != \(start.codecIdRaw)"
        case meta.channels != start.channels:
            return "channels \(meta.channels) != \(start.channels)"
        case meta.frameSamples != start.frameSamples:
            return "frameSamples \(meta.frameSamples) != \(start.frameSamples)"
        case meta.sampleRateHz != start.sampleRateHz:
            return "sampleRateHz \(meta.sampleRateHz) != \(start.sampleRateHz)"
        case meta.bitRateBps != start.bitRateBps:
            return "bitRateBps \(meta.bitRateBps) != \(start.bitRateBps)"
        case meta.frameDurationMs != start.frameDurationMs:
            return "frameDurationMs \(meta.frameDurationMs) != \(start.frameDurationMs)"
        case meta.provenance != expectedProvenance:
            return "provenance \(String(describing: meta.provenance)) != \(String(describing: expectedProvenance))"
        default:
            return "no field mismatch"
        }
    }

    private func openSegmentInternal(
        start: StreamStart,
        receivedAtMs: Int64,
        provenance: SegmentProvenance?,
        dedupeFloorSequence: UInt32? = nil
    ) throws {
        try fm.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        segmentCounter += 1
        let segmentId = "seg-\(receivedAtMs)-\(String(format: "%08x", start.streamId))-\(segmentCounter)"
        // `startTimeMs` anchors SAMPLE INDEX 0 of the stream — it is half of a pair, and the other
        // half is `firstSampleIndex`. The wall clock of any sample is
        // `startTimeMs + sampleIndex·1000/rate`, and the firmware guarantees it: it captures the
        // birth clock once in `prv_begin_stream_locked()`, resends it verbatim on every RESUME
        // re-announcement, and advances the sample counter through pauses (`elapsed_ms / 20`) so
        // the counter stays a wall clock. Measured against Roger's 88-day export, the 598 segments
        // that kept the firmware's value land within ±32 s of their own `receivedAtMs`.
        //
        // This used to re-anchor mid-stream segments at receive time, reasoning that a birth clock
        // "15 minutes (rotation successor) to hours (RESUME) old" filed them under the wrong time.
        // That broke the pair: it moved `startTimeMs` forward while leaving `firstSampleIndex`
        // counted from birth, so the whole elapsed stream got added twice and the segment landed
        // that far in the FUTURE. In the same export it hit 169 segments; 91 of them were more
        // than a minute ahead of their own arrival, 413 h of phantom shift in total, worst case
        // +24.4 h — which is the "segments hours in the future" that
        // `ConversationGrouper.segmentStartMs` clamps against, and the reason
        // `CoverageComputer`'s sample→wall mapping put whole recordings on the wrong day.
        // Rotation is the common case, not the rare one: every 15-minute successor took it, so the
        // error grew with the age of the stream.
        //
        // So keep the wire value verbatim and let the pair stay self-consistent. A segment's own
        // start is `SegmentMeta.startWallMs` (= startTimeMs + firstSampleIndex, clamped by
        // receivedAtMs), which is what every consumer wants and is now correct by construction.
        let meta = SegmentMeta(
            segmentId: segmentId,
            streamId: start.streamId,
            protocolVersion: start.protocolVersion,
            codecIdRaw: start.codecIdRaw,
            channels: start.channels,
            frameSamples: start.frameSamples,
            sampleRateHz: start.sampleRateHz,
            bitRateBps: start.bitRateBps,
            frameDurationMs: start.frameDurationMs,
            startTimeMs: start.startTimeMs,
            startMonotonicMs: start.startMonotonicMs,
            receivedAtMs: receivedAtMs,
            provenance: provenance.map {
                ProvenanceMeta(fwVersionPacked: $0.fwVersionPacked, protocolVersion: $0.protocolVersion)
            },
            dedupeFloorSequence: dedupeFloorSequence
        )
        try writeMetaAtomically(meta)
        current = OpenSegment(
            meta: meta,
            handle: try openLogForAppend(segmentId),
            logBytes: 0,
            openedAtMs: nowMs(),
            start: start,
            provenance: provenance
        )
    }

    private func openLogForAppend(_ segmentId: String) throws -> FileHandle {
        let url = logURL(segmentId)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    public func appendFrames(streamId: UInt32, frames: [SegmentFrame]) throws -> [SegmentFrame] {
        // Fail LOUD, not empty. Returning `[]` here reads to the caller exactly like "all of this
        // was already persisted" (the ordinary post-RESUME dedupe result), so a session whose
        // segment was closed behind its back went on checkpointing audio that reached no disk —
        // and a checkpoint is what frees the watch's copy. There is no legitimate way to reach
        // this: a segment is opened and closed only through this sink, and rotation opens the
        // successor before returning. Throwing fails the connection, which forces a resync and
        // a fresh STREAM_START, so the watch redelivers everything it still holds.
        guard let segment = current else {
            throw SegmentStoreError.noOpenSegment(streamId: streamId)
        }
        if segment.meta.streamId != streamId {
            throw SegmentStoreError.streamMismatch(
                expected: segment.meta.streamId, got: streamId)
        }

        // A reattached stream rewinds its spool to the last checkpoint, so the first batches
        // after a RESUME can re-send frames already persisted here (the flushed-but-not-yet-
        // checkpointed tail). Drop those exact re-sends instead of appending duplicate audio —
        // EXCEPT frames that fall inside a recorded loss gap: the watch deliberately retained
        // those for exactly this recovery, so they are appended (out of file order; readFrames
        // sorts) and the gap record shrinks accordingly.
        let floor = segment.meta.lastSequence ?? segment.meta.dedupeFloorSequence
        let accepted: [SegmentFrame]
        if let floor {
            accepted = frames.filter { f in
                f.sequence > floor || segment.meta.gaps.contains { $0.containsSequence(f.sequence) }
            }
        } else {
            accepted = frames
        }
        if accepted.isEmpty { return [] }

        var writer = WireWriter(
            initialCapacity: accepted.reduce(0) { $0 + $1.payload.count + Self.recordHeaderBytes })
        for frame in accepted {
            writer.u32(frame.sequence)
            writer.u64(frame.sampleIndex)
            writer.u16(frame.payload.count)
            writer.bytes(frame.payload)
        }
        let bytes = writer.toData()
        try segment.handle.write(contentsOf: bytes)
        // Deliberately NOT fsynced here. This ran on every STREAM_DATA batch — about seven times a
        // second while the watch is streaming — and an fsync is a real flash write that blocks the
        // caller. It was the single most expensive thing on the receive path, and it was buying a
        // guarantee nothing needed at that granularity.
        //
        // The invariant is "the session checkpoints only what is flushed", and the CHECKPOINT is
        // the only thing that authorizes the watch to free its spool. So the flush belongs
        // immediately before the checkpoint, not after every append: anything written but not yet
        // flushed is still held on the watch, and a crash re-receives it on the next RESUME. The
        // durability story is unchanged; only the number of flash writes is.
        dirtyBytes += bytes.count
        segment.logBytes += Int64(bytes.count)

        let refilled: [SegmentFrame]
        if let floor {
            refilled = accepted.filter { $0.sequence <= floor }
        } else {
            refilled = []
        }
        let newGaps: [GapMeta]
        if refilled.isEmpty {
            newGaps = segment.meta.gaps
        } else {
            newGaps = withRefilledSequences(
                segment.meta.gaps,
                refilled: refilled.map(\.sequence),
                frameSamples: UInt64(segment.meta.frameSamples)
            )
        }

        // Refills can land below the persisted range (a leading gap), so first* take minimums.
        let minSequence = accepted.map(\.sequence).min()!
        let maxSequence = accepted.map(\.sequence).max()!
        let minSampleIndex = accepted.map(\.sampleIndex).min()!
        let maxSampleEndExclusive =
            accepted.map(\.sampleIndex).max()! + UInt64(segment.meta.frameSamples)
        segment.meta.firstSequence = segment.meta.firstSequence.map { min($0, minSequence) } ?? minSequence
        segment.meta.lastSequence = segment.meta.lastSequence.map { max($0, maxSequence) } ?? maxSequence
        segment.meta.firstSampleIndex =
            segment.meta.firstSampleIndex.map { min($0, minSampleIndex) } ?? minSampleIndex
        segment.meta.lastSampleIndexExclusive = max(
            segment.meta.lastSampleIndexExclusive ?? 0, maxSampleEndExclusive)
        segment.meta.frameCount += Int64(accepted.count)
        segment.meta.logBytes = segment.logBytes
        segment.meta.gaps = newGaps

        // Keep the on-disk meta fresh while recording: readers (UI durations/sizes, the live
        // transcript preview) only see the sidecar file, and without periodic writes an open
        // segment's frame counters would stay at their last gap/rotate values for minutes.
        // A gap refill flushes immediately, like recordGap does for the gap it shrinks.
        segment.framesSinceMetaWrite += accepted.count
        if !refilled.isEmpty || segment.framesSinceMetaWrite >= Self.openMetaFlushFrames {
            segment.framesSinceMetaWrite = 0
            try writeMetaAtomically(segment.meta)
        }

        try maybeRotate(segment)
        return accepted
    }

    /// Subtracts refilled (re-delivered and now persisted) sequences from the recorded loss gaps,
    /// splitting a gap when the refill covers its middle. `refilled` is ascending (frames within a
    /// wire batch are consecutive); gaps keep their reason/origin metadata on both split halves.
    private func withRefilledSequences(
        _ gaps: [GapMeta],
        refilled: [UInt32],
        frameSamples: UInt64
    ) -> [GapMeta] {
        guard let firstRefilled = refilled.first else { return gaps }
        // Collapse the refill list into maximal contiguous [start, endExclusive) runs.
        var runs: [(UInt64, UInt64)] = []
        var runStart = UInt64(firstRefilled)
        var previous = runStart
        for sequence in refilled.dropFirst().map({ UInt64($0) }) {
            if sequence == previous + 1 {
                previous = sequence
                continue
            }
            runs.append((runStart, previous + 1))
            runStart = sequence
            previous = sequence
        }
        runs.append((runStart, previous + 1))

        return gaps.flatMap { gap -> [GapMeta] in
            if gap.missingFrameCount == 0 { return [gap] }
            var pieces: [(UInt64, UInt64)] = [(UInt64(gap.firstMissingSequence), gap.endExclusive)]
            for (refillStart, refillEnd) in runs {
                pieces = pieces.flatMap { piece -> [(UInt64, UInt64)] in
                    let (gapStart, gapEnd) = piece
                    if refillEnd <= gapStart || refillStart >= gapEnd { return [(gapStart, gapEnd)] }
                    var kept: [(UInt64, UInt64)] = []
                    if refillStart > gapStart { kept.append((gapStart, refillStart)) }
                    if refillEnd < gapEnd { kept.append((refillEnd, gapEnd)) }
                    return kept
                }
            }
            return pieces.map { piece -> GapMeta in
                let (pieceStart, pieceEnd) = piece
                var copy = gap
                copy.firstMissingSequence = UInt32(pieceStart)
                copy.missingFrameCount = UInt32(pieceEnd - pieceStart)
                copy.firstMissingSampleIndex =
                    gap.firstMissingSampleIndex
                    + (pieceStart - UInt64(gap.firstMissingSequence)) * frameSamples
                return copy
            }
        }
    }

    /// Records genuinely-lost audio. A durable gap means audio the receiver could not recover: a
    /// disconnection long enough that the watch's buffer overflowed, an explicit watch pause/
    /// interruption, or a dropped notification.
    ///
    ///  - Silence-suppressed spans are deliberately-skipped quiet, not lost audio, so they are
    ///    never persisted as loss (the live waveform still renders them as quiet while active).
    ///  - The record joins the list in SEQUENCE order, whatever order it arrived in, and merges
    ///   only with what it really overlaps — see `normalizedSegmentGaps`.
    public func recordGap(streamId: UInt32, gap: GapRecord) throws {
        // Same reasoning as `appendFrames`: a gap that lands nowhere is loss with no record of
        // it, which is the one thing this product promises never to do quietly.
        guard let segment = current else {
            throw SegmentStoreError.noOpenSegment(streamId: streamId)
        }
        if segment.meta.streamId != streamId {
            throw SegmentStoreError.streamMismatch(
                expected: segment.meta.streamId, got: streamId)
        }
        let incoming = GapMeta.from(gap)
        guard incoming.shouldPersistAsLoss else { return }
        // THE WHOLE LIST, not its tail. This used to compare the incoming record with the LAST
        // stored one only, and "merged" whenever the incoming range started before that one's
        // end — without ever moving the start back. A record that arrived out of order was
        // therefore swallowed: its frames vanished from the list while the reply said it was
        // stored. That is the ordinary shape of a RESUME, not an edge case: the watch's held gap
        // notices are recorded first, and the hole BELOW them is only seen when the buffered
        // audio arrives. On 2026-09-24 17:37 seven held overflow records went in, the receiver's
        // sequence skip for 11975590..11976422 followed, and the 352 frames between the overflow
        // records were left with no record at all. Across the 858 sidecars of the 2026-09-29
        // backup only 15 sequence-skip records survived.
        segment.meta.gaps = normalizedSegmentGaps(
            segment.meta.gaps + [incoming], frameSamples: segment.meta.frameSamples)
        try writeMetaAtomically(segment.meta)
    }

    public func closeSegment(reason: SegmentCloseReason) throws {
        try closeSegmentInternal(.from(reason))
    }

    private func closeSegmentInternal(_ reason: CloseReasonMeta) throws {
        guard let segment = current else { return }
        current = nil
        // Appends are not fsynced individually, so a closing segment gets one final flush. Closes
        // happen on rotation (15 min / 16 MB) and on teardown, so this costs nothing.
        try? segment.handle.synchronize()
        dirtyBytes = 0
        try segment.handle.close()
        segment.meta.closeReason = reason
        segment.meta.closedAtMs = nowMs()
        try writeMetaAtomically(segment.meta)
    }

    /// Rotation (plan 6.2): close at 15 min or 16 MB; the stream continues in a new segment.
    private func maybeRotate(_ segment: OpenSegment) throws {
        let tooOld = nowMs() - segment.openedAtMs >= config.rotateAfterMs
        let tooBig = segment.logBytes >= config.rotateAfterBytes
        if !tooOld && !tooBig { return }
        let start = segment.start
        let provenance = segment.provenance
        // The successor's dedupe floor: a post-RESUME rewind can re-send the predecessor's tail
        // (its own lastSequence is still nil while empty), which must not be re-appended.
        let floor = segment.meta.lastSequence ?? segment.meta.dedupeFloorSequence
        try closeSegmentInternal(.rotated)
        try openSegmentInternal(
            start: start, receivedAtMs: nowMs(), provenance: provenance, dedupeFloorSequence: floor)
    }

    // --- meta persistence ---------------------------------------------------------------------

    private func writeMetaAtomically(_ meta: SegmentMeta) throws {
        try fm.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        let final = metaURL(meta.segmentId)
        let tmp = segmentsDir.appendingPathComponent("\(meta.segmentId)\(Self.metaSuffix).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: tmp)
        try atomicMove(from: tmp, to: final)
        // Keep the in-memory index coherent. No-op until the index is built (recover() rebuilds it
        // at the end, so reconcile-writes during recovery don't each trigger a disk scan).
        if metaIndex != nil { metaIndex![meta.segmentId] = meta }
    }

    /// Marks transcription progress for a closed segment (used by the transcription queue).
    public func updateTranscriptionState(_ segmentId: String, _ state: TranscriptionState) throws {
        guard var meta = readMeta(segmentId) else { return }
        meta.transcriptionState = state
        try writeMetaAtomically(meta)
        if let segment = current, segment.meta.segmentId == segmentId {
            segment.meta.transcriptionState = state
        }
    }

    // --- reading ------------------------------------------------------------------------------

    // Served from the index, which is the last-flushed sidecar state — identical to what reading
    // the on-disk `*.meta.json` returned before, just without the disk I/O. The open segment's
    // live counters become visible on its periodic meta flush, exactly as they did before.
    public func readMeta(_ segmentId: String) -> SegmentMeta? { ensureIndex()[segmentId] }

    public func listSegments() -> [SegmentMeta] {
        ensureIndex().values.sorted { a, b in
            if a.receivedAtMs != b.receivedAtMs { return a.receivedAtMs < b.receivedAtMs }
            return a.segmentId < b.segmentId
        }
    }

    /// Lazily builds the metadata index from disk on first read (recover() rebuilds it explicitly).
    private func ensureIndex() -> [String: SegmentMeta] {
        if let metaIndex { return metaIndex }
        let built = buildIndexFromDisk()
        metaIndex = built
        return built
    }

    /// Read-only. Trusts the recovery index for every segment whose files are exactly as it
    /// recorded them and reads the sidecars of the rest; never writes anything.
    private func buildIndexFromDisk() -> [String: SegmentMeta] {
        guard fm.fileExists(atPath: segmentsDir.path) else { return [:] }
        let scan = scanSegmentsDirectory()
        let cached = loadRecoveryIndex()
        var map: [String: SegmentMeta] = [:]
        for (id, stamp) in scan.metas {
            if let entry = cached?.entries[id], entry.metaStamp == stamp,
                entry.logBytes == scan.logs[id]
            {
                map[id] = entry.meta
                continue
            }
            if let meta = readMetaFromDisk(id) {
                map[id] = withNormalizedGaps(meta)
            }
        }
        return map
    }

    private func listDirectory(_ dir: URL) -> [URL] {
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readMetaFromDisk(_ segmentId: String) -> SegmentMeta? {
        let url = metaURL(segmentId)
        guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SegmentMeta.self, from: data)
    }

    private func withNormalizedGaps(_ meta: SegmentMeta) -> SegmentMeta {
        let normalized = normalizedSegmentGaps(meta.gaps, frameSamples: meta.frameSamples)
        if normalized == meta.gaps { return meta }
        var copy = meta
        copy.gaps = normalized
        return copy
    }

    public func logSizeBytes(_ segmentId: String) -> Int64 {
        let attrs = try? fm.attributesOfItem(atPath: logURL(segmentId).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func readFrames(_ segmentId: String) -> [FrameRecord] {
        let url = logURL(segmentId)
        guard fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else {
            return []
        }
        // Gap refills append after later frames, so the log is not strictly ordered on disk;
        // every consumer (playback, waveform, transcription decode, export) wants stream order.
        return parseRecords([UInt8](data)).records.sorted { $0.sequence < $1.sequence }
    }

    public func deleteSegment(_ segmentId: String) throws {
        precondition(segmentId != openSegmentId, "refusing to delete the open segment \(segmentId)")
        try removeIfExists(logURL(segmentId))
        try removeIfExists(metaURL(segmentId))
        metaIndex?[segmentId] = nil
    }

    private func removeIfExists(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // --- corruption recovery ------------------------------------------------------------------

    /// Validates the on-disk state (plan 6.2): leftover temp files are removed, frame logs with
    /// invalid framing are truncated at the first bad record, metas are reconciled with their log
    /// (open segments become interrupted), and orphan logs are swept to `quarantine/`.
    /// Call once on startup before opening new segments.
    /// Bytes appended since the last fsync. Only ever read to decide whether a flush has work.
    private var dirtyBytes = 0

    /// Forces appended frames to durable storage. Called by the receiver just before it sends a
    /// CHECKPOINT — see `appendFrames` for why that is the right place and the only place.
    public func flush() throws {
        guard dirtyBytes > 0, let segment = current else { return }
        try segment.handle.synchronize()
        dirtyBytes = 0
    }

    public func recover() throws {
        // Reconcile rather than trap.
        //
        // This was `precondition(current == nil, ...)`, which is a hard crash in release builds
        // too. The intended order does hold — `CompanionRuntime.start()` awaits recovery before
        // starting the receiver — but `AppLifecycleCoordinator` is a REENTRANT actor driven by two
        // independently dispatched tasks: `.didFinishLaunching` from the composition root and
        // `.didBecomeActive` from a notification observer. While the first is suspended inside
        // `recoverStore()`, the second is free to run and calls `receiver.start()`, which can open
        // a segment before this function has finished. The invariant was incidental, not enforced,
        // and the penalty for losing the race was a launch crash.
        //
        // Closing the open segment as interrupted is exactly what recovery does for an
        // open-at-crash segment anyway, so this costs nothing and removes the trap.
        if current != nil {
            try closeSegment(reason: .interrupted)
        }
        guard fm.fileExists(atPath: segmentsDir.path) else { return }

        // ONE pass over the directory, and the sidecars of unchanged segments are not read at all.
        //
        // This used to read and decode every sidecar three times — the reconcile loop,
        // `normalizeGapSidecars`, then `buildIndexFromDisk` — and `stat` every log through
        // `attributesOfItem`. It is the one step the receiver waits for on every launch, while the
        // watch's ~6 s spool has nobody to send to; over the phone's 1,344 segments it measured
        // 0.6 s on a Mac and 1.6-3.7 s on the phone when nothing else was wrong. Now: one directory
        // listing that carries sizes and modification dates, and the recovery index written by the
        // previous launch. A segment whose sidecar and log are byte-for-byte as that index recorded
        // them, and which was closed then, cannot need reconciling — its meta comes from the index.
        // Everything else (a new segment, the one open at the crash, anything rewritten since, a
        // launch with no index) is read and repaired exactly as before.
        let scan = scanSegmentsDirectory()
        // Leftover atomic-write temps: the final file either exists (rename happened) or the
        // write never completed; either way the temp is garbage.
        for tmp in scan.temps { try removeIfExists(tmp) }

        let cached = loadRecoveryIndex()
        var index: [String: SegmentMeta] = [:]
        var entries: [String: RecoveryIndex.Entry] = [:]
        var trusted = 0

        for id in scan.logs.keys.sorted() {
            let logBytes = scan.logs[id]!
            guard let stamp = scan.metas[id] else {
                try quarantine(logURL(id))
                continue
            }
            if let entry = cached?.entries[id], entry.meta.closeReason != nil,
                entry.metaStamp == stamp, entry.logBytes == logBytes
            {
                index[id] = entry.meta
                entries[id] = entry
                trusted += 1
                continue
            }
            guard let meta = readMetaFromDisk(id) else {
                try quarantine(logURL(id))
                continue
            }
            var reconciled = meta
            var finalLogBytes = logBytes
            if needsRecoveryParse(meta, logBytes: logBytes) {
                let logFile = logURL(id)
                let bytes = [UInt8]((try? Data(contentsOf: logFile)) ?? Data())
                let parsed = parseRecords(bytes)
                if parsed.validBytes < bytes.count {
                    // Truncate at the first bad record via temp + atomic rename.
                    let tmp = segmentsDir.appendingPathComponent("\(id)\(Self.logSuffix).tmp")
                    try Data(bytes[0..<parsed.validBytes]).write(to: tmp)
                    try atomicMove(from: tmp, to: logFile)
                }
                finalLogBytes = Int64(parsed.validBytes)
                reconciled = reconciledMeta(meta, records: parsed.records, logBytes: finalLogBytes)
            }
            reconciled = withNormalizedGaps(reconciled)
            var metaStamp = stamp
            if reconciled != meta {
                try writeMetaAtomically(reconciled)
                metaStamp = stampOf(metaURL(id)) ?? stamp
            }
            index[id] = reconciled
            entries[id] = RecoveryIndex.Entry(
                meta: reconciled, metaStamp: metaStamp, logBytes: finalLogBytes)
        }

        // Sidecars with no log. A meta is written BEFORE its log is created, so a crash between
        // the two leaves a sidecar describing nothing — and the real device had three. They are
        // not harmless: they appear in `listSegments`, so the Library shows a recording with no
        // audio, and until the caller filtered on `frameCount` they were enqueued for
        // transcription, where the task could only fail, exhaust its retries and sit in
        // Diagnostics forever.
        //
        // Only the ones recording ZERO frames are removed, which is provably lossless — the
        // sidecar describes no audio, so there is nothing to lose. A sidecar that claims frames
        // whose log has gone is a genuine loss and is deliberately KEPT: the audio is already
        // gone, and deleting the record of it would turn a visible gap into a silent one, which
        // this product does not do.
        for id in scan.metas.keys.sorted() where scan.logs[id] == nil {
            let stamp = scan.metas[id]!
            if let entry = cached?.entries[id], entry.logBytes == nil, entry.metaStamp == stamp {
                index[id] = entry.meta
                entries[id] = entry
                trusted += 1
                continue
            }
            guard let meta = readMetaFromDisk(id) else { continue }
            if meta.frameCount == 0 {
                try removeIfExists(metaURL(id))
                continue
            }
            let normalized = withNormalizedGaps(meta)
            var metaStamp = stamp
            if normalized != meta {
                try writeMetaAtomically(normalized)
                metaStamp = stampOf(metaURL(id)) ?? stamp
            }
            index[id] = normalized
            entries[id] = RecoveryIndex.Entry(meta: normalized, metaStamp: metaStamp, logBytes: nil)
        }

        metaIndex = index
        log("recover: \(index.count) segment(s), \(trusted) from the index, \(index.count - trusted) read")
        saveRecoveryIndex(RecoveryIndex(entries: entries))
    }

    private func needsRecoveryParse(_ meta: SegmentMeta, logBytes: Int64) -> Bool {
        // Open-at-crash segments need frame-log reconciliation so they become explicit
        // interrupted segments and their counters match the flushed durable audio.
        meta.closeReason == nil
            // Closed segments normally wrote a final sidecar after the log closed. If the log size
            // still matches that sidecar, launch can trust the metadata instead of reparsing every
            // historical audio byte. Size drift means an append/truncate raced the final metadata
            // write, so we pay the parse cost and reconcile.
            || meta.logBytes != logBytes
    }

    /// The sidecar a log's records say it should be. Pure; the caller writes it if it differs.
    private func reconciledMeta(_ meta: SegmentMeta, records: [FrameRecord], logBytes: Int64) -> SegmentMeta {
        var reconciled = meta
        // min/max, not first/last: gap refills make the on-disk record order non-monotonic.
        reconciled.firstSequence = records.map(\.sequence).min()
        reconciled.lastSequence = records.map(\.sequence).max()
        reconciled.firstSampleIndex = records.map(\.sampleIndex).min()
        reconciled.lastSampleIndexExclusive =
            records.map { $0.sampleIndex + UInt64(meta.frameSamples) }.max()
        reconciled.frameCount = Int64(records.count)
        reconciled.logBytes = logBytes
        // A meta still marked open means we died with the segment open: it was interrupted.
        reconciled.closeReason = meta.closeReason ?? .interrupted
        // Stamp the close time (recovery time is the best bound) — the RESUME reattach
        // window keys off closedAtMs, and a crash-interrupted segment must be able to
        // reattach when the watch re-announces after the app relaunches.
        reconciled.closedAtMs = meta.closedAtMs ?? nowMs()
        return reconciled
    }

    // --- the recovery index -------------------------------------------------------------------

    /// A file's size and modification time, the two facts one directory listing yields for free
    /// and that together say "nobody has written this since". Microseconds: `Date` cannot carry a
    /// 2026 timestamp to the nanosecond, and the value only ever has to equal itself.
    struct FileStamp: Codable, Equatable, Sendable {
        var bytes: Int64
        var modifiedUs: Int64
    }

    /// What `recover()` leaves behind for the next launch. See the layout note at the top.
    struct RecoveryIndex: Codable, Sendable {
        static let currentVersion = 1
        var version = RecoveryIndex.currentVersion
        var entries: [String: Entry]

        struct Entry: Codable, Sendable {
            /// The sidecar as recovery last left it (reconciled and gap-normalized).
            var meta: SegmentMeta
            var metaStamp: FileStamp
            /// The log's size when the entry was recorded; nil for a sidecar whose log is gone.
            var logBytes: Int64?
        }
    }

    struct DirectoryScan {
        /// Segment id -> log size.
        var logs: [String: Int64] = [:]
        /// Segment id -> sidecar stamp.
        var metas: [String: FileStamp] = [:]
        var temps: [URL] = []
    }

    private var recoveryIndexURL: URL { root.appendingPathComponent("segments_index.json") }

    /// One listing, with the attributes the index is validated against. This is the whole of the
    /// per-file I/O a launch pays for a segment nothing has touched.
    private func scanSegmentsDirectory() -> DirectoryScan {
        var scan = DirectoryScan()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let entries =
            (try? fm.contentsOfDirectory(
                at: segmentsDir, includingPropertiesForKeys: keys, options: [])) ?? []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasSuffix(".tmp") {
                scan.temps.append(url)
            } else if name.hasSuffix(Self.logSuffix) {
                let id = String(name.dropLast(Self.logSuffix.count))
                scan.logs[id] = stampOf(url)?.bytes ?? 0
            } else if name.hasSuffix(Self.metaSuffix) {
                let id = String(name.dropLast(Self.metaSuffix.count))
                if let stamp = stampOf(url) { scan.metas[id] = stamp }
            }
        }
        return scan
    }

    private func stampOf(_ url: URL) -> FileStamp? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let bytes = values.fileSize
        else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileStamp(bytes: Int64(bytes), modifiedUs: Int64((modified * 1_000_000).rounded()))
    }

    private func loadRecoveryIndex() -> RecoveryIndex? {
        guard let data = try? Data(contentsOf: recoveryIndexURL),
            let index = try? JSONDecoder().decode(RecoveryIndex.self, from: data),
            index.version == RecoveryIndex.currentVersion
        else { return nil }
        return index
    }

    /// Best effort: a cache that fails to write costs the next launch a full read, nothing more.
    private func saveRecoveryIndex(_ index: RecoveryIndex) {
        do {
            let tmp = root.appendingPathComponent("segments_index.json.tmp")
            let encoder = JSONEncoder()
            // Deterministic bytes: the same library produces the same file, so the migration
            // importer's idempotency check (a byte-for-byte snapshot of the root) holds.
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(to: tmp)
            try atomicMove(from: tmp, to: recoveryIndexURL)
        } catch {
            log("recover: could not write the recovery index: \(error)")
        }
    }

    /// What a quarantine sweep found.
    public struct QuarantineSweep: Sendable, Equatable {
        /// Empty logs (and their stray sidecars) removed. Pure reclaimed disk.
        public var removed: Int = 0
        /// Logs that still hold parseable frames. NOT touched — that is real audio, and deleting
        /// it to tidy a directory would be the worst possible trade.
        public var retainedWithAudio: Int = 0
    }

    /// Cleans up `quarantine/`, which until now nothing ever looked at again.
    ///
    /// `recover()` moves a `.spxlog` here when its sidecar cannot be read. The only code that ever
    /// read the directory back was the one-shot legacy importer, so anything quarantined since has
    /// sat there permanently: invisible to retention (which sweeps `segments/` and has never known
    /// this exists), never recovered, never deleted. On a real device that was 5.2 MB in 33 files,
    /// the oldest from June.
    ///
    /// The sweep is deliberately asymmetric, because the two cases deserve opposite treatment. A
    /// log with no parseable frames holds nothing and is deleted. A log that still has frames is
    /// LEFT ALONE and counted, so it shows up in diagnostics rather than being quietly discarded —
    /// reconstructing a sidecar for it needs a codec template from a sibling segment, which is the
    /// importer's job, and throwing real audio away to tidy a directory would be far worse than
    /// leaving it.
    @discardableResult
    public func sweepQuarantine() -> QuarantineSweep {
        var result = QuarantineSweep()
        guard fm.fileExists(atPath: quarantineDir.path) else { return result }
        for url in listDirectory(quarantineDir)
        where url.lastPathComponent.hasSuffix(Self.logSuffix) {
            let bytes = [UInt8]((try? Data(contentsOf: url)) ?? Data())
            if parseRecords(bytes).records.isEmpty {
                let segmentId = String(url.lastPathComponent.dropLast(Self.logSuffix.count))
                try? removeIfExists(url)
                // Any sidecar the importer left beside it goes too; on its own it describes
                // audio that no longer exists.
                try? removeIfExists(
                    quarantineDir.appendingPathComponent("\(segmentId)\(Self.metaSuffix)")
                )
                result.removed += 1
            } else {
                result.retainedWithAudio += 1
            }
        }
        return result
    }

    private func quarantine(_ url: URL) throws {
        try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        try atomicMove(from: url, to: quarantineDir.appendingPathComponent(url.lastPathComponent))
    }

    private func parseRecords(_ bytes: [UInt8]) -> (records: [FrameRecord], validBytes: Int) {
        SegmentFrameLog.parse(bytes)
    }

    /// POSIX rename: atomically replaces `to` (Kotlin `FileSystem.atomicMove` semantics).
    private func atomicMove(from: URL, to: URL) throws {
        if rename(from.path, to.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: to.path])
        }
    }
}

// --- GapMeta range helpers (private to the store in the KMP source) ---------------------------

extension GapMeta {
    var endExclusive: UInt64 { UInt64(firstMissingSequence) + UInt64(missingFrameCount) }

    func containsSequence(_ sequence: UInt32) -> Bool {
        missingFrameCount > 0
            && sequence >= firstMissingSequence
            && UInt64(sequence) < endExclusive
    }

    var shouldPersistAsLoss: Bool {
        guard let raw = reasonRaw,
            let reason = UInt8(exactly: raw).flatMap(GapReason.init(rawValue:))
        else { return true }
        return !reason.isSilence
    }

    /// Same origin, same reason: two records that say the same thing about their frames.
    ///
    /// Records with DIFFERENT stories are never merged. A receiver sequence skip that ends exactly
    /// where the watch's overflow record begins is two facts — "the phone saw the sequence jump
    /// here" and "the watch's buffer filled here" — and folding the second into the first erased
    /// the watch's reason from the transcript and the Library.
    func tellsTheSameStory(as other: GapMeta) -> Bool {
        origin == other.origin && reasonRaw == other.reasonRaw
    }

    /// This record extended to cover `next` as well. The start never moves: `next` starts at or
    /// after it. The watch's drop counter is cumulative, so the larger one is the newer one.
    func extended(by next: GapMeta) -> GapMeta {
        var merged = self
        let end = max(endExclusive, next.endExclusive)
        merged.missingFrameCount = UInt32(clamping: end - UInt64(firstMissingSequence))
        merged.watchDropCounter = [watchDropCounter, next.watchDropCounter].compactMap { $0 }.max()
        return merged
    }
}

/// The one shape a segment's gap list is kept in — applied on every insert, and to every old
/// sidecar as it is read.
///
///  1. A receiver-synthesized sequence skip is cut back to the frames no watch record accounts
///     for. The watch's account of a frame — its reason, or that it was deliberately quiet — is
///     always the better one, and the receiver only ever guessed the skip from a jump in
///     sequence numbers. A skip the watch fully accounts for disappears.
///  2. Records are ordered by first missing sequence, whatever order they arrived in.
///  3. A record that tells the same story as the one before it and overlaps or touches it is
///     merged into it, so one period of loss stays one record however many notices described
///     it. A record with a different story keeps its own frames: where it overlaps the one
///     before, that one keeps the overlap and this one starts where it ends.
///
/// No loss the watch or the receiver reported is dropped by any of this: every sequence a loss
/// record claimed before is still claimed after, either by the same record or by the watch record
/// that trimmed it. The one exception is a skip over frames the watch said were deliberately
/// quiet, which is not loss; silence-suppressed records themselves are filtered out here, as
/// `recordGap` filters them.
///
/// `frameSamples` places the pieces of a trimmed skip on the sample clock.
func normalizedSegmentGaps(_ gaps: [GapMeta], frameSamples: Int) -> [GapMeta] {
    if gaps.isEmpty { return [] }
    let samplesPerFrame = UInt64(frameSamples > 0 ? frameSamples : 320)

    // (1) What the watch accounts for, as disjoint ranges. Silence counts: a skip over frames
    // the watch says it chose not to send is not loss the phone discovered.
    var watch: [(UInt64, UInt64)] = []
    for gap in gaps where gap.origin == GapMeta.originWatch && gap.missingFrameCount > 0 {
        watch.append((UInt64(gap.firstMissingSequence), gap.endExclusive))
    }
    watch.sort { $0.0 < $1.0 }
    var accounted: [(UInt64, UInt64)] = []
    for range in watch {
        if let last = accounted.last, range.0 <= last.1 {
            accounted[accounted.count - 1].1 = max(last.1, range.1)
        } else {
            accounted.append(range)
        }
    }
    func unaccountedPieces(of gap: GapMeta) -> [GapMeta] {
        let start = UInt64(gap.firstMissingSequence)
        let end = gap.endExclusive
        var pieces: [GapMeta] = []
        var cursor = start
        for range in accounted where range.1 > cursor && range.0 < end {
            if range.0 > cursor { pieces.append(piece(of: gap, from: cursor, to: range.0)) }
            cursor = max(cursor, range.1)
            if cursor >= end { break }
        }
        if cursor < end { pieces.append(piece(of: gap, from: cursor, to: end)) }
        return pieces
    }
    func piece(of gap: GapMeta, from: UInt64, to: UInt64) -> GapMeta {
        if from == UInt64(gap.firstMissingSequence) && to == gap.endExclusive { return gap }
        var copy = gap
        copy.firstMissingSequence = UInt32(from)
        copy.missingFrameCount = UInt32(to - from)
        copy.firstMissingSampleIndex =
            gap.firstMissingSampleIndex + (from - UInt64(gap.firstMissingSequence)) * samplesPerFrame
        return copy
    }

    var kept: [GapMeta] = []
    for gap in gaps where gap.shouldPersistAsLoss {
        if gap.origin == GapMeta.originSequenceSkip, gap.missingFrameCount > 0, !accounted.isEmpty {
            kept += unaccountedPieces(of: gap)
        } else {
            kept.append(gap)
        }
    }

    // (2) Sequence order; on a tie the watch's record goes first so it is the one that absorbs.
    let ordered = kept.enumerated()
        .sorted { a, b in
            if a.element.firstMissingSequence != b.element.firstMissingSequence {
                return a.element.firstMissingSequence < b.element.firstMissingSequence
            }
            let rankA = a.element.origin == GapMeta.originWatch ? 0 : 1
            let rankB = b.element.origin == GapMeta.originWatch ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset  // stable
        }
        .map(\.element)

    // (3) Sorted input means only the latest ranged record can overlap the next one: every
    // earlier one ends at or before it starts. (A zero-count record — "extent unknown" — has no
    // range to overlap with, so it is kept where it falls and never merged.)
    var result: [GapMeta] = []
    var latestRanged: Int?
    for var gap in ordered {
        if gap.missingFrameCount > 0, let index = latestRanged {
            let last = result[index]
            let start = UInt64(gap.firstMissingSequence)
            if last.tellsTheSameStory(as: gap), start <= last.endExclusive {
                result[index] = last.extended(by: gap)
                continue
            }
            if start < last.endExclusive {
                guard gap.endExclusive > last.endExclusive else { continue }  // wholly claimed
                gap = piece(of: gap, from: last.endExclusive, to: gap.endExclusive)
            }
        }
        result.append(gap)
        if gap.missingFrameCount > 0 { latestRanged = result.count - 1 }
    }
    return result
}
