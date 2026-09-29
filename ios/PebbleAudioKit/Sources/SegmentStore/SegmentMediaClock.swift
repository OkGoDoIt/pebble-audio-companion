import Foundation

// The two clocks a recording has, and the exact conversion between them.
//
// WHY THIS IS IN SegmentStore RATHER THAN THE APP LAYER
//
// It began life in `App/Runtime/TranscriptItems.swift`, built for the conversation screen's
// playback follow-along. But the same conversion is needed by three other consumers that sit
// BELOW the app layer — the conversation-boundary detector (`AppDB`), the transcript renderer
// (`SearchKit`) and Ask's citation targets — and the rule in this codebase is one
// implementation per idea (see the note at the top of `SearchKit/TranscriptFormatting.swift`
// about the gap classifier that was copied and then drifted). SegmentStore is the lowest module
// every one of those depends on, so this is where it can be shared without a new edge.
//
// WHY IT SUDDENLY MATTERS MORE THAN IT DID
//
// Watch-side silence suppression (`GapReason.silenceSuppressed`) had fired zero times in 88
// days because its entry rule was unsatisfiable on a wrist; PebbleOS a47acac74 fixed that. The
// firmware's own simulation over 116.5 h of this watch's recordings puts the new behaviour at
// 4.1% / 8.7% / 13.8% of airtime withheld (light / balanced / aggressive) across 60-200
// suppression episodes an hour. Every one of those is time that really elapsed and holds no
// stored frames — so the difference between the two clocks below stops being a rounding detail
// and becomes minutes per segment. Measured over the real library with suppression synthesised
// at the firmware's own rates: the last word of a segment lands a median of 7.5 s early in
// light mode (p90 67 s, worst 21.8 min) and a median of 54.9 s early in aggressive mode.

/// Wall time the segment spans, from its sample extents — quiet and lost audio included,
/// because the watch's sample counter keeps running through both.
///
/// The primitive, so `StatusUI.segmentDurationMs` and this clock cannot disagree.
public func segmentWallSpanMs(_ meta: SegmentMeta) -> Int64 {
    if let first = meta.firstSampleIndex,
        let lastExclusive = meta.lastSampleIndexExclusive,
        lastExclusive > first, meta.sampleRateHz > 0
    {
        return Int64((lastExclusive - first) * 1000 / UInt64(meta.sampleRateHz))
    }
    return meta.frameCount * Int64(meta.frameDurationMs)
}

/// Audio the segment actually holds — frames on disk. This is the player's clock, and the clock
/// a provider's timings are on, because `TranscriptionProcessor.segmentPcmSource` decodes the
/// frame log and nothing else. The difference from `segmentWallSpanMs` is exactly the audio
/// that never reached the log, whether it was lost or deliberately skipped.
public func segmentStoredAudioMs(_ meta: SegmentMeta) -> Int64 {
    let frames = meta.frameCount * Int64(meta.frameDurationMs)
    return frames > 0 ? frames : segmentWallSpanMs(meta)
}

/// Converts one segment's two clocks into each other using its own gap records.
///
/// Media time is wall time minus everything that was never stored — lost audio and VAD-skipped
/// silence alike, since neither reaches the frame log. Both directions are therefore exact
/// arithmetic over the gap spans, not the proportional guess this replaced: proportionally, a
/// point 40% through a member's wall span is 40% through its stored audio, which is only true
/// when the gaps happen to be spread evenly. On a real recording — where the quiet hours are
/// one long gap and the talking is another — it is wrong by minutes.
///
/// Gap records overlap routinely (a sequence-skip inside a silence-suppressed span records
/// both), so the spans are unioned before anything is counted; summing raw durations would
/// double-count and push media time negative.
///
/// Both kinds of gap are treated identically HERE and nowhere else. For the arithmetic of "how
/// much stored audio precedes this instant" the cause is irrelevant: neither quiet nor loss is
/// in the frame log. For presentation the two are never conflated — quiet is calm, loss is
/// explicit — and that separation lives in `StatusUI` and the transcript renderer.
public struct SegmentMediaClock: Sendable {
    public let wallSpanMs: Int64
    public let mediaSpanMs: Int64

    /// Unioned gap spans in wall ms since the segment's first sample.
    private let starts: [Int64]
    private let ends: [Int64]
    /// Gap time already closed BEFORE span i, and the media time consumed when span i begins.
    private let closedBefore: [Int64]
    private let mediaAtStart: [Int64]
    /// False when the gap records do not account for the wall/media difference (truncated
    /// sidecars, metadata written by an older build). The proportional mapping is then still
    /// the best available guess, and pretending otherwise would be the actual lie.
    public let isExact: Bool

