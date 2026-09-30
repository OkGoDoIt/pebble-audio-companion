import AppDB
import Foundation
import SegmentStore
import StatusUI
import WireProtocol

// The live conversation's timeline — the growing equivalent of the finished conversation's
// player card.
//
// WHY THIS IS A COVERAGE STRIP AND NOT A SCRUBBER
//
// The finished screen's "timeline" is `PlayerCard`: a scrubber over stored MEDIA time with
// amber ticks where audio is missing. Three things make that the wrong object for a
// conversation that is still being written:
//
//  1. Playing it aloud feeds the phone's speaker straight back into the watch microphone that
//     is recording — the app would be recording its own playback, and the person would have no
//     reason to expect that.
//  2. The engine `LiveWorld.playback(id:)` hands back resolves the conversation's pieces ONCE
//     (`pieces(of:)`) and fixes `durationMs` from the sidecars at that instant. A reconnect
//     opens a new member the engine will never see, so the scrubber would quietly stop covering
//     the recording it claims to cover. (`SegmentPlaybackController` does re-read the OPEN
//     segment's frames as they land, so the tail of one member follows along — but only that.)
//  3. A scrubber's whole meaning is "you are here in a fixed span". The span is not fixed. A
//     control whose maximum moves while you hold it is a lie about what it is.
//
// What a person actually wants at the top of a live recording is the shape of what has been
// captured so far and where it broke — which is exactly `CoverageStrip`, the component Today
// already uses for the day. So this maps the conversation's OWN wall-clock span (start → now)
// through the same `CoverageComputer` the day strip uses: recorded, missing, paused and off all
// come from that one computation, and the two surfaces cannot disagree about them.
//
// ONE REFINEMENT ON TOP: the quiet layer.
//
// `CoverageComputer` can only separate VAD quiet from audio when it is handed the frame log's
// sample ranges, and reading the frame log is megabytes on a path that runs every few seconds
// while recording. Today's day strip therefore passes none and counts suppressed silence as
// recorded. On a whole day that overstatement is diluted; on ONE conversation it is the
// headline — a quiet hour-long meeting would read "1 hr recorded" when the watch sent a few
// minutes of speech, on a product whose whole promise is that quiet and loss are never dressed
// up as each other or as audio.
//
// The watch already tells us where it suppressed silence: a reported gap whose reason is
// `silenceSuppressed`, in the sidecar this refresh has already loaded. `applyingQuiet` cuts
// those windows out of the recorded spans and marks them quiet. Nothing else moves — loss,
// pauses and the domain still come from `CoverageComputer` untouched.
//
// (The same refinement would make Today's day strip honest, where the quiet colour is currently
// unreachable from real data and appears only in the artboard sample. Left alone here: that
// strip belongs to Today's own surface.)

/// The growing timeline card's content. Nil'd out entirely when there is nothing to draw yet.
struct LiveTimelineDisplay: Equatable {
    /// e.g. "34 min recorded" — the same phrasing as Today's day coverage card.
    var headline: String
    /// e.g. "2 min missing". Nil when nothing was lost; never a zero.
    var missingText: String?
    /// Left axis label: when this conversation started, in the zone it is being recorded in
    /// (Q16). The right-hand label is always `Copy.Live.timelineNow`.
    var startLabel: String
    var spans: [CoverageSpanDisplay]

    var stripSpans: [CoverageSpan] { spans.map(\.span) }
}

enum LiveTimeline {
    /// How many logical days one conversation's timeline may walk. The grouper splits on a
    /// break of five minutes, so a real conversation is minutes-to-hours; this only bounds the
    /// loop against a pathological grouping rather than describing an expected case.
    static let maxDays = 3

