import Foundation

/// Week and month arithmetic on logical-day keys (`"YYYY-MM-DD"`, as `LogicalDay` and
/// `ZoneTimeline` produce them).
///
/// A key is already a calendar DATE — the zone was applied when the key was made — so everything
/// here is date arithmetic with no zone in it. It runs on a fixed Gregorian calendar in UTC,
/// where every day is 24 hours, so a daylight-saving change can never shift a date by one.
/// `firstWeekday` uses `Calendar`'s numbering (1 = Sunday, 2 = Monday, … 7 = Saturday); the
/// caller passes `Calendar.current.firstWeekday`. Keys are zero-padded, so a `ClosedRange` of
/// them orders chronologically.
///
/// A malformed key (not a real date in `YYYY-MM-DD` form) is answered with itself — a
/// one-day range, no neighbours — rather than a guess.
public enum HistoryCalendar {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// The week (`firstWeekday` through the day before the next one) containing the day.
    /// A week's key is its first day.
    public static func week(containing dateKey: String, firstWeekday: Int) -> ClosedRange<String> {
        guard let date = date(dateKey) else { return dateKey...dateKey }
        let weekday = calendar.component(.weekday, from: date)
        let back = ((weekday - normalized(firstWeekday)) % 7 + 7) % 7
        let start = adding(-back, to: date)
        return key(start)...key(adding(6, to: start))
    }

    /// The calendar month containing the day, first to last day.
    public static func month(containing dateKey: String) -> ClosedRange<String> {
        guard let date = date(dateKey),
            let interval = calendar.dateInterval(of: .month, for: date)
        else { return dateKey...dateKey }
        return key(interval.start)...key(adding(-1, to: interval.end))
    }

    /// Every week that overlaps the month containing the day, whole and in order. A week that
    /// straddles two months belongs to both.
    public static func weeks(inMonthOf dateKey: String, firstWeekday: Int) -> [ClosedRange<String>] {
        guard date(dateKey) != nil else { return [dateKey...dateKey] }
        let days = month(containing: dateKey)
        var result: [ClosedRange<String>] = []
        var current = week(containing: days.lowerBound, firstWeekday: firstWeekday)
        while current.lowerBound <= days.upperBound {
            result.append(current)
            let next = key(current.upperBound, addingDays: 1)
            current = next...key(next, addingDays: 6)
        }
        return result
    }

    /// Every day in the range, inclusive, in order.
    public static func days(in range: ClosedRange<String>) -> [String] {
        guard let first = date(range.lowerBound), let last = date(range.upperBound) else {
            return range.lowerBound == range.upperBound ? [range.lowerBound] : []
        }
        var result: [String] = []
        var day = first
        while day <= last {
            result.append(key(day))
            day = adding(1, to: day)
        }
        return result
    }

    /// The key `addingDays` days after (or, negative, before) this one.
    public static func key(_ dateKey: String, addingDays days: Int) -> String {
        guard let date = date(dateKey) else { return dateKey }
        return key(adding(days, to: date))
    }

    // --- helpers ------------------------------------------------------------------------------

    /// Midnight UTC of the key's date; nil unless the key is a real date written canonically.
    private static func date(_ dateKey: String) -> Date? {
        let parts = dateKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            key(date) == dateKey
        else { return nil }
        return date
    }

    private static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func adding(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    /// `Calendar`'s 1…7, tolerating an out-of-range value by wrapping it.
    private static func normalized(_ firstWeekday: Int) -> Int {
        ((firstWeekday - 1) % 7 + 7) % 7 + 1
    }
}
