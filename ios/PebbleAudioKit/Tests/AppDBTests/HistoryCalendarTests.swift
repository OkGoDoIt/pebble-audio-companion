import Foundation
import SegmentStore
import Testing

@testable import AppDB

// History's two time primitives: `ZoneTimeline` (which zone, and so which 5 AM logical day, a
// moment belongs to) and `HistoryCalendar` (week and month arithmetic on day keys).

private let hourMs: Int64 = 3_600_000

/// Epoch ms of a wall-clock time in a zone.
private func ms(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ zone: String
) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    let date = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    return Int64(date.timeIntervalSince1970 * 1000)
}

/// A 10-minute segment starting at `startMs`, stamped with `tz` (nil = recorded before stamps).
private func segment(_ id: String, at startMs: Int64, tz: String?) -> SegmentMeta {
    makeSegment(id: id, stream: 1, startTimeMs: startMs, durationSamples: minutesSamples(10), tz: tz)
}

private let la = "America/Los_Angeles"
private let jakarta = "Asia/Jakarta"

@Suite struct HistoryCalendarTests {

    // MARK: - ZoneTimeline: the 5 AM boundary

    @Test("a moment belongs to the logical day that began at the last 5 AM in its zone")
    func fiveAmBoundary() throws {
        let ny = "America/New_York"
        let timeline = ZoneTimeline(
            segments: [segment("s", at: ms(2026, 3, 10, 9, 0, ny), tz: ny)], currentZoneID: "UTC")
        let fiveAm = ms(2026, 3, 10, 5, 0, ny)
        #expect(timeline.dayKey(forMs: fiveAm - 1) == "2026-03-09")
        #expect(timeline.dayKey(forMs: fiveAm) == "2026-03-10")
        #expect(timeline.dayKey(forMs: ms(2026, 3, 11, 4, 59, ny)) == "2026-03-10")

        let windows = timeline.windows(of: "2026-03-10")
        try #require(windows.count == 1)
        #expect(windows[0].range == fiveAm..<ms(2026, 3, 11, 5, 0, ny))
        #expect(windows[0].zoneID == ny)
    }

    @Test("a daylight-saving day is 23 or 25 hours, still 5 AM to 5 AM")
    func daylightSavingDays() throws {
        // US clocks change at 2 AM, which is before the 5 AM boundary: the short and long
        // LOGICAL days are the ones keyed the day before the change (03-07 and 10-31).
        let timeline = ZoneTimeline(
            segments: [segment("s", at: ms(2026, 1, 5, 12, 0, la), tz: la)], currentZoneID: "UTC")
        let spring = try #require(timeline.windows(of: "2026-03-07").first)  // clocks go forward
        #expect(spring.range == ms(2026, 3, 7, 5, 0, la)..<ms(2026, 3, 8, 5, 0, la))
        #expect(spring.range.count == 23 * Int(hourMs))
        let fall = try #require(timeline.windows(of: "2026-10-31").first)  // clocks go back
        #expect(fall.range.count == 25 * Int(hourMs))
        #expect(timeline.windows(of: "2026-10-31").count == 1)
        #expect(timeline.windows(of: "2026-11-01").first?.range.count == 24 * Int(hourMs))
        #expect(timeline.dayKey(forMs: ms(2026, 11, 1, 4, 59, la)) == "2026-10-31")
        #expect(timeline.dayKey(forMs: ms(2026, 3, 8, 4, 59, la)) == "2026-03-07")
    }

    // MARK: - ZoneTimeline: legacy and unstamped data

