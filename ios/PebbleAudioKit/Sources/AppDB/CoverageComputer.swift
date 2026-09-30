import Foundation
import GRDB
import SegmentStore
import WireProtocol

// Day coverage (plan 6.2). Per logical day — 5 AM to 5 AM in the recorded zone — the strip
// shows: recorded (persisted frames), missing (visible loss — NEVER silence), quiet (VAD
// holes: sample-index ranges covered by neither frames nor loss gaps; the watch advances
// sample indexes across suppressed silence so these holes ARE the quiet spans), paused
// (pause_intervals), and off (the remainder). Pure computation, cached in `coverage_days`.

/// Coverage taxonomy. Paused is its own state — never rendered as missing (plan 6.1).
public enum CoverageKind: String, Codable, Sendable {
    case recorded, quiet, missing, paused, off
}

public struct CoverageSpan: Codable, Equatable, Sendable {
    public var kind: CoverageKind
    public var startMs: Int64
    public var endMs: Int64

    public init(kind: CoverageKind, startMs: Int64, endMs: Int64) {
        self.kind = kind
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int64 { endMs - startMs }
}

/// One computed logical day: contiguous spans covering 5 AM → 5 AM (or → now for the current
/// day) plus the summary-string inputs.
public struct DayCoverage: Equatable, Sendable {
    public var dateKey: String
    public var timeZoneID: String
    public var spans: [CoverageSpan]
    public var totalRecordedMs: Int64
    public var totalMissingMs: Int64

    public init(
        dateKey: String, timeZoneID: String, spans: [CoverageSpan],
        totalRecordedMs: Int64, totalMissingMs: Int64
    ) {
        self.dateKey = dateKey
        self.timeZoneID = timeZoneID
        self.spans = spans
        self.totalRecordedMs = totalRecordedMs
        self.totalMissingMs = totalMissingMs
    }
}

/// One gap record as coverage placed it: the wall-clock range it painted (clipped to the day and
/// bounded by its segment's close exactly as the layer is), and the record itself.
public struct CoverageGapRecord: Equatable, Sendable {
    public var range: Range<Int64>
    public var segmentId: String
    public var gap: GapMeta

    public init(range: Range<Int64>, segmentId: String, gap: GapMeta) {
        self.range = range
        self.segmentId = segmentId
        self.gap = gap
    }
}

/// One pause-journal row as coverage placed it (an open pause runs to the domain's end).
public struct CoveragePauseRecord: Equatable, Sendable {
    public var range: Range<Int64>
    /// The journal's `source` (`PauseSource.rawValue`, or whatever an older build wrote).
    public var source: String

    public init(range: Range<Int64>, source: String) {
        self.range = range
        self.source = source
    }
}

/// A day's coverage together with what it was drawn from.
///
/// `coverage` is exactly what `CoverageComputer.compute` returns. The record lists are clipped to
/// `domain` and are NOT flattened: a loss record under recorded audio, or under a pause, is
/// still listed, because the priority that hides it belongs to `coverage.spans`. A reader asks
/// "which records overlap this missing span" and gets only the ones that can explain it.
public struct AttributedDayCoverage: Equatable, Sendable {
    public var coverage: DayCoverage
    /// The computed domain (5 AM → 5 AM, or → now); nil when the day has none.
    public var domain: Range<Int64>?
    /// Every visible-loss record (`GapClassifier` class `.loss`), each at its own placed range.
    public var lossRecords: [CoverageGapRecord]
    /// Every watch power-save record (`GapClassifier` class `.watchPause`), placed the same way.
    public var watchPauseRecords: [CoverageGapRecord]
    /// The pause journal's rows, clipped to the domain.
    public var pauseRecords: [CoveragePauseRecord]
    /// Watch-reported suppressed silence (`CoverageComputer.silenceWindows`), clipped to the
    /// domain, merged.
    public var silence: [Range<Int64>]

    public init(
        coverage: DayCoverage, domain: Range<Int64>?, lossRecords: [CoverageGapRecord],
        watchPauseRecords: [CoverageGapRecord], pauseRecords: [CoveragePauseRecord],
        silence: [Range<Int64>]
    ) {
        self.coverage = coverage
        self.domain = domain
        self.lossRecords = lossRecords
        self.watchPauseRecords = watchPauseRecords
        self.pauseRecords = pauseRecords
        self.silence = silence
    }