    /// The conversation's span, start → now, as strip-ready fractions.
    ///
    /// Returns nil while there is nothing to say — a window with no recorded, missing or paused
    /// time is a plain grey bar, which is decoration rather than information.
    static func display(
        metas: [SegmentMeta],
        pauses: [PauseInterval],
        startMs: Int64,
        nowMs: Int64,
        timeZone: TimeZone
    ) -> LiveTimelineDisplay? {
        guard nowMs > startMs else { return nil }
        let covered = spans(
            metas: metas, pauses: pauses, startMs: startMs, nowMs: nowMs,
            timeZoneID: timeZone.identifier)
        guard covered.contains(where: { $0.kind != .off }) else { return nil }

        let domain = Double(nowMs - startMs)
        let recordedMs = total(covered, .recorded)
        let missingMs = total(covered, .missing)

        return LiveTimelineDisplay(
            headline: Copy.Today.recorded(Formatting.duration(recordedMs)),
            missingText: missingMs > 0 ? Copy.Today.missing(Formatting.duration(missingMs)) : nil,
            startLabel: clock(startMs, timeZone),
            spans: covered.map { span in
                let lower = Double(span.startMs - startMs) / domain
                let upper = Double(span.endMs - startMs) / domain
                let range = min(max(lower, 0), 1)...min(max(upper, lower), 1)
                return CoverageSpanDisplay(
                    span: CoverageSpan(kind: span.kind.displayKind, range: range),
                    popoverText: popoverText(span, timeZone: timeZone))
            }
        )
    }

    /// The conversation's coverage in wall-clock ms, contiguous and clipped to its own window.
    ///
    /// `CoverageComputer` is keyed on a logical day (5 AM → 5 AM), so a conversation that runs
    /// through the boundary is computed once per day it touches and the pieces are stitched
    /// back together here. Split-and-rejoin rather than a second implementation — recorded,
    /// missing, paused and off must mean the same thing on both strips, and the only way to
    /// guarantee that is to run the same code. `applyingQuiet` is the one layer added after.
    static func spans(
        metas: [SegmentMeta],
        pauses: [PauseInterval],
        startMs: Int64,
        nowMs: Int64,
        timeZoneID: String
    ) -> [AppDB.CoverageSpan] {
        let inputs = metas.map { SegmentCoverageInput(meta: $0) }
        var computed: [AppDB.CoverageSpan] = []
        var key = LogicalDay.dateKey(forMs: startMs, timeZoneID: timeZoneID)
        for _ in 0..<maxDays {
            computed += CoverageComputer.compute(
                dateKey: key, timeZoneID: timeZoneID, segments: inputs, pauses: pauses,
                nowMs: nowMs
            ).spans
            guard let bounds = LogicalDay.bounds(ofDateKey: key, timeZoneID: timeZoneID),
                bounds.endMs < nowMs
            else { break }
            key = LogicalDay.dateKey(forMs: bounds.endMs, timeZoneID: timeZoneID)
        }

        var clipped: [AppDB.CoverageSpan] = []
        for span in computed.sorted(by: { $0.startMs < $1.startMs }) {
            let lower = max(span.startMs, startMs)
            let upper = min(span.endMs, nowMs)
            guard upper > lower else { continue }
            clipped.append(AppDB.CoverageSpan(kind: span.kind, startMs: lower, endMs: upper))
        }
        // Merge LAST, so it rejoins the day-boundary cut, any run the computer emitted in
        // pieces, and anything the quiet pass left abutting. Without it the strip draws one
        // stretch as several rectangles and the popovers name the same minute twice.
        return merged(applyingQuiet(clipped, silence: silenceWindows(metas)))
    }

    /// The windows the watch reported as suppressed silence, in wall-clock ms, merged.
    ///
    /// This is deliberately the WATCH's claim rather than an inference from the frame log: a
    /// `silenceSuppressed` gap is the watch saying "I heard nothing here and did not send it",
    /// which is precisely the calm-quiet case (Q6). Every other gap reason, and any reason we
    /// cannot decode, stays loss — never silently reclassified as quiet.
    static func silenceWindows(_ metas: [SegmentMeta]) -> [Range<Int64>] {
        var windows: [Range<Int64>] = []
        for meta in metas {
            guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
                last > first
            else { continue }
            let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
            for gap in meta.gaps {
                guard gap.origin != GapMeta.originSequenceSkip,
                    let raw = gap.reasonRaw,
                    let reason = UInt8(exactly: raw).flatMap(GapReason.init(rawValue:)),
                    reason.isSilence
                else { continue }
                let lower = max(gap.firstMissingSampleIndex, first)
                let upper = min(
                    gap.firstMissingSampleIndex + UInt64(gap.missingFrameCount) * frameSamples,
                    last)
                guard upper > lower else { continue }
                windows.append(wallMs(lower, in: meta)..<wallMs(upper, in: meta))
            }
        }
        return merged(windows)
    }

