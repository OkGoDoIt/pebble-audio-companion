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

    /// Visible-loss filter: `sequence_skip` gaps (receiver-synthesized) always count as loss;
    /// watch-reported gaps count unless the reason is SilenceSuppressed (known quiet, not
    /// loss). Unknown reasons count as loss — never silently hidden.
    static func isVisibleLoss(_ gap: GapMeta) -> Bool {
        if gap.origin == GapMeta.originSequenceSkip { return true }
        guard let raw = gap.reasonRaw,
            let reason = UInt8(exactly: raw).flatMap(GapReason.init(rawValue:))
        else { return true }
        return !reason.isSilence
    }

    /// Computes one logical day's coverage. `nowMs` clamps the domain for the current day
    /// ("today so far"); nil renders the full 24 h domain.
    public static func compute(
        dateKey: String,
        timeZoneID: String,
        segments: [SegmentCoverageInput],
        pauses: [PauseInterval],
        nowMs: Int64? = nil
    ) -> DayCoverage {
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: timeZoneID) else {
            return DayCoverage(
                dateKey: dateKey, timeZoneID: timeZoneID, spans: [],
                totalRecordedMs: 0, totalMissingMs: 0)
        }
        let domainStart = bounds.startMs
        let domainEnd = min(bounds.endMs, nowMs ?? bounds.endMs)
        guard domainEnd > domainStart else {
            return DayCoverage(
                dateKey: dateKey, timeZoneID: timeZoneID, spans: [],
                totalRecordedMs: 0, totalMissingMs: 0)
        }
        let domain = domainStart..<domainEnd

        var recorded: [Range<Int64>] = []
        var missing: [Range<Int64>] = []
        var quiet: [Range<Int64>] = []

        for input in segments {
            let meta = input.meta
            guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
                last > first
            else { continue }
            let extent = first..<last
            let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)

            let lossSamples = mergeRanges(
                meta.gaps.filter(isVisibleLoss).compactMap { gap -> Range<UInt64>? in
                    let start = gap.firstMissingSampleIndex
                    let end = start + UInt64(gap.missingFrameCount) * frameSamples
                    return clip(start..<end, to: extent)
                }
            )

            let recordedSamples: [Range<UInt64>]
            let quietSamples: [Range<UInt64>]
            if let frameRanges = input.frameSampleRanges {
                let frames = mergeRanges(frameRanges.compactMap { clip($0, to: extent) })
                recordedSamples = frames
                quietSamples = subtractRanges(
                    [extent], subtracting: mergeRanges(frames + lossSamples))
            } else {
                recordedSamples = subtractRanges([extent], subtracting: lossSamples)
                quietSamples = []
            }

            func toWall(_ ranges: [Range<UInt64>]) -> [Range<Int64>] {
                ranges.compactMap { range in
                    let start = ConversationGrouper.wallMs(ofSample: range.lowerBound, in: meta)
                    let end = ConversationGrouper.wallMs(ofSample: range.upperBound, in: meta)
                    return clip(start..<end, to: domain)
                }
            }
            recorded += toWall(recordedSamples)
            missing += toWall(lossSamples)
            quiet += toWall(quietSamples)
        }

        let paused = pauses.compactMap { pause -> Range<Int64>? in
            let end = pause.endMs ?? domainEnd
            guard end > pause.startMs else { return nil }
            return clip(pause.startMs..<end, to: domain)
        }

        let layers: [(kind: CoverageKind, ranges: [Range<Int64>])] = [
            (.recorded, mergeRanges(recorded)),
            (.paused, mergeRanges(paused)),
            (.missing, mergeRanges(missing)),
            (.quiet, mergeRanges(quiet)),
        ]

        // Flatten: at every elementary interval the highest-priority covering layer wins;
        // uncovered time is off. Output covers the whole domain contiguously.
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
        return DayCoverage(
            dateKey: dateKey, timeZoneID: timeZoneID, spans: spans,
            totalRecordedMs: totalRecorded, totalMissingMs: totalMissing)
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