    /// `coverage.spans` with the watch-reported silence cut out of recorded time as quiet —
    /// what Today's strip and the Live timeline draw.
    public var spansWithWatchQuiet: [CoverageSpan] {
        CoverageComputer.applyingQuiet(coverage.spans, silence: silence)
    }
}

/// One segment's contribution to coverage: its meta plus (optionally) the sample-index ranges
/// its persisted frames cover, read from the frame log. Without frame ranges the whole extent
/// minus loss gaps counts as recorded (no quiet detection — used where the log wasn't read).
public struct SegmentCoverageInput: Sendable {
    public var meta: SegmentMeta
    public var frameSampleRanges: [Range<UInt64>]?

    public init(meta: SegmentMeta, frameSampleRanges: [Range<UInt64>]? = nil) {
        self.meta = meta
        self.frameSampleRanges = frameSampleRanges
    }

    /// Builds the merged frame-coverage ranges from raw frame records (each frame covers
    /// `frameSamples` samples from its sample index).
    public static func from(meta: SegmentMeta, frames: [FrameRecord]) -> SegmentCoverageInput {
        let samples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
        let ranges = frames.map { $0.sampleIndex..<($0.sampleIndex + samples) }
        return SegmentCoverageInput(meta: meta, frameSampleRanges: mergeRanges(ranges))
    }
}

/// The 5 AM logical-day boundary, evaluated in a specific IANA zone (Q16).
public enum LogicalDay {
    public static let boundaryHour = 5

    static func calendar(_ timeZoneID: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return cal
    }

    /// The `YYYY-MM-DD` key of the logical day containing the given wall-clock moment.
    public static func dateKey(forMs ms: Int64, timeZoneID: String) -> String {
        let cal = calendar(timeZoneID)
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        var dayStart = cal.date(
            from: DateComponents(year: comps.year, month: comps.month, day: comps.day))!
        if let hour = comps.hour, hour < boundaryHour {
            dayStart = cal.date(byAdding: .day, value: -1, to: dayStart)!
        }
        let day = cal.dateComponents([.year, .month, .day], from: dayStart)
        return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
    }

    /// [5 AM of the keyed date, 5 AM of the next date) in the zone, as epoch ms.
    public static func bounds(
        ofDateKey dateKey: String, timeZoneID: String
    ) -> (startMs: Int64, endMs: Int64)? {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let cal = calendar(timeZoneID)
        guard
            let start = cal.date(
                from: DateComponents(
                    year: parts[0], month: parts[1], day: parts[2], hour: boundaryHour)),
            let nextDay = cal.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(nextDay.timeIntervalSince1970 * 1000))
    }
}

public enum CoverageComputer {
    /// Priority when spans overlap (lower wins): recorded audio is recorded no matter what;
    /// paused beats missing ("paused, not missing") and quiet; loss beats quiet.
    static func priority(_ kind: CoverageKind) -> Int {
        switch kind {
        case .recorded: return 0
        case .paused: return 1
        case .missing: return 2
        case .quiet: return 3
        case .off: return 4
        }
    }

    /// How far past its segment's close a loss record may still be drawn: the watch's clock,
    /// which places the record, and the phone's, which stamped the close, drift by tens of
    /// seconds (±32 s across the real library — see `SegmentStore.openSegmentInternal`).
    static let recordAfterCloseSlackMs: Int64 = 60_000

    // Which gap records are loss, which are the watch's own pause, and which are quiet is decided
    // by `SegmentStore.GapClassifier` — the same classifier the transcript, the per-recording
    // missing time, Ask and the loss notification use, so a minute cannot be "paused" here and
    // "missing" in the recording it belongs to.
    //
    // - Loss: every receiver `sequence_skip` except one that a single watch-reported silence
    //   record fully covers (that is quiet — a duplicate a few field builds stored); every
    //   watch-reported reason other than silence and power-save, and any reason we cannot decode.
    //   Never silently hidden.
    // - The watch's own power-save pause: a stretch it CHOSE not to listen to (stationary mute —
    //   the phone's status card already says "Paused while the watch is saving power"). Drawn as
    //   paused, never as missing: a night on the nightstand is not lost audio, and the 2026-09-29
    //   backup would otherwise have drawn 45 h of it as loss (570 min on 09-22 alone).

    /// Computes one logical day's coverage. `nowMs` clamps the domain for the current day
    /// ("today so far"); nil renders the full 24 h domain.
    public static func compute(
        dateKey: String,
        timeZoneID: String,
        segments: [SegmentCoverageInput],
        pauses: [PauseInterval],
        nowMs: Int64? = nil
    ) -> DayCoverage {
        computeAttributed(
            dateKey: dateKey, timeZoneID: timeZoneID, segments: segments, pauses: pauses,
            nowMs: nowMs
        ).coverage
    }

