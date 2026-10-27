import EventKit
import Foundation
import MuseLink

/// A portable recurrence rule. Omitted changes leave the original EventKit rules untouched.
public struct MuseRecurrence: Sendable, Equatable {
    public var frequency: String
    public var interval: Int
    public var weekdays: [Int]
    public var monthDays: [Int]
    public var months: [Int]
    public var count: Int?
    public var until: Date?
    /// Existing complex rules are described honestly; simple edits do not replace them.
    public var complex: Bool = false

    public init(frequency: String, interval: Int = 1, weekdays: [Int] = [], monthDays: [Int] = [],
                months: [Int] = [], count: Int? = nil, until: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.weekdays = weekdays
        self.monthDays = monthDays; self.months = months; self.count = count; self.until = until
    }

    public enum Change: Sendable, Equatable { case clear, set(MuseRecurrence) }
    enum Invalid: Error { case rule }

    static func parse(_ json: MuseJSON) throws -> Change {
        if json == .null || json.string == "none" { return .clear }
        let allowed: Set<String> = ["frequency", "interval", "weekdays", "month_days", "months", "count", "until"]
        guard let object = json.object, Set(object.keys).isSubset(of: allowed),
              let frequency = json["frequency"]?.string,
              ["daily", "weekly", "monthly", "yearly"].contains(frequency) else { throw Invalid.rule }
        let interval = MuseTools.int(json["interval"]) ?? 1
        guard interval > 0, interval <= Int(Int32.max), json["interval"] == nil || MuseTools.int(json["interval"]) != nil else { throw Invalid.rule }
        func integers(_ key: String, valid: (Int) -> Bool) throws -> [Int] {
            guard let value = json[key] else { return [] }
            guard let array = value.array else { throw Invalid.rule }
            let ints = array.compactMap { MuseTools.int($0) }
            guard ints.count == array.count, ints.allSatisfy(valid), Set(ints).count == ints.count else { throw Invalid.rule }
            return ints
        }
        let weekdays = try integers("weekdays") { (1...7).contains($0) }
        let days = try integers("month_days") { (-31...31).contains($0) && $0 != 0 }
        let months = try integers("months") { (1...12).contains($0) }
        guard weekdays.isEmpty || frequency != "daily", days.isEmpty || frequency == "monthly",
              months.isEmpty || frequency == "yearly" else { throw Invalid.rule }
        var count: Int?, until: Date?
        if json["count"] != nil {
            guard let value = MuseTools.int(json["count"]), value > 0, value <= Int(Int32.max) else { throw Invalid.rule }
            count = value
        }
        if json["until"] != nil {
            guard count == nil, let parsed = MuseTools.date(json["until"]?.string), parsed.hasTime else { throw Invalid.rule }
            until = parsed.date
        }
        return .set(MuseRecurrence(frequency: frequency, interval: interval, weekdays: weekdays,
                                  monthDays: days, months: months, count: count, until: until))
    }

    func rule() -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch self.frequency {
        case "daily": .daily; case "weekly": .weekly; case "monthly": .monthly; default: .yearly
        }
        let end = count.map(EKRecurrenceEnd.init(occurrenceCount:)) ?? until.map(EKRecurrenceEnd.init(end:))
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
            daysOfTheWeek: weekdays.isEmpty ? nil : weekdays.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } },
            daysOfTheMonth: monthDays.isEmpty ? nil : monthDays.map(NSNumber.init(value:)),
            monthsOfTheYear: months.isEmpty ? nil : months.map(NSNumber.init(value:)),
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    init(_ rule: EKRecurrenceRule) {
        frequency = switch rule.frequency { case .daily: "daily"; case .weekly: "weekly"; case .monthly: "monthly"; case .yearly: "yearly"; @unknown default: "unknown" }
        interval = rule.interval; weekdays = rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } ?? []
        monthDays = rule.daysOfTheMonth?.map(\.intValue) ?? []; months = rule.monthsOfTheYear?.map(\.intValue) ?? []
        count = rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil }
        until = rule.recurrenceEnd?.endDate
        complex = (rule.daysOfTheWeek?.contains { $0.weekNumber != 0 } ?? false)
            || !(rule.weeksOfTheYear ?? []).isEmpty || !(rule.daysOfTheYear ?? []).isEmpty || !(rule.setPositions ?? []).isEmpty
    }

    var json: MuseJSON {
        ["frequency": .string(frequency), "interval": .number(Double(interval)),
         "weekdays": .array(weekdays.map { .number(Double($0)) }),
         "month_days": .array(monthDays.map { .number(Double($0)) }), "months": .array(months.map { .number(Double($0)) }),
         "count": count.map { .number(Double($0)) } ?? .null,
         "until": until.map { .string(MuseTools.isoFormatter.string(from: $0)) } ?? .null,
         "has_additional_constraints": .bool(complex)]
    }
}
