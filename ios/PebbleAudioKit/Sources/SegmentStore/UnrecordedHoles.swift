import Foundation
import WireProtocol

// Holes in a frame log that no gap record explains, and what they were.
//
// WHERE THEY CAME FROM
//
// Until 42dc693 (2026-09-30) `SegmentStore.recordGap` discarded every watch notice whose reason is
// `silenceSuppressed`. The receiver had already done its half correctly: it remembered the
// notice (`rememberKnownGap`), so when the next frame arrived above the suppressed stretch the
// jump was accounted for and no `sequence_skip` was synthesized — and then the store threw the
// only record of that stretch away. Every recording made before that build therefore holds
// voice-activity quiet as a bare hole in its sequence numbers: sequence span and sample span
// both run over it, and nothing says why.
//
// Measured on the 2026-09-30 01:14 backup: 330 of 865 segments, 3,260 min of wall time (54 h;
// 9.78 M frames in 31,667 holes, a median 120 holes an hour — the watch's suppression cadence).
// The 19:37 backup the same day shows the other side of it: from the first segment the fixed
// build recorded (09-30 01:07) the same fifteen-minute segments of a few hundred frames are
// accounted for to the frame by the watch's own reason-8 records, and no segment after it has
// an unexplained hole. Coverage placed recorded audio from the first to the last sample of a
// segment, so Today, Live and History drew all of that quiet as recorded audio (History's
// 2026-09-24 showed a 20 h "Not transcribed yet" stretch over 17 h of stored audio), and
// `SegmentMediaClock` fell back to its proportional guess for every one of those recordings.
//
// WHAT A HOLE IS TAKEN TO BE
//
// A hole is only inferred at all in a recording opened before the library's first watch-reported
// quiet record — the store's own evidence of when its build began keeping them (see
// `SegmentStore.accountForUnrecordedHoles`). Inside such a recording the ONLY notices the store
// dropped were quiet ones, so a hole is quiet — with one exception, which fails closed: a hole
// that touches a record of anything else (overflow, power save, a transport reset, a receiver
// skip) is LOSS of unknown cause. That is the shape of the two receiver bugs of the same period
// that did lose audio without a record — the RESUME seed that left the run just below the
// watch's first overflow record unrecorded, and the out-of-order merge that swallowed the frames
// between two held overflow records — and quiet laid over real loss would hide it. In the backup
// it is 92 holes, 12.8 min.
//
// Both kinds are stored as records with their own origin, `frame_log_hole`, so an inferred
// record can never be mistaken for the watch's word: quiet carries the `silenceSuppressed` reason
// (every consumer already classifies by reason), loss carries none, which `GapClassifier` and the
// gap copy already read as "audio missing", cause unknown.

extension GapMeta {
    /// A hole in a recording's frame log that no record explained when it was stored, recorded
    /// after the fact from the log itself (`unrecordedHoleRecords`). Quiet when its reason is
    /// `silenceSuppressed`; loss of unknown cause when it has none.
    public static let originFrameLogHole = "frame_log_hole"
}

/// The frames `SegmentStore.accountForUnrecordedHoles` needs: sequence and sample index, no
/// payload. Order does not matter (a refill is appended out of order).
public struct StoredFramePosition: Equatable, Sendable {
    public let sequence: UInt32
    public let sampleIndex: UInt64

    public init(sequence: UInt32, sampleIndex: UInt64) {
        self.sequence = sequence
        self.sampleIndex = sampleIndex
    }
}

extension SegmentFrameLog {
    /// `parse` without the payloads: the repair reads 190 MB of logs once and needs 12 bytes of
    /// each record.
    static func positions(_ bytes: [UInt8]) -> [StoredFramePosition] {
        // The record layout `parse` reads: u32 sequence, u64 sample index, u16 length, payload,
        // all little-endian.
        func little(_ at: Int, _ width: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in stride(from: width - 1, through: 0, by: -1) {
                value = (value << 8) | UInt64(bytes[at + i])
            }
            return value
        }
        var positions: [StoredFramePosition] = []
        var offset = 0
        while bytes.count - offset >= SegmentStore.recordHeaderBytes {
            let len = Int(little(offset + 12, 2))
            let payloadStart = offset + SegmentStore.recordHeaderBytes
            if len > ProtocolConstants.maxEncodedFrameBytes || bytes.count - payloadStart < len {
                break
            }
            positions.append(
                StoredFramePosition(
                    sequence: UInt32(little(offset, 4)), sampleIndex: little(offset + 4, 8)))
            offset = payloadStart + len
        }
        return positions
    }
}

