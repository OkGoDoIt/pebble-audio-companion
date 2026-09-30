import Foundation

// Every date, time and duration History prints (plan 5.1, 5.3). Pure: each function takes the
// zone and locale it formats in, so a travel day's cards read in the zone they were recorded in
// and tests do not depend on the machine they run on.
//
// The shapes follow the mockups exactly in a 12-hour English locale — "9:05 – 10:15 AM" with
// the meridiem once when both ends share it, "11:40 AM – 12:10 PM" otherwise — and fall back to
// Foundation's own interval formatting wherever the locale writes times differently.

enum HistoryFormat {

    /// Joins the two ends of a range. A plain en dash between ordinary spaces, as drawn.
    static let rangeDash = " – "
    /// Between a time and its meridiem: a no-break space, so "10:15" and "AM" never part.
    static let meridiemSpace = "\u{00A0}"

    // MARK: Times

    /// "9:05 AM".
    static func time(_ ms: Int64, zone: TimeZone, locale: Locale = .current) -> String {
        let parts = clockParts(ms, zone: zone, locale: locale)
        if let parts { return parts.clock + meridiemSpace + parts.meridiem }
        return normalizeSpaces(formatter(template: "jmm", zone: zone, locale: locale)
            .string(from: date(ms)))
    }

    /// The time without its meridiem, for the "now" marker on the axis: "11:41".
    static func clock(_ ms: Int64, zone: TimeZone, locale: Locale = .current) -> String {
        if let parts = clockParts(ms, zone: zone, locale: locale) { return parts.clock }
        return time(ms, zone: zone, locale: locale)
    }

    /// "9:05 – 10:15 AM" when both ends share the meridiem; "11:40 AM – 12:10 PM" otherwise.
    static func timeRange(_ startMs: Int64, _ endMs: Int64, zone: TimeZone, locale: Locale = .current)
        -> String
    {
        // A stretch inside one minute reads as that minute, not "5:31 – 5:31 PM".
        let startTime = time(startMs, zone: zone, locale: locale)
        if startTime == time(endMs, zone: zone, locale: locale) { return startTime }
        if let a = clockParts(startMs, zone: zone, locale: locale),
            let b = clockParts(endMs, zone: zone, locale: locale)
        {
            let start = a.meridiem == b.meridiem ? a.clock : a.clock + meridiemSpace + a.meridiem
            return start + rangeDash + b.clock + meridiemSpace + b.meridiem
        }
        let interval = DateIntervalFormatter()
        interval.locale = locale
        interval.timeZone = zone
        interval.dateStyle = .none
        interval.timeStyle = .short
        return normalizeSpaces(interval.string(from: date(startMs), to: date(endMs)))
    }

    /// The spoken form: "10:15 to 11:20 AM".
    static func spokenTimeRange(
        _ startMs: Int64, _ endMs: Int64, zone: TimeZone, locale: Locale = .current
    ) -> String {
        timeRange(startMs, endMs, zone: zone, locale: locale)
            .replacingOccurrences(of: rangeDash, with: " to ")
    }

    /// Hour label on the axis: "9 AM", or "09" / "9" where the locale is 24-hour.
    static func hourLabel(_ ms: Int64, zone: TimeZone, locale: Locale = .current) -> String {
        let f = formatter(template: "j", zone: zone, locale: locale)
        return normalizeSpaces(f.string(from: date(ms)))
    }