    /// Total time the segment's gap records account for, after unioning them — quiet and loss
    /// together, which is the only way to add them up without double-counting a sequence skip
    /// recorded inside a suppressed span.
    ///
    /// Exposed because `mediaSpanMs + recordedGapMs` is the part of the wall span this recording
    /// can actually vouch for: audio we hold, plus time we have a record of missing. Anything
    /// beyond that is the phantom duration (`isExact` is exactly the test "is there any"), and
    /// `StatusUI.displaySegmentDurationMs` is where that distinction becomes a number on a screen.
    public let recordedGapMs: Int64

    public init(_ meta: SegmentMeta) {
        let wall = max(segmentWallSpanMs(meta), 0)
        let media = segmentStoredAudioMs(meta)
        wallSpanMs = wall
        mediaSpanMs = media

        let rate = Int64(max(meta.sampleRateHz, 1))
        var raw: [(Int64, Int64)] = []
        raw.reserveCapacity(meta.gaps.count)
        for gap in meta.gaps {
            let anchor = meta.firstSampleIndex ?? gap.firstMissingSampleIndex
            // Where the gap starts relative to the first sample — NEGATIVE for a record that
            // begins before this recording did. Only the part inside the span is on these clocks.
            //
            // This used to clamp such a record's start to zero and keep its whole length, so a
            // record of the outage BEFORE the recording (the watch's account of it, delivered
            // after a RESUME that had to open a new segment — 35 records in the 2026-09-29
            // backup, one of them eight hours of power save) was read as the recording's own
            // opening being missing. The clock then either shifted every stamp by the gap's
            // length or, when that could not add up, fell back to the proportional guess — and
            // `recordedGapMs` counted time that is not this recording's.
            let offset: Int64 =
                gap.firstMissingSampleIndex >= anchor
                ? Int64(gap.firstMissingSampleIndex - anchor) * 1_000 / rate
                : -(Int64(anchor - gap.firstMissingSampleIndex) * 1_000 / rate)
            let duration = max(Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs), 0)
            let start = min(max(offset, 0), wall)
            let end = min(offset + duration, wall)
            if end > start { raw.append((start, end)) }
        }
        raw.sort { $0.0 < $1.0 }

        var mergedStarts: [Int64] = []
        var mergedEnds: [Int64] = []
        for span in raw {
            if let last = mergedEnds.last, span.0 <= last {
                if span.1 > last { mergedEnds[mergedEnds.count - 1] = span.1 }
            } else {
                mergedStarts.append(span.0)
                mergedEnds.append(span.1)
            }
        }
        starts = mergedStarts
        ends = mergedEnds

        var closed: [Int64] = []
        var atStart: [Int64] = []
        closed.reserveCapacity(mergedStarts.count)
        atStart.reserveCapacity(mergedStarts.count)
        var running: Int64 = 0
        for index in mergedStarts.indices {
            closed.append(running)
            atStart.append(max(mergedStarts[index] - running, 0))
            running += mergedEnds[index] - mergedStarts[index]
        }
        closedBefore = closed
        mediaAtStart = atStart
        recordedGapMs = running
        // 5% (or 2 s, whichever is larger) of slack: gap durations are frame-quantized and the
        // wall span is sample-derived, so they never agree to the millisecond.
        isExact = abs((wall - running) - media) <= max(2_000, media / 20)
    }

    /// Where a wall offset into the segment lands on the scrubber.
    public func media(fromWall wallMs: Int64) -> Int64 {
        guard mediaSpanMs > 0, wallSpanMs > 0 else { return 0 }
        let point = min(max(wallMs, 0), wallSpanMs)
        guard isExact else { return mediaSpanMs * point / wallSpanMs }
        guard let index = lastIndex(in: starts, notAfter: point) else {
            return min(point, mediaSpanMs)
        }
        let insideThisGap = min(max(point - starts[index], 0), ends[index] - starts[index])
        let skipped = closedBefore[index] + insideThisGap
        return min(max(point - skipped, 0), mediaSpanMs)
    }

    /// Where a scrubber position sits on the wall clock — what a transcript stamp reads.
    public func wall(fromMedia mediaMs: Int64) -> Int64 {
        guard mediaSpanMs > 0, wallSpanMs > 0 else { return 0 }
        let point = min(max(mediaMs, 0), mediaSpanMs)
        guard isExact else { return wallSpanMs * point / mediaSpanMs }
        guard let index = lastIndex(in: mediaAtStart, notAfter: point) else {
            return min(point, wallSpanMs)
        }
        // Media time does not advance during a gap, so a media instant at or past a gap's start
        // is on the far side of it: the whole span has elapsed.
        let skipped = closedBefore[index] + (ends[index] - starts[index])
        return min(point + skipped, wallSpanMs)
    }

    /// Last index whose value is <= `value`; nil when the array is empty or starts after it.
    private func lastIndex(in values: [Int64], notAfter value: Int64) -> Int? {
        guard let first = values.first, first <= value else { return nil }
        var low = 0
        var high = values.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if values[mid] <= value {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