    @Test("with no stamps at all it is exactly LogicalDay in the current zone")
    func allUnstampedIsLogicalDayInTheCurrentZone() {
        let start = ms(2026, 9, 1, 0, 0, la)
        let segments = (0..<40).map { segment("s\($0)", at: start + Int64($0) * 17 * hourMs, tz: nil) }
        let timeline = ZoneTimeline(segments: segments, currentZoneID: la)
        for step in 0..<(40 * 17 * 4) {
            let moment = start - 30 * hourMs + Int64(step) * 15 * 60_000 + 7_000
            #expect(timeline.zoneID(atMs: moment) == la)
            #expect(timeline.dayKey(forMs: moment) == LogicalDay.dateKey(forMs: moment, timeZoneID: la))
        }
        let windows = timeline.windows(of: "2026-09-10")
        #expect(windows.count == 1)
        #expect(windows.first?.range.lowerBound == LogicalDay.bounds(ofDateKey: "2026-09-10", timeZoneID: la)?.startMs)
    }

    @Test("an unstamped recording is dated in the current zone, even after a stamped one")
    func unstampedSegmentsAgreeWithEveryOtherConsumer() {
        // The legacy shape: an importer-stamped segment inside weeks of unstamped audio, then
        // the stamped era. Every other surface dates a segment `recordedTimeZone ?? current`;
        // History must file each of these under the same day they do.
        let current = "Europe/London"
        let stamped = segment("importer", at: ms(2026, 9, 1, 12, 0, jakarta), tz: jakarta)
        let legacy = segment("legacy", at: ms(2026, 9, 2, 12, 0, current), tz: nil)
        let newEra = segment("new", at: ms(2026, 9, 20, 12, 0, la), tz: la)
        let timeline = ZoneTimeline(segments: [newEra, legacy, stamped], currentZoneID: current)

        for meta in [stamped, legacy, newEra] {
            let zone = meta.recordedTimeZone ?? current
            for offset in stride(from: Int64(0), to: 10 * 60_000, by: 60_000) {
                let moment = meta.startWallMs + offset
                #expect(timeline.zoneID(atMs: moment) == zone, "\(meta.segmentId)")
                #expect(timeline.dayKey(forMs: moment) == LogicalDay.dateKey(forMs: moment, timeZoneID: zone))
            }
        }
        // Between recordings the last known zone carries forward…
        #expect(timeline.zoneID(atMs: ms(2026, 9, 10, 12, 0, current)) == current)
        #expect(timeline.zoneID(atMs: ms(2026, 9, 25, 12, 0, la)) == la)
        // …and before the first recording, the first recording's zone applies.
        #expect(timeline.zoneID(atMs: ms(2026, 8, 1, 12, 0, jakarta)) == jakarta)
    }

    @Test("no segments, or a stamp that is not a zone, means the current zone")
    func fallbacks() {
        #expect(ZoneTimeline(segments: [], currentZoneID: la).zoneID(atMs: 0) == la)
        #expect(ZoneTimeline(segments: [], currentZoneID: la).windows(of: "2026-09-10").count == 1)
        let corrupt = segment("corrupt", at: ms(2026, 9, 2, 12, 0, la), tz: "Not/AZone")
        #expect(ZoneTimeline(segments: [corrupt], currentZoneID: la).zoneID(atMs: corrupt.startWallMs) == la)
    }

    // MARK: - ZoneTimeline: travel

    @Test("flying west repeats a date: two windows, one per zone")
    func westwardRepeatsADate() throws {
        // Jakarta (UTC+7) to Los Angeles (UTC-7). The first LA recording starts at
        // 10:00 on the 22nd in Jakarta — 20:00 on the 21st in LA — so the 21st happens twice.
        let arrival = ms(2026, 9, 22, 10, 0, jakarta)
        #expect(arrival == ms(2026, 9, 21, 20, 0, la))
        let timeline = ZoneTimeline(
            segments: [
                segment("jakarta", at: ms(2026, 9, 20, 9, 0, jakarta), tz: jakarta),
                segment("la", at: arrival, tz: la),
            ],
            currentZoneID: la)

        #expect(timeline.dayKey(forMs: arrival - 1) == "2026-09-22")
        #expect(timeline.dayKey(forMs: arrival) == "2026-09-21")

        let repeated = timeline.windows(of: "2026-09-21")
        try #require(repeated.count == 2)
        #expect(repeated[0].zoneID == jakarta)
        #expect(repeated[0].range == ms(2026, 9, 21, 5, 0, jakarta)..<ms(2026, 9, 22, 5, 0, jakarta))
        #expect(repeated[1].zoneID == la)
        #expect(repeated[1].range == arrival..<ms(2026, 9, 22, 5, 0, la))

        // The 22nd, too, is lived in two pieces: five Jakarta hours, then all of it in LA.
        let next = timeline.windows(of: "2026-09-22")
        #expect(next.map(\.zoneID) == [jakarta, la])
        #expect(next.first?.range == ms(2026, 9, 22, 5, 0, jakarta)..<arrival)
        assertWindowsMatchDayKeys(timeline, keys: ["2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23"])
    }

