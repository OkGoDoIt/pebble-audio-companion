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
        segmentsDir.appendingPathComponent("\(segmentId)\(Self.logSuffix)")
    }

    private func metaURL(_ segmentId: String) -> URL {
        segmentsDir.appendingPathComponent("\(segmentId)\(Self.metaSuffix)")
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
        // The StreamStart carries the stream-BIRTH wall clock, which can be 15 minutes (rotation
        // successor) to hours (RESUME outside the reattach window) old by the time a mid-stream
        // segment is minted. Anchor those at receive time so the timeline/recap files them when
        // they actually happened; only a segment that begins at the stream's birth keeps it.
        let resume = (start.flags & ProtocolConstants.streamStartFlagResume) != 0
            || dedupeFloorSequence != nil
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
            startTimeMs: resume ? UInt64(bitPattern: receivedAtMs) : start.startTimeMs,
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
        guard let segment = current else { return [] }
        if segment.meta.streamId != streamId { return [] }

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
        try segment.handle.synchronize() // durability point: the session checkpoints only what is flushed
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
    /// interruption, or a dropped notification. Two things keep `gaps` informative and sparse
    /// instead of one record per dropped packet:
    ///
    ///  - Silence-suppressed spans are deliberately-skipped quiet, not lost audio, so they are
    ///    never persisted as loss (the live waveform still renders them as quiet while active).
    ///  - A loss overlapping or contiguous (in sequence) with the previous gap extends that
    ///    record's total dropped duration rather than appending a new one — so one period of lost
    ///    audio is one gap noting the total time, however many packets it spanned.
    public func recordGap(streamId: UInt32, gap: GapRecord) throws {
        guard let segment = current else { return }
        if segment.meta.streamId != streamId { return }
        let incoming = GapMeta.from(gap)
        guard incoming.shouldPersistAsLoss else { return }
        segment.meta.gaps = withSparseLossGap(segment.meta.gaps, incoming: incoming)
        try writeMetaAtomically(segment.meta)
    }

    private func withSparseLossGap(_ gaps: [GapMeta], incoming: GapMeta) -> [GapMeta] {
        guard let last = gaps.last, last.shouldPersistAsLoss, last.overlapsOrTouches(incoming)
        else {
            return gaps + [incoming]
        }
        let mergedEnd = max(last.endExclusive, incoming.endExclusive)
        var merged = last
        merged.missingFrameCount = UInt32(mergedEnd - UInt64(last.firstMissingSequence))
        merged.watchDropCounter = incoming.watchDropCounter ?? last.watchDropCounter
        return gaps.dropLast() + [merged]
    }

    public func closeSegment(reason: SegmentCloseReason) throws {
        try closeSegmentInternal(.from(reason))
    }

    private func closeSegmentInternal(_ reason: CloseReasonMeta) throws {
        guard let segment = current else { return }
        current = nil
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

    private func buildIndexFromDisk() -> [String: SegmentMeta] {
        guard fm.fileExists(atPath: segmentsDir.path) else { return [:] }
        var map: [String: SegmentMeta] = [:]
        for url in listDirectory(segmentsDir) where url.lastPathComponent.hasSuffix(Self.metaSuffix) {
            let id = String(url.lastPathComponent.dropLast(Self.metaSuffix.count))
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
        let normalized = normalizeSparseLossGaps(meta.gaps)
        if normalized == meta.gaps { return meta }
        var copy = meta
        copy.gaps = normalized
        return copy
    }

    private func normalizeSparseLossGaps(_ gaps: [GapMeta]) -> [GapMeta] {
        if gaps.isEmpty { return [] }
        let watchRanges = gaps.filter { $0.origin == GapMeta.originWatch && $0.missingFrameCount > 0 }
        func coveredByWatch(_ gap: GapMeta) -> Bool {
            watchRanges.contains { $0.covers(gap) }
        }

        let sorted = gaps
            .filter { $0.shouldPersistAsLoss }
            .filter { !($0.origin == GapMeta.originSequenceSkip && coveredByWatch($0)) }
            .enumerated()
            .sorted { a, b in
                if a.element.firstMissingSequence != b.element.firstMissingSequence {
                    return a.element.firstMissingSequence < b.element.firstMissingSequence
                }
                let rankA = a.element.origin == GapMeta.originWatch ? 0 : 1
                let rankB = b.element.origin == GapMeta.originWatch ? 0 : 1
                if rankA != rankB { return rankA < rankB }
                return a.offset < b.offset  // stable, matching Kotlin's sortedWith
            }
            .map(\.element)
        return sorted.reduce([]) { acc, gap in withSparseLossGap(acc, incoming: gap) }
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
    public func recover() throws {
        precondition(current == nil, "recover() must run before any segment is opened")
        guard fm.fileExists(atPath: segmentsDir.path) else { return }
        let entries = listDirectory(segmentsDir)

        // Leftover atomic-write temps: the final file either exists (rename happened) or the
        // write never completed; either way the temp is garbage.
        for tmp in entries where tmp.lastPathComponent.hasSuffix(".tmp") {
            try removeIfExists(tmp)
        }

        let logs = entries.filter { $0.lastPathComponent.hasSuffix(Self.logSuffix) }
        for logFile in logs {
            let segmentId = String(logFile.lastPathComponent.dropLast(Self.logSuffix.count))
            guard let meta = readMetaFromDisk(segmentId) else {
                try quarantine(logFile)
                continue
            }
            let logBytes = logSizeBytes(segmentId)
            if !needsRecoveryParse(meta, logBytes: logBytes) {
                continue
            }
            let bytes = [UInt8]((try? Data(contentsOf: logFile)) ?? Data())
            let parsed = parseRecords(bytes)
            if parsed.validBytes < bytes.count {
                // Truncate at the first bad record via temp + atomic rename.
                let tmp = segmentsDir.appendingPathComponent("\(segmentId)\(Self.logSuffix).tmp")
                try Data(bytes[0..<parsed.validBytes]).write(to: tmp)
                try atomicMove(from: tmp, to: logFile)
            }
            try reconcileMeta(meta, records: parsed.records, logBytes: Int64(parsed.validBytes))
        }
        try normalizeGapSidecars()
        // Build the authoritative index once, after all reconcile-writes, so subsequent reads
        // (diagnostics, UI, RESUME continuation) never touch disk.
        metaIndex = buildIndexFromDisk()
    }

    private func normalizeGapSidecars() throws {
        for url in listDirectory(segmentsDir) where url.lastPathComponent.hasSuffix(Self.metaSuffix) {
            let segmentId = String(url.lastPathComponent.dropLast(Self.metaSuffix.count))
            guard let meta = readMetaFromDisk(segmentId) else { continue }
            let normalized = withNormalizedGaps(meta)
            if normalized != meta { try writeMetaAtomically(normalized) }
        }
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

    private func reconcileMeta(_ meta: SegmentMeta, records: [FrameRecord], logBytes: Int64) throws {
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
        if reconciled != meta { try writeMetaAtomically(reconciled) }
    }

    private func quarantine(_ url: URL) throws {
        try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        try atomicMove(from: url, to: quarantineDir.appendingPathComponent(url.lastPathComponent))
    }

    private func parseRecords(_ bytes: [UInt8]) -> (records: [FrameRecord], validBytes: Int) {
        var records: [FrameRecord] = []
        var offset = 0
        var reader = WireReader(bytes)
        while true {
            if reader.remaining < Self.recordHeaderBytes { break }
            let sequence = reader.u32()
            let sampleIndex = reader.u64()
            let len = reader.u16()
            if len > ProtocolConstants.maxEncodedFrameBytes || reader.remaining < len { break }
            records.append(
                FrameRecord(sequence: sequence, sampleIndex: sampleIndex, payload: reader.readBytes(len)))
            offset += Self.recordHeaderBytes + len
        }
        return (records, offset)
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

    func overlapsOrTouches(_ next: GapMeta) -> Bool {
        missingFrameCount > 0
            && next.missingFrameCount > 0
            && UInt64(next.firstMissingSequence) <= endExclusive
    }

    func covers(_ other: GapMeta) -> Bool {
        missingFrameCount > 0
            && other.missingFrameCount > 0
            && firstMissingSequence <= other.firstMissingSequence
            && endExclusive >= other.endExclusive
    }
}
