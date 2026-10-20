import Foundation
import SegmentStore

/// Which time zone was in effect at any moment of the library, and therefore which logical day
/// (5 AM → 5 AM, `LogicalDay`) that moment belongs to.
///
/// Built from the segments' own `recordedTimeZone` stamps (every segment opened since 64aff4f
/// carries one). The rule, and why:
///
/// - **The zone at a moment is the zone of the latest segment that STARTED at or before it**:
///   its stamp, or `currentZoneID` when it has none. Change points are therefore segment starts.
///   Inside a segment this is exactly what every other consumer already does per segment
///   (`meta.recordedTimeZone ?? currentZone` — the grouper, coverage, recaps, Ask), so History
///   can never file a recording under a different day than the rest of the app does. Between
///   recordings the last known zone carries forward until the next recording says otherwise:
///   nothing records where the phone was in between, and "where it last was" is the least
///   surprising guess.
/// - **An unstamped segment means `currentZoneID`, and is a change point like any other.** It is
///   tempting to carry the nearest stamp over legacy data instead, but that would disagree with
///   every other surface about the very same recording, and legacy data is not rare stretches
///   between stamps: it is everything recorded before the stamp shipped (863 of 866 segments in
///   the 2026-09-30 backup), with a handful of importer-stamped segments inside it. Carrying one
///   of those stamps forward would re-date weeks of unstamped audio. So legacy data is dated in
///   the phone's current zone, as it is everywhere else; that re-dates it when the phone changes
///   zone, which is the known, unfixable cost of recordings that never said where they were made.
/// - **Before the first segment**, the first segment's zone (so the first day's 5 AM is in the
///   zone of its first recording). With no segments at all, `currentZoneID`.
/// - **A stamp that is not a zone identifier** is treated as no stamp. (`LogicalDay` would
///   otherwise quietly fall back to `TimeZone.current` for it, which is what `currentZoneID`
///   stands for.)
///
/// Overlapping segments stamped with different zones would make the later-starting one win for
/// the overlap. The stamp is taken from the phone's zone when a segment opens, so that needs the
/// zone to change while two segments are open at once; it is not a shape the library has.
public struct ZoneTimeline: Sendable {
    /// Zone change points: `starts[i]` is where `zones[i]` takes effect. Consecutive equal zones
    /// are collapsed, so every entry is a real change. Never empty; `starts[0]` is a placeholder,
    /// since the first zone also applies to everything before it.
    private let starts: [Int64]
    private let zones: [String]

    public init(segments: [SegmentMeta], currentZoneID: String) {
        let ordered = segments
            .map { (startMs: $0.startWallMs, id: $0.segmentId, zone: Self.zone(of: $0, currentZoneID)) }
            .sorted { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.id < $1.id }
        var starts: [Int64] = []
        var zones: [String] = []
        for entry in ordered where zones.last != entry.zone {
            starts.append(entry.startMs)
            zones.append(entry.zone)
        }
        if zones.isEmpty {
            starts = [Int64.min]
            zones = [currentZoneID]
        }
        self.starts = starts
        self.zones = zones
    }

    private static func zone(of meta: SegmentMeta, _ currentZoneID: String) -> String {
        guard let stamp = meta.recordedTimeZone, TimeZone(identifier: stamp) != nil else {
            return currentZoneID
        }
        return stamp
    }

    /// The zone in effect at that moment.
    public func zoneID(atMs ms: Int64) -> String {
        zones[pieceIndex(atMs: ms)]
    }

    /// The `LogicalDay` key of the moment, in the zone in effect at it.
    public func dayKey(forMs ms: Int64) -> String {
        LogicalDay.dateKey(forMs: ms, timeZoneID: zoneID(atMs: ms))
    }

    /// Every stretch of absolute time whose `dayKey` is `dateKey`, in order, each with the zone
    /// in effect over it: exactly the moments `dayKey(forMs:)` files under that key.
    ///
    /// Normally one window, 5 AM → 5 AM in one zone (23 or 25 hours on a daylight-saving day).
    /// A zone change during the day clips it at the change. Travel west can make a date happen
    /// twice — two windows, one per zone, with the other date's time between them — and a jump
    /// of more than a day forward (across the date line) can skip a date entirely: no windows.
    public func windows(of dateKey: String) -> [(range: Range<Int64>, zoneID: String)] {
        // Every zone's window for this key lies between 5 AM of it at UTC+14 and 5 AM of the next
        // day at UTC-12 (the UTC window widened by 14 and 12 hours), so only the pieces
        // overlapping that need looking at.
        guard let utc = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: "UTC") else { return [] }
        let slackMs: Int64 = 15 * 3_600_000
        let searchStart = utc.startMs - slackMs
        let searchEnd = utc.endMs + slackMs

        var result: [(range: Range<Int64>, zoneID: String)] = []
        var index = pieceIndex(atMs: searchStart)
        while index < zones.count {
            let pieceStart = index == 0 ? Int64.min : starts[index]
            if pieceStart >= searchEnd { break }
            let pieceEnd = index + 1 < starts.count ? starts[index + 1] : Int64.max
            let zone = zones[index]
            index += 1
            guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone) else { continue }
            let lower = max(bounds.startMs, pieceStart)
            let upper = min(bounds.endMs, pieceEnd)
            guard upper > lower else { continue }
            // A date the zone itself skipped (Pacific/Apia's 2011-12-30) has no 5 AM; Calendar
            // resolves it to some other day's, and those moments are not this key's. Keep only
            // what really dates to it.
            guard LogicalDay.dateKey(forMs: lower, timeZoneID: zone) == dateKey else { continue }
            result.append((lower..<upper, zone))
        }
        return result
    }

    /// Index of the piece containing `ms`: the last change at or before it, else the first.
    private func pieceIndex(atMs ms: Int64) -> Int {
        var low = 1
        var high = starts.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= ms {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