    @Test("flying east from LA to Jakarta shortens a date but cannot skip one")
    func eastwardLosAngelesToJakarta() throws {
        // The zone changes at the first Jakarta recording, 07:00 on the 23rd (17:00 on the 22nd in
        // LA). A 14-hour jump crosses at most one midnight, so no date is skipped: the 22nd ends
        // early (5 AM to 5 PM in LA) and the 23rd begins late (at 07:00 in Jakarta). Across the
        // date line, below, is where a date can vanish.
        let arrival = ms(2026, 9, 23, 7, 0, jakarta)
        let timeline = ZoneTimeline(
            segments: [
                segment("la", at: ms(2026, 9, 20, 9, 0, la), tz: la),
                segment("jakarta", at: arrival, tz: jakarta),
            ],
            currentZoneID: jakarta)

        let short = timeline.windows(of: "2026-09-22")
        try #require(short.count == 1)
        #expect(short[0].zoneID == la)
        #expect(short[0].range == ms(2026, 9, 22, 5, 0, la)..<arrival)
        #expect(short[0].range.count == 12 * Int(hourMs))

        let late = timeline.windows(of: "2026-09-23")
        try #require(late.count == 1)
        #expect(late[0].zoneID == jakarta)
        #expect(late[0].range == arrival..<ms(2026, 9, 24, 5, 0, jakarta))
        assertWindowsMatchDayKeys(timeline, keys: ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24"])
    }

    @Test("flying east across the date line skips a date: no window at all")
    func eastwardAcrossTheDateLineSkipsADate() throws {
        // Pago Pago (UTC-11) to Kiritimati (UTC+14), 25 hours apart. The first Kiritimati
        // recording starts at 04:30 on the 22nd in Pago Pago — still the 21st's logical day
        // there — which is 05:30 on the 23rd in Kiritimati. The 22nd never happens.
        let pago = "Pacific/Pago_Pago"
        let kiritimati = "Pacific/Kiritimati"
        let arrival = ms(2026, 9, 22, 4, 30, pago)
        #expect(arrival == ms(2026, 9, 23, 5, 30, kiritimati))
        let timeline = ZoneTimeline(
            segments: [
                segment("pago", at: ms(2026, 9, 20, 12, 0, pago), tz: pago),
                segment("kiritimati", at: arrival, tz: kiritimati),
            ],
            currentZoneID: kiritimati)

        #expect(timeline.dayKey(forMs: arrival - 1) == "2026-09-21")
        #expect(timeline.dayKey(forMs: arrival) == "2026-09-23")
        #expect(timeline.windows(of: "2026-09-22").isEmpty)
        #expect(timeline.windows(of: "2026-09-21").last?.range.upperBound == arrival)
        #expect(timeline.windows(of: "2026-09-23").first?.range.lowerBound == arrival)
        assertWindowsMatchDayKeys(timeline, keys: ["2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23"])
    }

    @Test("a date the zone itself skipped has no window")
    func aDateTheZoneSkipped() {
        // Samoa moved across the date line at the end of 2011: 2011-12-30 never happened there.
        let apia = "Pacific/Apia"
        let timeline = ZoneTimeline(
            segments: [segment("s", at: ms(2011, 12, 28, 12, 0, apia), tz: apia)], currentZoneID: apia)
        #expect(timeline.windows(of: "2011-12-30").isEmpty)
        assertWindowsMatchDayKeys(timeline, keys: ["2011-12-29", "2011-12-30", "2011-12-31"])
    }

    /// `windows(of:)` must be exactly the moments `dayKey(forMs:)` files under the key — checked
    /// by sweeping every 10 minutes across the keys' neighbourhood.
    private func assertWindowsMatchDayKeys(
        _ timeline: ZoneTimeline, keys: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let windows = Dictionary(uniqueKeysWithValues: keys.map { ($0, timeline.windows(of: $0)) })
        guard let first = LogicalDay.bounds(ofDateKey: keys[0], timeZoneID: "UTC"),
            let last = LogicalDay.bounds(ofDateKey: keys[keys.count - 1], timeZoneID: "UTC")
        else { return }
        var moment = first.startMs + 16 * hourMs
        while moment < last.endMs - 16 * hourMs {
            let key = timeline.dayKey(forMs: moment)
            for candidate in keys {
                let inside = windows[candidate]!.contains { $0.range.contains(moment) }
                #expect(inside == (key == candidate), "\(moment) is \(key)", sourceLocation: sourceLocation)
            }
            // And the window that holds it names the zone in effect.
            if let window = windows[key]?.first(where: { $0.range.contains(moment) }) {
                #expect(window.zoneID == timeline.zoneID(atMs: moment), sourceLocation: sourceLocation)
            }
            moment += 10 * 60_000
        }
        for list in windows.values {
            for (a, b) in zip(list, list.dropFirst()) {
                #expect(a.range.upperBound <= b.range.lowerBound, "windows in order, disjoint", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: - HistoryCalendar

    @Test("a week starts on the calendar's first weekday")
    func weekStarts() {
        // 2026-09-30 is a Wednesday.
        #expect(HistoryCalendar.week(containing: "2026-09-30", firstWeekday: 1) == "2026-09-27"..."2026-10-03")
        #expect(HistoryCalendar.week(containing: "2026-09-30", firstWeekday: 2) == "2026-09-28"..."2026-10-04")
        // The first day of a week is in its own week.
        #expect(HistoryCalendar.week(containing: "2026-09-27", firstWeekday: 1).lowerBound == "2026-09-27")
        #expect(HistoryCalendar.week(containing: "2026-09-27", firstWeekday: 2) == "2026-09-21"..."2026-09-27")
        // Saturday-first (7).
        #expect(HistoryCalendar.week(containing: "2026-09-30", firstWeekday: 7) == "2026-09-26"..."2026-10-02")
    }

    @Test("a week runs across a year boundary")
    func weekAcrossTheYear() {
        #expect(HistoryCalendar.week(containing: "2027-01-01", firstWeekday: 2) == "2026-12-28"..."2027-01-03")
        #expect(HistoryCalendar.week(containing: "2026-12-31", firstWeekday: 1) == "2026-12-27"..."2027-01-02")
    }

    @Test("a month is its first to its last day")
    func months() {
        #expect(HistoryCalendar.month(containing: "2026-09-30") == "2026-09-01"..."2026-09-30")
        #expect(HistoryCalendar.month(containing: "2026-12-15") == "2026-12-01"..."2026-12-31")
        #expect(HistoryCalendar.month(containing: "2026-02-10") == "2026-02-01"..."2026-02-28")
        #expect(HistoryCalendar.month(containing: "2028-02-10") == "2028-02-01"..."2028-02-29")
    }

    @Test("every week overlapping a month, whole; a straddling week is in both months")
    func weeksInAMonth() {
        // September 2026 begins on a Tuesday and ends on a Wednesday.
        #expect(
            HistoryCalendar.weeks(inMonthOf: "2026-09-15", firstWeekday: 2) == [
                "2026-08-31"..."2026-09-06", "2026-09-07"..."2026-09-13", "2026-09-14"..."2026-09-20",
                "2026-09-21"..."2026-09-27", "2026-09-28"..."2026-10-04",
            ])
        #expect(
            HistoryCalendar.weeks(inMonthOf: "2026-09-15", firstWeekday: 1) == [
                "2026-08-30"..."2026-09-05", "2026-09-06"..."2026-09-12", "2026-09-13"..."2026-09-19",
                "2026-09-20"..."2026-09-26", "2026-09-27"..."2026-10-03",
            ])
        // Across the year: the week holding New Year closes December and opens January.
        let december = HistoryCalendar.weeks(inMonthOf: "2026-12-01", firstWeekday: 1)
        let january = HistoryCalendar.weeks(inMonthOf: "2027-01-20", firstWeekday: 1)
        #expect(december.last == "2026-12-27"..."2027-01-02")
        #expect(january.first == "2026-12-27"..."2027-01-02")
        #expect(december.count == 5)
        // A month that begins on the week's first day starts with its own first day.
        #expect(HistoryCalendar.weeks(inMonthOf: "2026-11-11", firstWeekday: 1).first?.lowerBound == "2026-11-01")
        // February 2026 starts on a Sunday and has exactly four Sunday weeks.
        #expect(HistoryCalendar.weeks(inMonthOf: "2026-02-14", firstWeekday: 1).count == 4)
    }

    @Test("leap days")
    func leapDays() {
        #expect(HistoryCalendar.key("2028-02-28", addingDays: 1) == "2028-02-29")
        #expect(HistoryCalendar.key("2028-02-29", addingDays: 1) == "2028-03-01")
        #expect(HistoryCalendar.key("2027-02-28", addingDays: 1) == "2027-03-01")
        #expect(HistoryCalendar.key("2028-03-01", addingDays: -1) == "2028-02-29")
        #expect(HistoryCalendar.week(containing: "2028-02-29", firstWeekday: 1) == "2028-02-27"..."2028-03-04")
        #expect(HistoryCalendar.days(in: "2028-02-27"..."2028-03-01") == [
            "2028-02-27", "2028-02-28", "2028-02-29", "2028-03-01",
        ])
        // Not a date: answered with itself, never rolled into March.
        #expect(HistoryCalendar.key("2026-02-29", addingDays: 1) == "2026-02-29")
        #expect(HistoryCalendar.month(containing: "2026-02-29") == "2026-02-29"..."2026-02-29")
    }