    /// A 12-hour locale that writes the meridiem after the clock gets the hand-made shape;
    /// anything else (24-hour, or a meridiem written first) returns nil and falls back.
    private static func clockParts(_ ms: Int64, zone: TimeZone, locale: Locale)
        -> (clock: String, meridiem: String)?
    {
        guard let pattern = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale),
            pattern.contains("a"),
            let aIndex = pattern.firstIndex(of: "a"), let hIndex = pattern.firstIndex(of: "h"),
            hIndex < aIndex
        else { return nil }
        let clock = formatter(format: "h:mm", zone: zone, locale: locale).string(from: date(ms))
        let meridiem = formatter(format: "a", zone: zone, locale: locale).string(from: date(ms))
        return (clock, meridiem)
    }

    // MARK: Durations

    /// "1 hr 10 min", "48 min", "2 hr". Rounded to the minute; under a minute reads "1 min"
    /// only when there is at least half a minute, otherwise "under 1 min".
    static func duration(ms: Int64) -> String {
        let minutes = Int((Double(max(0, ms)) / 60_000).rounded())
        if minutes == 0 { return Copy.History.underOneMinute }
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) hr"
        case (let h, let m): return "\(h) hr \(m) min"
        }
    }

    /// The spoken form: "1 hour 5 minutes", "48 minutes", "2 hours".
    static func spokenDuration(ms: Int64) -> String {
        let minutes = Int((Double(max(0, ms)) / 60_000).rounded())
        if minutes == 0 { return Copy.History.underOneMinuteSpoken }
        let hours = minutes / 60
        let rest = minutes % 60
        func unit(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        switch (hours, rest) {
        case (0, let m): return unit(m, "minute", "minutes")
        case (let h, 0): return unit(h, "hour", "hours")
        case (let h, let m): return unit(h, "hour", "hours") + " " + unit(m, "minute", "minutes")
        }
    }

    // MARK: Titles (plan 5.1)

    /// The two-line page title of a day: "Tuesday" / "September 22"; today reads "Today" /
    /// "Saturday, September 26". Yesterday is its weekday — the title has to stay true after
    /// midnight. The year joins the second line when it is not the current year.
    static func dayTitle(_ dateKey: String, todayKey: String, zone: TimeZone, locale: Locale = .current)
        -> (title: String, subtitle: String)
    {
        let day = noon(of: dateKey, zone: zone)
        let otherYear = dateKey.prefix(4) != todayKey.prefix(4)
        if dateKey == todayKey {
            let subtitle = formatter(
                template: otherYear ? "yEEEEMMMMd" : "EEEEMMMMd", zone: zone, locale: locale
            ).string(from: day)
            return (Copy.History.today, subtitle)
        }
        let weekday = formatter(template: "EEEE", zone: zone, locale: locale).string(from: day)
        let date = formatter(template: otherYear ? "yMMMMd" : "MMMMd", zone: zone, locale: locale)
            .string(from: day)
        return (weekday, date)
    }

    /// "Sep 20 – 26"; "Sep 27 – Oct 3" across months; with the year when either end is not in
    /// the current year.
    static func weekTitle(
        firstDateKey: String, lastDateKey: String, todayKey: String, locale: Locale = .current
    ) -> String {
        let zone = TimeZone(identifier: "UTC")!
        let otherYear = firstDateKey.prefix(4) != todayKey.prefix(4)
            || lastDateKey.prefix(4) != todayKey.prefix(4)
        let interval = DateIntervalFormatter()
        interval.locale = locale
        interval.timeZone = zone
        interval.dateTemplate = otherYear ? "yMMMd" : "MMMd"
        return normalizeSpaces(interval.string(
            from: noon(of: firstDateKey, zone: zone), to: noon(of: lastDateKey, zone: zone)))
    }

    /// "September"; "September 2025" when not the current year.
    static func monthTitle(_ dateKey: String, todayKey: String, locale: Locale = .current) -> String {
        let zone = TimeZone(identifier: "UTC")!
        let otherYear = dateKey.prefix(4) != todayKey.prefix(4)
        return formatter(template: otherYear ? "yLLLL" : "LLLL", zone: zone, locale: locale)
            .string(from: noon(of: dateKey, zone: zone))
    }

    /// The short weekday and the day number for a week row: ("Tue", "22").
    static func weekdayAndNumber(_ dateKey: String, locale: Locale = .current)
        -> (weekday: String, number: String)
    {
        let zone = TimeZone(identifier: "UTC")!
        let day = noon(of: dateKey, zone: zone)
        return (
            formatter(template: "EEE", zone: zone, locale: locale).string(from: day),
            formatter(template: "d", zone: zone, locale: locale).string(from: day)
        )
    }

    // MARK: Helpers

    /// Noon on a logical day's date in a zone. Noon, so no daylight-saving change can move it
    /// to a neighbouring date.
    static func noon(of dateKey: String, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = calendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return Date(timeIntervalSince1970: 0) }
        return date
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// Foundation writes thin and narrow no-break spaces into ranges and times; the design
    /// draws ordinary spaces, and a meridiem must not wrap away from its time.
    static func normalizeSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: meridiemSpace)
    }

    // A day page formats a few hundred strings; building a `DateFormatter` for each costs more
    // than the layout. Formatting from several threads is safe; only the cache needs the lock.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: DateFormatter] = [:]

        func formatter(_ key: String, make: () -> DateFormatter) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let hit = store[key] { return hit }
            let made = make()
            store[key] = made
            return made
        }
    }

    private static let cache = FormatterCache()

    private static func cached(_ key: String, make: () -> DateFormatter) -> DateFormatter {
        cache.formatter(key, make: make)
    }

    private static func formatter(template: String, zone: TimeZone, locale: Locale) -> DateFormatter {
        cached("t|\(template)|\(zone.identifier)|\(locale.identifier)") {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
    }

    private static func formatter(format: String, zone: TimeZone, locale: Locale) -> DateFormatter {
        cached("f|\(format)|\(zone.identifier)|\(locale.identifier)") {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = zone
            f.dateFormat = format
            return f
        }
    }
}
