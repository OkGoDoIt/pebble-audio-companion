import Foundation
import SegmentStore

// Recovery of orphan audio from `quarantine/` (migration phase 4, added in marker version 2).
//
// `SegmentStore.recover()` sweeps a `.spxlog` aside whenever its `.meta.json` sidecar cannot be
// read. The audio is untouched — only its metadata is gone — so a quarantined log is a complete
// frame log with no description of itself. On Roger's container that is 298 logs / 285 MB /
// ~40 h of audio reaching back to 2026-06-12, most of it older than the 30-day retention window
// that pruned the matching `segments/` entries, which is why "my library starts on August 2".
//
// Everything the sidecar held is either recoverable from the file name, derivable from the frame
// log, or fixed for this product:
//
//  - the id `seg-<receivedAtMs>-<streamId 8-hex>-<counter>` carries the phone wall clock at
//    segment open and the stream id;
//  - `firstSequence` / `lastSequence` / `firstSampleIndex` / `lastSampleIndexExclusive` /
//    `frameCount` / `logBytes` come from scanning the records;
//  - `frameSamples` is measured from the log (sample index and sequence advance in lockstep —
//    verified across 1.8 M record pairs in the real container), and the remaining codec fields
//    are copied from a healthy sidecar in `segments/` rather than invented.
//
// One thing is NOT recoverable: the gap records. Sequence holes in this data are either
// spool-overflow LOSS or VAD-suppressed silence, and only the lost sidecar knew which. Coverage
// treats a hole with no loss gap as calm "quiet" (CoverageComputer), so writing no gaps would
// have recovered audio silently claim clean coverage it cannot prove. Recovered holes are
// therefore written as explicit `sequence_skip` loss: the product rule is that loss is never
// hidden, and the real container agrees empirically — every gap record in `segments/` is a
// spool-overflow/transport/power-save loss, and not one is SilenceSuppressed.

/// Frame-log facts scanned out of one `.spxlog`.
struct ScannedFrameLog {
    var frameCount: Int
    var validBytes: Int
    var firstSequence: UInt32
    var lastSequence: UInt32
    var firstSampleIndex: UInt64
    var lastSampleIndexExclusive: UInt64
    /// Samples per frame measured from consecutive records (nil when the log has < 2 records).
    var measuredFrameSamples: Int?
    /// Sequence ranges present in neither the records nor (for a restored sidecar) its gaps.
    var holes: [(firstSequence: UInt32, frameCount: UInt32, firstSampleIndex: UInt64)]

    var spanFrames: Int { Int(lastSequence - firstSequence) + 1 }
}

/// Parses `<u32 sequence><u64 sampleIndex><u16 len><payload>` records — the same layout
/// `SegmentStore` writes and `SegmentFrameLog` reads. Duplicated here (rather than exported from
/// SegmentStore) because recovery reads files that are NOT yet under the store's root.
enum QuarantineFrameLog {
    /// Upper bound on one encoded frame, mirroring `ProtocolConstants.maxEncodedFrameBytes`;
    /// a longer length field means the record is garbage and the scan stops there.
    static let maxEncodedFrameBytes = 200
    static let recordHeaderBytes = 14