    @Test("days(in:) lists every day inclusive, across months and years")
    func daysInRange() {
        #expect(HistoryCalendar.days(in: "2026-09-30"..."2026-09-30") == ["2026-09-30"])
        #expect(HistoryCalendar.days(in: "2026-12-30"..."2027-01-02") == [
            "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02",
        ])
        #expect(HistoryCalendar.days(in: HistoryCalendar.month(containing: "2026-09-01")).count == 30)
        #expect(HistoryCalendar.days(in: HistoryCalendar.week(containing: "2026-09-01", firstWeekday: 2)).count == 7)
    }

    @Test("date arithmetic never moves with daylight saving")
    func arithmeticIgnoresDaylightSaving() {
        // Whatever zone the process runs in, a key plus one is the next date.
        #expect(HistoryCalendar.key("2026-03-07", addingDays: 1) == "2026-03-08")
        #expect(HistoryCalendar.key("2026-03-08", addingDays: 1) == "2026-03-09")
        #expect(HistoryCalendar.key("2026-11-01", addingDays: 1) == "2026-11-02")
        #expect(HistoryCalendar.key("2026-10-25", addingDays: 7) == "2026-11-01")
        #expect(HistoryCalendar.key("2026-01-01", addingDays: 365) == "2027-01-01")
    }

    @Test("a malformed key is answered with itself")
    func malformedKeys() {
        for bad in ["", "2026-9-30", "2026-13-01", "20260930", "2026-09-31", "x"] {
            #expect(HistoryCalendar.week(containing: bad, firstWeekday: 1) == bad...bad)
            #expect(HistoryCalendar.key(bad, addingDays: 3) == bad)
            #expect(HistoryCalendar.days(in: bad...bad) == [bad])
            #expect(HistoryCalendar.weeks(inMonthOf: bad, firstWeekday: 1) == [bad...bad])
        }
    }
}