    /// Recut the recorded spans so the stretches the watch skipped read as quiet.
    /// `silence` must be sorted and non-overlapping.
    static func applyingQuiet(
        _ spans: [AppDB.CoverageSpan], silence: [Range<Int64>]
    ) -> [AppDB.CoverageSpan] {
        guard !silence.isEmpty else { return spans }
        return spans.flatMap { span -> [AppDB.CoverageSpan] in
            // Only recorded time can turn out to have been quiet. Loss stays loss and a pause
            // stays a pause — quiet inside either would be a claim nothing supports.
            guard span.kind == .recorded else { return [span] }
            var pieces: [AppDB.CoverageSpan] = []
            var cursor = span.startMs
            for window in silence
            where window.upperBound > span.startMs && window.lowerBound < span.endMs {
                let lower = max(window.lowerBound, cursor)
                let upper = min(window.upperBound, span.endMs)
                guard upper > lower else { continue }
                if lower > cursor {
                    pieces.append(
                        AppDB.CoverageSpan(kind: .recorded, startMs: cursor, endMs: lower))
                }
                pieces.append(AppDB.CoverageSpan(kind: .quiet, startMs: lower, endMs: upper))
                cursor = upper
            }
            if cursor < span.endMs {
                pieces.append(
                    AppDB.CoverageSpan(kind: .recorded, startMs: cursor, endMs: span.endMs))
            }
            return pieces.isEmpty ? [span] : pieces
        }
    }

    /// Joins abutting spans of the same kind, in order.
    static func merged(_ spans: [AppDB.CoverageSpan]) -> [AppDB.CoverageSpan] {
        var result: [AppDB.CoverageSpan] = []
        for span in spans {
            if var last = result.last, last.kind == span.kind, last.endMs == span.startMs {
                last.endMs = span.endMs
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Sorts and joins overlapping/touching windows; drops empties. (`AppDB` has this, but it
    /// is internal to the kit.)
    static func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int64>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    result[result.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// The same sample → wall-clock mapping `ConversationGrouper.wallMs` uses, which is
    /// internal to the kit.
    static func wallMs(_ sampleIndex: UInt64, in meta: SegmentMeta) -> Int64 {
        let rate = meta.sampleRateHz > 0 ? UInt64(meta.sampleRateHz) : 16_000
        return Int64(meta.startTimeMs) + Int64(sampleIndex * 1000 / rate)
    }

    static func total(_ spans: [AppDB.CoverageSpan], _ kind: CoverageKind) -> Int64 {
        spans.filter { $0.kind == kind }.map(\.durationMs).reduce(0, +)
    }

    /// Q11's explain-on-tap, in the conversation's own zone. Same vocabulary as the day strip;
    /// loss is named by DURATION (how much went) and everything else by the clock range.
    static func popoverText(_ span: AppDB.CoverageSpan, timeZone: TimeZone) -> String? {
        let range = "\(clock(span.startMs, timeZone))–\(clock(span.endMs, timeZone))"
        switch span.kind {
        case .off: return nil
        case .recorded: return "recorded \(range)"
        case .quiet: return Copy.Popover.quietSpan(range)
        case .missing: return Copy.Popover.missingSpan(Formatting.duration(span.durationMs))
        case .paused: return Copy.Popover.pausedSpan(range)
        }
    }

    /// Q16: every clock time on this screen reads in the zone the audio is being recorded in,
    /// so the strip keeps the times things actually happened at after you fly home.
    static func clock(_ ms: Int64, _ timeZone: TimeZone) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
    }
}
