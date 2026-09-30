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

/// Longer than this and an unattributed sequence skip may not be called "brief".
private let briefSkipLimitMs: Int64 = 60_000

/// Plain-language reason for one gap, told against the length actually shown beside it.
///
/// A receiver-synthesized skip is the one gap this app genuinely cannot attribute: it saw the
/// watch's sequence numbers jump and the watch never said why. Nearly all of them really are a
/// lost notification or two — across Roger's 88-day export the median is 0.9 s and p90 is 14.8 s,
/// which "briefly" describes honestly. But 79 of the 2,690 *display* longer than a minute and
/// together hold 27 h, the largest a single 10 h 30 m hole, and calling that "brief" is the one
/// thing a background-microphone product must not do: the duration is rendered right next to this
/// text, so the copy contradicted the number and made real loss read as a hiccup.
///
/// `displayedDurationMs` must be the length the caller is about to show, which is the gap CLIPPED
/// to the segment's own audio extent (`gapDurationMsWithinSegment`), not `missingFrameCount`. The
/// two differ a lot — 16 gaps in the export run past a minute raw but display under one — so
/// deciding on the raw count would over-claim on exactly those. Pass nil when the length is not
/// known; that keeps the original wording rather than guessing.
///
/// Nothing here invents a cause. The reason is unknown, and the honest form is to drop the claim
/// of brevity, not to name a culprit.
public func gapDescription(_ gap: GapMeta, displayedDurationMs: Int64?) -> String {
    if gap.origin == GapMeta.originSequenceSkip, let shown = displayedDurationMs,
        shown >= briefSkipLimitMs
    {
        return "phone missed audio"
    }
    return gapDescription(gap)
}

/// Calm by design (ux plan: "visible but not alarmist"); gaps are expected in normal use, so no
/// "Gap:"/error framing. Prefer `gapDescription(_:displayedDurationMs:)` wherever the rendered
/// length is known — see its note on why "briefly" needs that length to stay truthful.
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

/// A silence-suppressed gap is audio the watch intentionally skipped because it was below the
/// voice-activity threshold — known-quiet time it withheld to save Bluetooth/battery, not lost
/// audio. The app treats it as silence everywhere, never as a gap, interruption, or error.
public func isSilenceGap(_ gap: GapMeta) -> Bool {
    gapReason(of: gap)?.isSilence == true
}

/// Gaps that should be presented as genuine missing audio, by the one classifier
/// (`SegmentStore.GapClassifier`): not quiet, and not the watch's power-save pause. A small number
/// of field builds could store a receiver-synthesized sequence skip adjacent to the watch's
/// explicit skipped-silence record for the same range; for display the watch's silence reason
/// wins. The raw metadata remains unchanged for diagnostics.
public func visibleLossGaps(_ meta: SegmentMeta) -> [GapMeta] {
    let visibility = GapVisibility(meta.gaps)
    return meta.gaps.filter { visibility.isVisibleLoss($0) }
}

/// The name every StatusUI caller already uses for the one gap classifier. It used to be a second,
/// separate classifier that disagreed with the day strip about the watch's power-save pause (it
/// counted it as loss) — see `SegmentStore/GapClassification.swift`.
public typealias GapVisibility = GapClassifier

public func isVisibleLossGap(_ gap: GapMeta, allGaps: [GapMeta]) -> Bool {
    GapVisibility(allGaps).isVisibleLoss(gap)
}

/// Approximate gap length from missing frame count (20 ms frames).
public func gapDurationMs(_ gap: GapMeta, frameDurationMs: Int) -> Int64 {
    Int64(gap.missingFrameCount) * Int64(frameDurationMs)
}