    static func scan(_ data: Data, frameSamplesHint: Int) -> ScannedFrameLog? {
        let bytes = [UInt8](data)
        var offset = 0
        var sequences: [UInt32] = []
        var sampleBySequence: [UInt32: UInt64] = [:]
        while offset + recordHeaderBytes <= bytes.count {
            let sequence = UInt32(
                littleEndian: bytes.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                })
            let sampleIndex = UInt64(
                littleEndian: bytes.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt64.self)
                })
            let length = Int(
                UInt16(
                    littleEndian: bytes.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt16.self)
                    }))
            if length > maxEncodedFrameBytes { break }
            if offset + recordHeaderBytes + length > bytes.count { break }
            sequences.append(sequence)
            // A gap refill can re-append an earlier sequence; keep the first sample index seen.
            if sampleBySequence[sequence] == nil { sampleBySequence[sequence] = sampleIndex }
            offset += recordHeaderBytes + length
        }
        guard let firstSequence = sequences.min(), let lastSequence = sequences.max(),
            let firstSampleIndex = sampleBySequence.values.min()
        else { return nil }

        // Sample index and sequence advance together, so frame size falls out of any pair of
        // records — no need to trust a constant.
        var measured: Int?
        let ordered = sampleBySequence.sorted { $0.key < $1.key }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let deltaSequence = UInt64(b.key - a.key)
            guard deltaSequence > 0, b.value > a.value else { continue }
            let delta = b.value - a.value
            if delta % deltaSequence == 0 {
                measured = Int(delta / deltaSequence)
                break
            }
        }
        let frameSamples = measured ?? frameSamplesHint
        let lastSampleIndexExclusive =
            (sampleBySequence.values.max() ?? firstSampleIndex) + UInt64(frameSamples)

        // Holes: maximal runs of absent sequence numbers inside [first, last].
        let present = Set(sequences)
        var holes: [(UInt32, UInt32, UInt64)] = []
        var cursor = firstSequence
        while cursor <= lastSequence {
            if present.contains(cursor) {
                cursor += 1
                continue
            }
            let holeStart = cursor
            while cursor <= lastSequence, !present.contains(cursor) { cursor += 1 }
            let count = cursor - holeStart
            let sampleIndex =
                firstSampleIndex + UInt64(holeStart - firstSequence) * UInt64(frameSamples)
            holes.append((holeStart, count, sampleIndex))
            if cursor == 0 { break }  // UInt32 wrap guard
        }

        return ScannedFrameLog(
            frameCount: sequences.count,
            validBytes: offset,
            firstSequence: firstSequence,
            lastSequence: lastSequence,
            firstSampleIndex: firstSampleIndex,
            lastSampleIndexExclusive: lastSampleIndexExclusive,
            measuredFrameSamples: measured,
            holes: holes.map {
                (firstSequence: $0.0, frameCount: $0.1, firstSampleIndex: $0.2)
            }
        )
    }
}

/// The `seg-<receivedAtMs>-<streamId 8-hex>-<counter>` id the store mints.
struct ParsedSegmentId {
    var receivedAtMs: Int64
    var streamId: UInt32

    /// Nil for anything that is not a well-formed segment id — the quarantine directory also
    /// holds truncated names from interrupted copies (`.spxlo`, `.meta.j`) and stray files.
    static func parse(_ segmentId: String) -> ParsedSegmentId? {
        let parts = segmentId.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "seg",
            let receivedAtMs = Int64(parts[1]), receivedAtMs > 0,
            parts[2].count == 8, let streamId = UInt32(parts[2], radix: 16),
            Int(parts[3]) != nil
        else { return nil }
        return ParsedSegmentId(receivedAtMs: receivedAtMs, streamId: streamId)
    }
}

/// Codec fields that are identical for every segment this product records. Taken from a healthy
/// sidecar when one exists so recovery copies the device's real values instead of asserting
/// them; the fallbacks are the Speex wideband configuration the firmware streams.
struct CodecTemplate {
    var protocolVersion: Int = 1
    var codecIdRaw: UInt8 = 1
    var channels: Int = 1
    var frameSamples: Int = 320
    var sampleRateHz: UInt32 = 16_000
    var bitRateBps: UInt32 = 9_800
    var frameDurationMs: Int = 20

    init() {}

    init(_ meta: SegmentMeta) {
        protocolVersion = meta.protocolVersion
        codecIdRaw = meta.codecIdRaw
        channels = meta.channels
        frameSamples = meta.frameSamples
        sampleRateHz = meta.sampleRateHz > 0 ? meta.sampleRateHz : 16_000
        bitRateBps = meta.bitRateBps
        frameDurationMs = meta.frameDurationMs
    }
}

