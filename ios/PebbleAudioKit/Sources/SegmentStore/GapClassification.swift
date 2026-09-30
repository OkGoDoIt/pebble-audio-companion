import Foundation
import WireProtocol

// The ONE answer to "what does this gap record mean for the person reading it?".
//
// There used to be two. `CoverageComputer.isVisibleLoss` (the day strip) treated the watch's
// power-save pause as a pause but counted every receiver sequence skip as loss;
// `StatusUI.GapVisibility` (transcript markers, the per-recording "N missing", Ask's gap note,
// the loss notification) excused a sequence skip that a silence record fully covers but counted
// the power-save pause as loss. So the same minute could be "paused" on the strip and "missing"
// in the recording it belongs to. Both now ask this type, and the answer keeps each side's
// product decision:
//
// - A power-save pause is a PAUSE, never loss — the watch chose not to listen (stationary mute;
//   the status card already says "Paused while the watch is saving power"), and a night on the
//   nightstand is not lost audio. See `CoverageComputer.isWatchPause` for the measured cost of
//   getting this wrong (45 h of the 2026-09-29 backup).
// - A receiver sequence skip that a SINGLE watch-reported silence record fully covers is quiet:
//   a few field builds stored both records for the same range, and the watch's reason is the
//   truth about that time.
//
// Everything else fails closed to loss: an absent or undecodable reason, an unknown origin, and
// every other watch-reported reason — `.userDisabled` included, whose treatment is an open
// product decision this type deliberately does not make.
//
// It lives in SegmentStore because that is the lowest module both AppDB (coverage) and StatusUI
// (gap status) can reach; it depends on nothing but `GapMeta` and `GapReason`.

/// What one gap record means.
public enum GapClass: Sendable, Equatable {
    /// Known-quiet audio the watch withheld (voice-activity suppression), or a duplicate receiver
    /// skip wholly inside such a record. Not loss.
    case quiet
    /// The watch's own power-save pause: nobody was listening, by the watch's choice. Not loss,
    /// and not quiet either — nothing was heard.
    case watchPause
    /// Genuine missing audio.
    case loss
}

/// The decoded wire reason of a gap record, or nil when absent or not one we know.
public func gapReason(of gap: GapMeta) -> GapReason? {
    guard let raw = gap.reasonRaw, raw >= 0, raw <= Int(UInt8.max) else { return nil }
    return GapReason(rawValue: UInt8(raw))
}

/// Classifies the gaps of ONE segment. Build it once over the segment's whole gap list: whether a
/// sequence skip is quiet depends on the silence records beside it.
///
/// A segment can hold thousands of gap records (every suppressed-silence span adds one), so the
/// silence cover is precomputed — sorted starts plus a running max end — and each question is a
/// binary search, not a rescan of the list (the rescan once froze the Today timeline for ~12 s).
public struct GapClassifier: Sendable {
    private let silenceStarts: [UInt64]
    private let silenceMaxEnd: [UInt64]

    public init(_ gaps: [GapMeta]) {
        // Silence cover is in SEQUENCE space, as the receiver's skips are. Only watch-reported
        // silence counts as cover: a sequence skip is never itself quiet evidence (see `classify`).
        // 64-bit interval arithmetic so `start + count` cannot wrap.
        let silence = gaps
            .filter { $0.origin != GapMeta.originSequenceSkip && gapReason(of: $0)?.isSilence == true }
            .map { (UInt64($0.firstMissingSequence), UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)) }
            .sorted { $0.0 < $1.0 }
        var starts = [UInt64]()
        var maxEnds = [UInt64]()
        starts.reserveCapacity(silence.count)
        maxEnds.reserveCapacity(silence.count)
        var runningMax: UInt64 = 0
        for (index, interval) in silence.enumerated() {
            runningMax = index == 0 ? interval.1 : max(runningMax, interval.1)
            starts.append(interval.0)
            maxEnds.append(runningMax)
        }
        silenceStarts = starts
        silenceMaxEnd = maxEnds
    }

    public func classify(_ gap: GapMeta) -> GapClass {
        // A receiver skip means "the sequence numbers jumped and nobody said why". It is loss
        // unless one silence record says that exact stretch was quiet. Its own reason field is
        // never consulted: the receiver does not set one, and a stray value on a skip must not be
        // able to turn it into quiet or a pause.
        if gap.origin == GapMeta.originSequenceSkip {
            let start = UInt64(gap.firstMissingSequence)
            return coveredBySingleSilenceGap(start: start, end: start + UInt64(gap.missingFrameCount))
                ? .quiet : .loss
        }
        switch gapReason(of: gap) {
        case .silenceSuppressed?: return .quiet
        case .powerSave?: return .watchPause
        default: return .loss
        }
    }

    /// Genuine missing audio: neither quiet nor the watch's pause.
    public func isVisibleLoss(_ gap: GapMeta) -> Bool { classify(gap) == .loss }

    private func coveredBySingleSilenceGap(start: UInt64, end: UInt64) -> Bool {
        // Largest index whose silence start <= `start`; its prefix max end is the widest a single
        // silence gap (with start <= start) reaches, so >= end means one fully covers [start, end).
        var lo = 0
        var hi = silenceStarts.count - 1
        var idx = -1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if silenceStarts[mid] <= start {
                idx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return idx >= 0 && silenceMaxEnd[idx] >= end
    }
}