/// The part of a gap that falls inside the segment's own audio extent.
///
/// A gap record routinely runs past the audio its segment covers, so its full length is not this
/// recording's loss. When the watch's receiver-liveness watchdog trips it STOPS capturing, and on
/// revival it records the whole elapsed pause as one gap — `elapsed_ms / frame_duration` frames,
/// starting one sequence past the last frame it sent — against whatever segment is still open. A
/// four-hour outage therefore lands on the eighteen-minute recording that preceded it, and
/// counting it there made a mostly-intact recording read as "18 min · 18 min missing" (the total
/// saturated `displayGapMs`'s clamp, so the clamp, not the loss, was choosing the number). Time
/// outside the extent is not this recording's audio: it is the hole BETWEEN recordings, and the
/// timeline is where that is shown — `CoverageComputer` draws every loss record where the record
/// says it happened, inside a segment's frames or not, so the outage is on the day strip as
/// "missing" while this row counts only what this recording lost.
///
/// Loss stays explicit: nothing inside the extent is trimmed, and the raw metadata is untouched.
/// A segment with no extent yet (nothing stored) has nothing to clip against, so it counts whole.
public func gapDurationMsWithinSegment(_ gap: GapMeta, _ meta: SegmentMeta) -> Int64 {
    let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
    guard let first = meta.firstSampleIndex,
          let lastExclusive = meta.lastSampleIndexExclusive,
          lastExclusive > first
    else { return gapDurationMs(gap, frameDurationMs: meta.frameDurationMs) }
    let start = gap.firstMissingSampleIndex
    let end = start + UInt64(gap.missingFrameCount) * frameSamples
    let low = max(start, first)
    let high = min(end, lastExclusive)
    guard high > low else { return 0 }
    // Round the overlap up to whole frames so clipping can never under-report loss.
    let frames = (high - low + frameSamples - 1) / frameSamples
    return Int64(frames) * Int64(meta.frameDurationMs)
}

/// Total approximate missing time of a segment (intentionally-skipped silence and the watch's
/// power-save pause excluded, and each gap counted only for the part that overlaps this segment's
/// audio).
public func totalGapMs(_ meta: SegmentMeta) -> Int64 {
    visibleLossGaps(meta).reduce(0) { $0 + gapDurationMsWithinSegment($1, meta) }
}

/// User-facing missing time, guarded against stale/impossible gap metadata.
///
/// Clamped to `displaySegmentDurationMs`, not to the raw wall span: this number is always shown
/// beside that one ("18 min · 4 min missing"), and a recording cannot be missing more time than it
/// claims to be long. The clamp binds in only one direction and never hides loss — recorded loss is
/// a SUBSET of the recorded gap time the display duration already includes.
public func displayGapMs(_ meta: SegmentMeta) -> Int64 {
    let totalMs = totalGapMs(meta)
    let durationMs = displaySegmentDurationMs(meta)
    if totalMs <= 0 { return 0 }
    if durationMs > 0 { return min(totalMs, durationMs) }
    return totalMs
}

/// Wall span of a segment in ms, from the sample counters (gaps included).
///
/// The implementation moved down to `SegmentStore.segmentWallSpanMs` when `SegmentMediaClock`
/// did: the clock has to agree with this to the millisecond or a transcript stamp and the gap
/// row beside it describe different recordings, and the only way to guarantee that is one
/// function. This name stays because it is what every caller already imports.
///
/// This is a PLACEMENT/CLAMP primitive and stays the raw span on purpose. Its callers convert
/// between the two clocks or clip gap offsets into the segment's own timeline
/// (`TranscriptFormatting.collapsedTranscriptGaps`, Ask's excerpt end times); shortening it there
/// would push gap markers off the end of the timeline they belong to and move Ask's citations. For
/// "how long was this recording", which is a different question, use `displaySegmentDurationMs`.
public func segmentDurationMs(_ meta: SegmentMeta) -> Int64 {
    segmentWallSpanMs(meta)
}

/// How long this recording is, for a person reading it.
///
/// The wall span is what the watch's sample counter says elapsed, and the counter keeps running
/// while the BLE link is down — across the real library that is 82 h 15 m (41.4%) of time that no
/// audio and no gap record accounts for. Reporting it as the recording's length is the same
/// phantom-duration lie `ConversationBoundaryDetector.displayExtent` removed for conversations,
/// and this is the per-segment equivalent.
///
/// The honest claim is: the audio we hold, plus the time we have a RECORD of missing (loss and
/// VAD-skipped quiet alike — both really elapsed, and both are gap records), and never more than
/// the counter's own span. When the metadata adds up this is the wall span to within a rounding
/// slack, so a healthy recording reads exactly as it did; when it does not, the excess is dropped
/// rather than presented as recording time.
///
/// It deliberately does NOT fall back to stored audio alone when the records fall short: doing
/// that would erase known loss from the number the loss is reported against, which is the failure
/// mode that once produced "18 min · 18 min missing".
public func displaySegmentDurationMs(_ meta: SegmentMeta) -> Int64 {
    let clock = SegmentMediaClock(meta)
    let accounted = clock.mediaSpanMs + clock.recordedGapMs
    guard clock.wallSpanMs > 0 else { return max(accounted, 0) }
    return max(min(clock.wallSpanMs, accounted), 0)
}