enum QuarantineRecovery {
    /// Rebuilds a sidecar for one orphan log.
    ///
    /// `startTimeMs` is set so the segment's ANCHORED start (`startTimeMs +
    /// firstSampleIndex·1000/rate`, the store's wall-clock rule) lands exactly on
    /// `receivedAtMs`. These are mid-stream orphans: only a stream-birth segment keeps the
    /// watch's own clock, and `LegacyImporter.clampedStartTimeMs` would otherwise immediately
    /// re-anchor anything else. Intra-segment relative timing is preserved either way.
    static func reconstructMeta(
        segmentId: String,
        parsedId: ParsedSegmentId,
        scan: ScannedFrameLog,
        codec: CodecTemplate,
        transcribed: Bool,
        timeZoneID: String,
        nowMs: Int64
    ) -> SegmentMeta {
        let frameSamples = scan.measuredFrameSamples ?? codec.frameSamples
        let rate = Int64(codec.sampleRateHz > 0 ? codec.sampleRateHz : 16_000)
        let startOffsetMs = Int64(scan.firstSampleIndex) * 1000 / rate
        let spanMs =
            Int64(scan.lastSampleIndexExclusive - scan.firstSampleIndex) * 1000 / rate
        let frameDurationMs =
            frameSamples > 0 ? Int(Int64(frameSamples) * 1000 / rate) : codec.frameDurationMs

        return SegmentMeta(
            segmentId: segmentId,
            streamId: parsedId.streamId,
            protocolVersion: codec.protocolVersion,
            codecIdRaw: codec.codecIdRaw,
            channels: codec.channels,
            frameSamples: frameSamples,
            sampleRateHz: codec.sampleRateHz,
            bitRateBps: codec.bitRateBps,
            frameDurationMs: frameDurationMs,
            startTimeMs: UInt64(max(parsedId.receivedAtMs - startOffsetMs, 0)),
            // The watch monotonic clock at stream start is unknowable; 0 is the honest value
            // (it is only ever used as a relative anchor within a live stream).
            startMonotonicMs: 0,
            receivedAtMs: parsedId.receivedAtMs,
            firstSequence: scan.firstSequence,
            lastSequence: scan.lastSequence,
            firstSampleIndex: scan.firstSampleIndex,
            lastSampleIndexExclusive: scan.lastSampleIndexExclusive,
            frameCount: Int64(scan.frameCount),
            logBytes: Int64(scan.validBytes),
            gaps: scan.holes.map {
                GapMeta(
                    firstMissingSequence: $0.firstSequence,
                    missingFrameCount: $0.frameCount,
                    firstMissingSampleIndex: $0.firstSampleIndex,
                    // `sequence_skip` = "frames absent from the log, cause unrecorded", which is
                    // exactly the situation, and CoverageComputer always renders it as loss.
                    origin: GapMeta.originSequenceSkip
                )
            },
            // The stream ended without a recorded close: interrupted is the truthful reason.
            closeReason: .interrupted,
            closedAtMs: parsedId.receivedAtMs + max(spanMs, 0),
            // A surviving transcript means this audio was already transcribed before it was
            // orphaned — never pay for it twice.
            transcriptionState: transcribed ? .complete : .pending,
            recordedTimeZone: timeZoneID,
            recoveredAtMs: nowMs
        )
    }

    /// Adopts a sidecar that was quarantined ALONGSIDE its log (11 such pairs in the real
    /// container). Its gap records are real, so nothing is synthesized — only the extents are
    /// reconciled against the log and the recovery/timezone markers are stamped.
    static func adoptMeta(
        _ meta: SegmentMeta,
        scan: ScannedFrameLog,
        transcribed: Bool,
        timeZoneID: String,
        nowMs: Int64
    ) -> SegmentMeta {
        var adopted = meta
        adopted.firstSequence = scan.firstSequence
        adopted.lastSequence = scan.lastSequence
        adopted.firstSampleIndex = scan.firstSampleIndex
        adopted.lastSampleIndexExclusive = scan.lastSampleIndexExclusive
        adopted.frameCount = Int64(scan.frameCount)
        adopted.logBytes = Int64(scan.validBytes)
        adopted.closeReason = adopted.closeReason ?? .interrupted
        adopted.closedAtMs = adopted.closedAtMs ?? nowMs
        if adopted.recordedTimeZone == nil { adopted.recordedTimeZone = timeZoneID }
        if transcribed, adopted.transcriptionState == .pending {
            adopted.transcriptionState = .complete
        }
        adopted.recoveredAtMs = nowMs
        return adopted
    }
}
