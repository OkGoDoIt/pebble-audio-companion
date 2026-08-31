import Foundation
import WireProtocol
import SegmentStore

// Port of the gap-visibility classifier and gap copy from `app/.../ui/StatusUi.kt`.
// Loss is always explicit; VAD-skipped silence is calm "quiet", never conflated with loss.
//
// This is the ONE gap vocabulary. SearchKit's transcript renderer (the surface that actually
// shows a person their gaps) used to carry a private copy of both the classifier and these
// strings; the two had already drifted, so the copy was deleted and SearchKit now depends on
// this module. Change the wording here and every surface changes with it.

/// Plain-language reason for one gap. Calm by design (ux plan: "visible but not alarmist");
/// gaps are expected in normal use, so no "Gap:"/error framing.
public func gapDescription(_ gap: GapMeta) -> String {
    let reason = gapReason(of: gap)
    if gap.origin == GapMeta.originSequenceSkip { return "phone briefly missed audio" }
    switch reason {
    case .spoolOverflow: return "watch buffer filled while disconnected"
    case .micConflict: return "watch dictation used the mic"
    case .userDisabled: return "recording was paused"
    case .lowBattery: return "paused for watch battery"
    case .codecError: return "watch audio hiccup"
    case .transportReset: return "connection was interrupted"
    case .powerSave: return "watch was saving power"
    case .silenceSuppressed: return "quiet audio was skipped"
    case nil: return "audio missing"
    }
}

private func gapReason(of gap: GapMeta) -> GapReason? {
    guard let raw = gap.reasonRaw, raw >= 0, raw <= Int(UInt8.max) else { return nil }
    return GapReason(rawValue: UInt8(raw))
}

/// A silence-suppressed gap is audio the watch intentionally skipped because it was below the
/// voice-activity threshold — known-quiet time it withheld to save Bluetooth/battery, not lost
/// audio. The app treats it as silence everywhere, never as a gap, interruption, or error.
public func isSilenceGap(_ gap: GapMeta) -> Bool {
    gapReason(of: gap)?.isSilence == true
}

/// Gaps that should be presented as genuine missing audio. A small number of field builds could
/// store a receiver-synthesized sequence skip adjacent to the watch's explicit skipped-silence
/// record for the same range. For display, the watch's silence reason wins: that time was known
/// quiet, not a phone/link failure. The raw metadata remains unchanged for diagnostics.
public func visibleLossGaps(_ meta: SegmentMeta) -> [GapMeta] {
    let visibility = GapVisibility(meta.gaps)
    return meta.gaps.filter { visibility.isVisibleLoss($0) }
}

/// Precomputes silence-coverage for one segment's gaps so visibility is a binary search instead
/// of a per-gap rescan of the whole list. A segment can accumulate thousands of gap records
/// (every silence-suppression span, overflow, and reconnect adds one), so the old O(n²)
/// `allGaps.none { … }` froze the main thread for ~12 s while building the Today timeline once
/// the test library grew. Silence intervals are sorted by start with a running max end, which
/// answers "is this sequence-skip fully covered by some single silence gap?" in O(log n).
public final class GapVisibility {
    private let silenceStarts: [UInt64]
    private let silenceMaxEnd: [UInt64]

    public init(_ gaps: [GapMeta]) {
        // 64-bit interval arithmetic: KMP's UInt math would wrap on (start + count) overflow;
        // widening is semantically identical for all real inputs and cannot trap.
        let silence = gaps
            .filter { isSilenceGap($0) }
            .map {
                (
                    UInt64($0.firstMissingSequence),
                    UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)
                )
            }
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

    public func isVisibleLoss(_ gap: GapMeta) -> Bool {
        if isSilenceGap(gap) { return false }
        if gap.origin != GapMeta.originSequenceSkip { return true }
        let start = UInt64(gap.firstMissingSequence)
        return !coveredBySingleSilenceGap(start: start, end: start + UInt64(gap.missingFrameCount))
    }

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

public func isVisibleLossGap(_ gap: GapMeta, allGaps: [GapMeta]) -> Bool {
    GapVisibility(allGaps).isVisibleLoss(gap)
}

/// Approximate gap length from missing frame count (20 ms frames).
public func gapDurationMs(_ gap: GapMeta, frameDurationMs: Int) -> Int64 {
    Int64(gap.missingFrameCount) * Int64(frameDurationMs)
}

/// Total approximate missing time of a segment (intentionally-skipped silence excluded).
public func totalGapMs(_ meta: SegmentMeta) -> Int64 {
    visibleLossGaps(meta).reduce(0) { $0 + gapDurationMs($1, frameDurationMs: meta.frameDurationMs) }
}

/// User-facing missing time, guarded against stale/impossible gap metadata.
public func displayGapMs(_ meta: SegmentMeta) -> Int64 {
    let totalMs = totalGapMs(meta)
    let durationMs = segmentDurationMs(meta)
    if totalMs <= 0 { return 0 }
    if durationMs > 0 { return min(totalMs, durationMs) }
    return totalMs
}

/// Duration of a segment in ms, preferring the sample counters (gaps included).
public func segmentDurationMs(_ meta: SegmentMeta) -> Int64 {
    if let first = meta.firstSampleIndex,
       let lastExclusive = meta.lastSampleIndexExclusive,
       lastExclusive > first, meta.sampleRateHz > 0
    {
        return Int64((lastExclusive - first) * 1000 / UInt64(meta.sampleRateHz))
    }
    return meta.frameCount * Int64(meta.frameDurationMs)
}
