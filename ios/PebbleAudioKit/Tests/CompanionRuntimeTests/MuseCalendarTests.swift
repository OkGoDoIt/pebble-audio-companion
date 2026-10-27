import EventKit
import Foundation
import MuseLink
import Testing
@testable import CompanionRuntime

struct MuseCalendarTests {
    @Test func allDayDatesUseTheEventTimezoneAndDSTDayLength() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let start = try MuseEventKitSource.calendarDay("2026-03-08", timezone: zone)
        let end = try MuseEventKitSource.calendarDay("2026-03-09", timezone: zone)
        #expect(end.timeIntervalSince(start) == 23 * 3600)
        #expect(throws: MuseEventKitSource.Failure.invalidEvent) {
            try MuseEventKitSource.calendarDay("2026-02-30", timezone: zone)
        }
    }

    @Test func recurrenceRoundTripsAndRejectsFieldsItWouldIgnore() throws {
        let input: MuseJSON = ["frequency": "weekly", "interval": 2, "weekdays": [2, 6], "count": 12]
        guard case .set(let value) = try MuseRecurrence.parse(input) else { Issue.record("Expected rule"); return }
        let native = value.rule()
        #expect(native.frequency == .weekly && native.interval == 2)
        #expect(native.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) == [2, 6])
        #expect(MuseRecurrence(native) == value)
        for invalid: MuseJSON in [
            ["frequency": "daily", "interval": 0], ["frequency": "weekly", "weekdays": [0]],
            ["frequency": "daily", "month_days": [15]], ["frequency": "yearly", "months": [13]],
            ["frequency": "weekly", "count": 2, "until": "2027-01-01T00:00:00Z"],
            ["frequency": "monthly", "week_number": 2], ["frequency": "daily", "interval": .number(1.5)]
        ] { #expect(throws: (any Error).self) { try MuseRecurrence.parse(invalid) } }
        #expect(try MuseRecurrence.parse(.null) == .clear)
    }

    @Test func recurringEventMutationsRequireAnExplicitOccurrenceOrFutureScope() throws {
        #expect(try MuseEventKitSource.span(nil, recurring: false) == .thisEvent)
        #expect(throws: MuseEventKitSource.Failure.recurrenceScopeRequired) {
            try MuseEventKitSource.span(nil, recurring: true)
        }
        #expect(try MuseEventKitSource.span("occurrence", recurring: true) == .thisEvent)
        #expect(try MuseEventKitSource.span("future", recurring: true) == .futureEvents)
        #expect(throws: MuseEventKitSource.Failure.recurrenceScopeRequired) {
            try MuseEventKitSource.span("all", recurring: true)
        }
    }

    @Test func reminderEditLeavesRecurrenceAndPriorityAloneUnlessSpecified() throws {
        guard case .request(let titleOnly) = MuseReminders.request(.edit, ["id": "r", "title": "New title"]) else { Issue.record("Expected edit"); return }
        #expect(titleOnly.recurrence == nil && titleOnly.priority == nil)
        guard case .request(let recurring) = MuseReminders.request(.edit, ["id": "r", "priority": 1,
            "recurrence": ["frequency": "monthly", "month_days": [-1]]]) else { Issue.record("Expected edit"); return }
        #expect(recurring.priority == 1)
        guard case .set(let rule)? = recurring.recurrence else { Issue.record("Expected recurrence"); return }
        #expect(rule.rule().daysOfTheMonth == [-1])
    }
}