extension SegmentMeta {
    /// Frames the sequence span covers that neither a stored frame nor a gap record accounts
    /// for — from the sidecar alone, no frame log read. Normalized gap records are disjoint
    /// (`normalizedSegmentGaps`), so their clipped counts add up without double counting; a
    /// record reaching outside the span only counts the part inside it.
    ///
    /// Zero for a fully accounted recording, and never an overestimate of the holes: a frame
    /// stored twice or a record lying over stored frames can only hide one, never invent one —
    /// which is what lets the repair use this as its "anything left to do?" test without ever
    /// re-reading a recording it has already repaired.
    public var unaccountedFrameCount: Int64 {
        guard let first = firstSequence, let last = lastSequence, last >= first else { return 0 }
        let lo = UInt64(first)
        let hi = UInt64(last) + 1
        var accounted = frameCount
        for gap in gaps where gap.missingFrameCount > 0 {
            let start = max(UInt64(gap.firstMissingSequence), lo)
            let end = min(gap.endExclusive, hi)
            if end > start { accounted += Int64(end - start) }
        }
        return max(0, Int64(hi - lo) - accounted)
    }
}

/// The records that account for every hole in `frames` no record of `meta` covers: quiet unless
/// the hole touches a record that is not quiet, then loss of unknown cause (see the note at the
/// top of this file). Holes are placed on the sample clock from the frame just below them — the
/// watch advances both counters together through quiet and loss alike (31,999 of 31,999 holes in
/// the backup agree).
///
/// Only holes BETWEEN stored frames: a recording's extent is its first to last frame, and what
/// lies outside it is not this recording's to explain.
public func unrecordedHoleRecords(
    in meta: SegmentMeta, frames: [StoredFramePosition]
) -> [GapMeta] {
    guard frames.count > 1 else { return [] }
    let samplesPerFrame = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
    let sorted = frames.sorted { $0.sequence < $1.sequence }

    let recorded: [(UInt64, UInt64)] = {
        let ranges = meta.gaps.filter { $0.missingFrameCount > 0 }
            .map { (UInt64($0.firstMissingSequence), $0.endExclusive) }
            .sorted { $0.0 < $1.0 }
        var merged: [(UInt64, UInt64)] = []
        for range in ranges {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else {
                merged.append(range)
            }
        }
        return merged
    }()
    // Where a record of anything but quiet begins and ends. A zero-count record ("extent
    // unknown") is a point, and a hole touching it touches it.
    let classifier = GapClassifier(meta.gaps)
    var otherEdges = Set<UInt64>()
    for gap in meta.gaps where classifier.classify(gap) != .quiet {
        otherEdges.insert(UInt64(gap.firstMissingSequence))
        otherEdges.insert(gap.endExclusive)
    }

    var records: [GapMeta] = []
    var next = 0  // first merged record that may still reach the current hole
    func emit(from: UInt64, to: UInt64, below frame: StoredFramePosition) {
        let touchesOther = otherEdges.contains(from) || otherEdges.contains(to)
        records.append(
            GapMeta(
                firstMissingSequence: UInt32(from),
                missingFrameCount: UInt32(to - from),
                firstMissingSampleIndex: frame.sampleIndex
                    + (from - UInt64(frame.sequence)) * samplesPerFrame,
                origin: GapMeta.originFrameLogHole,
                reasonRaw: touchesOther ? nil : Int(GapReason.silenceSuppressed.rawValue)))
    }
    for (below, above) in zip(sorted, sorted.dropFirst()) {
        let holeEnd = UInt64(above.sequence)
        var cursor = UInt64(below.sequence) + 1
        guard holeEnd > cursor else { continue }
        while next < recorded.count, recorded[next].1 <= cursor { next += 1 }
        var index = next
        while index < recorded.count, recorded[index].0 < holeEnd {
            if recorded[index].0 > cursor { emit(from: cursor, to: recorded[index].0, below: below) }
            cursor = max(cursor, recorded[index].1)
            if cursor >= holeEnd { break }
            index += 1
        }
        if cursor < holeEnd { emit(from: cursor, to: holeEnd, below: below) }
    }
    return records
}

/// What one `SegmentStore.accountForUnrecordedHoles` call did.
public struct UnrecordedHoleRepair: Equatable, Sendable {
    /// Recordings whose sidecar gained records.
    public var repaired = 0
    public var quietFrames: Int64 = 0
    public var lossFrames: Int64 = 0
    /// Recordings still to do (the byte budget ran out before them).
    public var remaining = 0

    public init() {}
}