    /// `compute`, plus the records each span was drawn from — for a reader that has to say WHY
    /// a stretch is missing or paused, not merely that it is (History's day, plan 7.10).
    ///
    /// This is the same computation, not a second one: `compute` is this function's `coverage`,
    /// to the millisecond (`CoverageAttributionTests` pins that against the previous
    /// implementation over fuzzed days). The attribution lists are collected on the way through
    /// the very placement code that builds the layers, so a record can never be credited with a
    /// range the strip did not draw for it.
    public static func computeAttributed(
        dateKey: String,
        timeZoneID: String,
        segments: [SegmentCoverageInput],
        pauses: [PauseInterval],
        nowMs: Int64? = nil
    ) -> AttributedDayCoverage {
        let empty = AttributedDayCoverage(
            coverage: DayCoverage(
                dateKey: dateKey, timeZoneID: timeZoneID, spans: [],
                totalRecordedMs: 0, totalMissingMs: 0),
            domain: nil, lossRecords: [], watchPauseRecords: [], pauseRecords: [], silence: [])
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: timeZoneID) else {
            return empty
        }
        let domainStart = bounds.startMs
        let domainEnd = min(bounds.endMs, nowMs ?? bounds.endMs)
        guard domainEnd > domainStart else { return empty }
        let domain = domainStart..<domainEnd

        var recorded: [Range<Int64>] = []
        var missing: [Range<Int64>] = []
        var quiet: [Range<Int64>] = []
        var watchPaused: [Range<Int64>] = []
        var lossRecords: [CoverageGapRecord] = []
        var watchPauseRecords: [CoverageGapRecord] = []

        for input in segments {
            let meta = input.meta
            let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
            func toWall(_ ranges: [Range<UInt64>]) -> [Range<Int64>] {
                ranges.compactMap { range in
                    let start = ConversationGrouper.wallMs(ofSample: range.lowerBound, in: meta)
                    let end = ConversationGrouper.wallMs(ofSample: range.upperBound, in: meta)
                    return clip(start..<end, to: domain)
                }
            }

            // Loss is drawn where its RECORD says it happened — not clipped to this segment's
            // frames, which is what it used to be.
            //
            // A record can lie wholly outside the frames of the segment that carries it, and the
            // ordinary way is a RESUME that had to open a NEW segment: the watch delivers its
            // account of the outage (overflow, a transport reset, a power-save pause) before the
            // first frame of the recording that follows it. Clipped, all of that rendered as
            // "off" — time nothing was recording — instead of "missing". The 2026-09-29 backup
            // holds 35 such records: 12 buffer overflows (71,046 frames, 23.7 min; one is the
            // 10-minute overflow of 09-20 14:53:44-15:03:43) and 23 power-save pauses (45 h),
            // while the same reasons INSIDE a segment's frames always rendered as missing.
            //
            // Nothing is invented: the painted range is exactly the record's own. The one bound is
            // physical — a record describes time before the phone wrote it, so it cannot reach
            // past the segment's close (plus the watch/phone clock skew the rest of the timeline
            // already tolerates); that keeps one corrupt count from painting a whole day.
            let closeBound = meta.closedAtMs.map { $0 + Self.recordAfterCloseSlackMs }
            let classifier = GapClassifier(meta.gaps)
            func samples(of gap: GapMeta) -> Range<UInt64> {
                let start = gap.firstMissingSampleIndex
                return start..<(start + UInt64(gap.missingFrameCount) * frameSamples)
            }
            func bounded(_ range: Range<Int64>) -> Range<Int64>? {
                guard let closeBound else { return range }
                return clip(range, to: range.lowerBound..<max(range.lowerBound, closeBound))
            }
            // Each record placed on its own, by the same two steps the layer takes (to the wall
            // clock, clipped to the domain; then bounded by the close). The layer below is the
            // union of these; the list is what lets a reader name a missing span's causes.
            func attributed(_ gaps: [GapMeta]) -> [CoverageGapRecord] {
                gaps.compactMap { gap in
                    guard let placed = toWall([samples(of: gap)]).first, let range = bounded(placed)
                    else { return nil }
                    return CoverageGapRecord(range: range, segmentId: meta.segmentId, gap: gap)
                }
            }
            let lossGaps = meta.gaps.filter { classifier.classify($0) == .loss && $0.missingFrameCount > 0 }
            let lossSamples = mergeRanges(lossGaps.map(samples(of:)))
            missing += toWall(lossSamples).compactMap(bounded)
            lossRecords += attributed(lossGaps)
            // The watch's power-save pauses, placed exactly like loss and bounded the same way.
            let pauseGaps = meta.gaps.filter { classifier.classify($0) == .watchPause && $0.missingFrameCount > 0 }
            let pausedSamples = mergeRanges(pauseGaps.map(samples(of:)))
            watchPaused += toWall(pausedSamples).compactMap(bounded)
            watchPauseRecords += attributed(pauseGaps)

            // Recorded and quiet are claims about THIS segment's own span, and stay inside it.
            guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
                last > first
            else { continue }
            let extent = first..<last
            // A pause inside the recording is no more quiet than loss is: neither was heard.
            let lossInExtent = mergeRanges(lossSamples + pausedSamples).compactMap { clip($0, to: extent) }

            let recordedSamples: [Range<UInt64>]
            let quietSamples: [Range<UInt64>]
            if let frameRanges = input.frameSampleRanges {
                let frames = mergeRanges(frameRanges.compactMap { clip($0, to: extent) })
                recordedSamples = frames
                quietSamples = subtractRanges(
                    [extent], subtracting: mergeRanges(frames + lossInExtent))
            } else {
                recordedSamples = subtractRanges([extent], subtracting: lossInExtent)
                quietSamples = []
            }
            recorded += toWall(recordedSamples)
            quiet += toWall(quietSamples)
        }

        let pauseRecords = pauses.compactMap { pause -> CoveragePauseRecord? in
            let end = pause.endMs ?? domainEnd
            guard end > pause.startMs, let range = clip(pause.startMs..<end, to: domain) else {
                return nil
            }
            return CoveragePauseRecord(range: range, source: pause.source)
        }
        let paused = pauseRecords.map(\.range) + watchPaused

        let layers: [(kind: CoverageKind, ranges: [Range<Int64>])] = [
            (.recorded, mergeRanges(recorded)),
            (.paused, mergeRanges(paused)),
            (.missing, mergeRanges(missing)),
            (.quiet, mergeRanges(quiet)),
        ]

        // Flatten: at every elementary interval the highest-priority covering layer wins;
        // uncovered time is off. Output covers the whole domain contiguously.
        //
        // Every boundary is tested against every range, which looks quadratic, and was measured
        // before anyone rewrote it (2026-09-30, the 2026-09-30 backup, every segment of the
        // library passed in): the heaviest day (09-24, 964 spans from ~2,000 spool-overflow
        // records) costs 0.8 ms in a release build and 39 ms in a debug one; a typical day
        // 0.5 ms. The layers are merged first, so the ranges stay in the hundreds.
        var boundaries: Set<Int64> = [domainStart, domainEnd]
        for layer in layers {
            for range in layer.ranges {
                boundaries.insert(range.lowerBound)
                boundaries.insert(range.upperBound)
            }
        }
        let sorted = boundaries.sorted()
        var spans: [CoverageSpan] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            let kind =
                layers
                .filter { layer in layer.ranges.contains { $0.lowerBound <= a && $0.upperBound >= b } }
                .min { priority($0.kind) < priority($1.kind) }?.kind ?? .off
            if let lastSpan = spans.last, lastSpan.kind == kind, lastSpan.endMs == a {
                spans[spans.count - 1].endMs = b
            } else {
                spans.append(CoverageSpan(kind: kind, startMs: a, endMs: b))
            }
        }

        let totalRecorded = spans.filter { $0.kind == .recorded }.map(\.durationMs).reduce(0, +)
        let totalMissing = spans.filter { $0.kind == .missing }.map(\.durationMs).reduce(0, +)
        return AttributedDayCoverage(
            coverage: DayCoverage(
                dateKey: dateKey, timeZoneID: timeZoneID, spans: spans,
                totalRecordedMs: totalRecorded, totalMissingMs: totalMissing),
            domain: domain,
            lossRecords: lossRecords,
            watchPauseRecords: watchPauseRecords,
            pauseRecords: pauseRecords,
            silence: mergeRanges(silenceWindows(segments.map(\.meta)).compactMap { clip($0, to: domain) })
        )
    }

    // --- the watch-reported quiet layer -------------------------------------------------------
    //
    // `compute` can only separate VAD quiet from audio when it is handed the frame log's sample
    // ranges, and reading the frame log is megabytes on paths that run every few seconds — so
    // Today, the Live timeline and History pass none, and everything the watch chose not to send
    // counts as RECORDED. The watch already says where it suppressed silence (a reported gap
    // whose reason is `silenceSuppressed`), so the recut below turns those windows back into
    // quiet. It began life in the app (`LiveTimeline.silenceWindows` / `applyingQuiet`, which
    // Today's day strip runs too); this is the same code, moved down so History's day builder
    // cuts the same minutes the same way. `CoverageAttributionTests` pins the two together.

    /// The windows the watch reported as suppressed silence, in wall-clock ms, clipped to each
    /// segment's own extent, merged.
    ///
    /// Deliberately the WATCH's claim rather than an inference from the frame log: a
    /// `silenceSuppressed` gap is the watch saying "I heard nothing here and did not send it",
    /// which is precisely the calm-quiet case. Every other reason, and any reason we cannot
    /// decode, stays loss — never silently reclassified as quiet.
    public static func silenceWindows(_ metas: [SegmentMeta]) -> [Range<Int64>] {
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
                windows.append(
                    ConversationGrouper.wallMs(ofSample: lower, in: meta)
                        ..< ConversationGrouper.wallMs(ofSample: upper, in: meta))
            }
        }
        return mergeRanges(windows)
    }

    /// Recuts recorded spans so the stretches the watch skipped read as quiet, then joins
    /// abutting spans of the same kind. `silence` must be sorted and non-overlapping (as
    /// `silenceWindows` returns it). Only recorded time can turn out to have been quiet: loss
    /// stays loss and a pause stays a pause — quiet inside either is a claim nothing supports.
    ///
    /// One pass over both lists (both are in time order), so a day's thousands of silence
    /// records cost a merge, not spans × records.
    public static func applyingQuiet(
        _ spans: [CoverageSpan], silence: [Range<Int64>]
    ) -> [CoverageSpan] {
        var pieces: [CoverageSpan] = []
        pieces.reserveCapacity(spans.count)
        var windowIndex = 0
        for span in spans {
            guard span.kind == .recorded, !silence.isEmpty else {
                pieces.append(span)
                continue
            }
            while windowIndex < silence.count, silence[windowIndex].upperBound <= span.startMs {
                windowIndex += 1
            }
            var cursor = span.startMs
            var index = windowIndex
            while index < silence.count, silence[index].lowerBound < span.endMs {
                let lower = max(silence[index].lowerBound, cursor)
                let upper = min(silence[index].upperBound, span.endMs)
                if upper > lower {
                    if lower > cursor {
                        pieces.append(CoverageSpan(kind: .recorded, startMs: cursor, endMs: lower))
                    }
                    pieces.append(CoverageSpan(kind: .quiet, startMs: lower, endMs: upper))
                    cursor = upper
                }
                index += 1
            }
            if cursor < span.endMs {
                pieces.append(CoverageSpan(kind: .recorded, startMs: cursor, endMs: span.endMs))
            }
        }
        var merged: [CoverageSpan] = []
        merged.reserveCapacity(pieces.count)
        for span in pieces {
            if let last = merged.last, last.kind == span.kind, last.endMs == span.startMs {
                merged[merged.count - 1].endMs = span.endMs
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// "Today so far": the logical day containing `nowMs`, rendered 5 AM → now.
    public static func todaySoFar(
        nowMs: Int64,
        timeZoneID: String,
        segments: [SegmentCoverageInput],
        pauses: [PauseInterval]
    ) -> DayCoverage {
        compute(
            dateKey: LogicalDay.dateKey(forMs: nowMs, timeZoneID: timeZoneID),
            timeZoneID: timeZoneID, segments: segments, pauses: pauses, nowMs: nowMs)
    }
}

// --- integer range set helpers ----------------------------------------------------------------

func clip<T: Comparable>(_ range: Range<T>, to domain: Range<T>) -> Range<T>? {
    let lower = max(range.lowerBound, domain.lowerBound)
    let upper = min(range.upperBound, domain.upperBound)
    guard upper > lower else { return nil }
    return lower..<upper
}

/// Sorts and merges overlapping/touching ranges; drops empties.
func mergeRanges<T: Comparable>(_ ranges: [Range<T>]) -> [Range<T>] {
    let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
    var result: [Range<T>] = []
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

/// `base` minus `subtracting` (both need not be merged; result is merged and ordered).
func subtractRanges<T: Comparable>(
    _ base: [Range<T>], subtracting: [Range<T>]
) -> [Range<T>] {
    let holes = mergeRanges(subtracting)
    var result: [Range<T>] = []
    for range in mergeRanges(base) {
        var cursor = range.lowerBound
        for hole in holes where hole.upperBound > range.lowerBound && hole.lowerBound < range.upperBound {
            if hole.lowerBound > cursor {
                result.append(cursor..<hole.lowerBound)
            }
            cursor = max(cursor, hole.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound {
            result.append(cursor..<range.upperBound)
        }
    }
    return result
}
