import EventKit
import Foundation

public struct MuseEventChange: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var startDay: String?
    public var endDay: String?
    public var allDay: Bool?
    public var calendarID: String?
    public var location: String?
    public var notes: String?
    /// Empty string is floating time; nil preserves the current timezone.
    public var timezone: String?
    public var recurrence: MuseRecurrence.Change?
    public init() {}
}

public extension MuseEventKitAccess {
    func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?,
                     priority: Int?, recurrence: MuseRecurrence.Change?) throws -> MuseEventKitSource.Reminder {
        guard priority == nil, recurrence == nil else { throw MuseEventKitSource.Failure.unsupported }
        return try addReminder(title: title, due: due, dueHasTime: dueHasTime, notes: notes, listID: listID)
    }
    func calendars() -> [MuseEventKitSource.ReminderList] { [] }
    func eventPage(from: Date, to: Date, calendarID: String?, offset: Int, limit: Int) throws -> [MuseEventKitSource.Event] {
        guard calendarID == nil else { throw MuseEventKitSource.Failure.unsupported }
        return Array(events(from: from, to: to, limit: offset + limit).dropFirst(offset))
    }
    func event(id: String) throws -> MuseEventKitSource.Event { throw MuseEventKitSource.Failure.unsupported }
    func saveEvent(id: String?, change: MuseEventChange, span: String?) throws -> MuseEventKitSource.Event {
        guard id == nil, change.calendarID == nil, change.allDay == nil,
              change.location == nil, change.timezone == nil, change.recurrence == nil,
              let title = change.title, let start = change.start else { throw MuseEventKitSource.Failure.unsupported }
        return try addEvent(title: title, start: start, end: change.end, notes: change.notes)
    }
    func deleteEvent(id: String, span: String?) throws -> MuseEventKitSource.Event { throw MuseEventKitSource.Failure.unsupported }
}

extension MuseEventKitSource {
    /// EventKit's identifier alone fetches the FIRST occurrence. Keep both the original
    /// occurrence and its displayed start so an edit cannot target a different instance.
    struct EventReference: Codable {
        var identifier: String
        var calendar: String
        var occurrence: Date
        var start: Date
        var token: String { "event:" + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }
        init(_ event: EKEvent) {
            identifier = event.eventIdentifier
            calendar = event.calendar.calendarIdentifier
            occurrence = event.occurrenceDate ?? event.startDate
            start = event.startDate
        }
        init(token: String) throws {
            guard token.hasPrefix("event:"), let data = Data(base64Encoded: String(token.dropFirst(6))),
                  data.count < 8192 else { throw Failure.noSuchEvent }
            self = try JSONDecoder().decode(Self.self, from: data)
            guard start.timeIntervalSince1970.isFinite, occurrence.timeIntervalSince1970.isFinite else { throw Failure.noSuchEvent }
        }
    }

    public func calendars() -> [ReminderList] {
        guard calendarAuthorized else { return [] }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map { calendar in
            var list = ReminderList(id: calendar.calendarIdentifier, name: calendar.title,
                isDefault: calendar.calendarIdentifier == defaultID, canChange: calendar.allowsContentModifications)
            list.account = calendar.source.title
            return list
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    public func eventPage(from: Date, to: Date, calendarID: String?, offset: Int, limit: Int) throws -> [Event] {
        guard calendarAuthorized else { throw Failure.notAllowed }
        guard to > from else { throw Failure.invalidEvent }
        var calendars: [EKCalendar]?
        if let calendarID {
            guard let selected = store.calendar(withIdentifier: calendarID), selected.allowedEntityTypes.contains(.event) else { throw Failure.noSuchList }
            calendars = [selected]
        }
        // EventKit truncates predicates longer than four years. Explicitly use smaller windows
        // and deduplicate long events that overlap a window boundary.
        var events: [String: EKEvent] = [:]
        var cursor = from
        while cursor < to {
            let end = min(cursor.addingTimeInterval(366 * 86400), to)
            for event in store.events(matching: store.predicateForEvents(withStart: cursor, end: end, calendars: calendars)) {
                events[EventReference(event).token] = event
            }
            cursor = end
        }
        return events.values.sorted {
            $0.startDate == $1.startDate ? EventReference($0).token < EventReference($1).token : $0.startDate < $1.startDate
        }.dropFirst(offset).prefix(limit).map(Self.eventSnapshot)
    }

    private func resolveEvent(_ id: String) throws -> EKEvent {
        guard calendarAuthorized else { throw Failure.notAllowed }
        let reference = try EventReference(token: id)
        guard let calendar = store.calendar(withIdentifier: reference.calendar) else { throw Failure.noSuchEvent }
        let candidates = store.events(matching: store.predicateForEvents(
            withStart: reference.start.addingTimeInterval(-86400), end: reference.start.addingTimeInterval(86400), calendars: [calendar]))
        let matches = candidates.filter {
            $0.eventIdentifier == reference.identifier && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(reference.occurrence)) < 1
        }
        guard matches.count == 1, let event = matches.first else { throw Failure.noSuchEvent }
        return event
    }

    public func event(id: String) throws -> Event { Self.eventSnapshot(try resolveEvent(id)) }

    static func span(_ value: String?, recurring: Bool) throws -> EKSpan {
        guard let value else {
            guard !recurring else { throw Failure.recurrenceScopeRequired }
            return .thisEvent
        }
        switch value {
        case "occurrence": return .thisEvent
        case "future": return .futureEvents
        default: throw Failure.recurrenceScopeRequired
        }
    }

    public func saveEvent(id: String?, change: MuseEventChange, span: String?) throws -> Event {
        guard calendarAuthorized else { throw Failure.notAllowed }
        let event = try id.map(resolveEvent) ?? EKEvent(eventStore: store)
        var saved = false
        defer { if id != nil && !saved { _ = event.refresh() } }
        let saveSpan = try Self.span(span, recurring: id != nil && event.hasRecurrenceRules)
        if id != nil, !event.calendar.allowsContentModifications { throw Failure.listCannotChange }
        if let calendarID = change.calendarID {
            guard let selected = store.calendar(withIdentifier: calendarID), selected.allowedEntityTypes.contains(.event) else { throw Failure.noSuchList }
            event.calendar = selected
        } else if id == nil { event.calendar = store.defaultCalendarForNewEvents }
        guard let calendar = event.calendar else { throw Failure.noDefaultList }
        guard calendar.allowsContentModifications else { throw Failure.listCannotChange }
        if let title = change.title { event.title = title }
        if let allDay = change.allDay { event.isAllDay = allDay }
        if let timezone = change.timezone { event.timeZone = timezone.isEmpty ? nil : TimeZone(identifier: timezone) }
        let timezone = event.timeZone ?? TimeZone.current
        if let day = change.startDay { event.startDate = try Self.calendarDay(day, timezone: timezone) }
        else if let start = change.start { event.startDate = start }
        if let day = change.endDay { event.endDate = try Self.calendarDay(day, timezone: timezone) }
        else if let end = change.end { event.endDate = end }
        if id == nil, change.end == nil {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
            event.endDate = event.isAllDay ? calendar.date(byAdding: .day, value: 1, to: event.startDate) : event.startDate.addingTimeInterval(3600)
        }
        guard let start = event.startDate, let end = event.endDate, end > start,
              !(event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidEvent }
        if let location = change.location { event.location = location.isEmpty ? nil : location }
        if let notes = change.notes { event.notes = notes.isEmpty ? nil : notes }
        if let recurrence = change.recurrence {
            // EventKit cannot replace a series rule by changing a detached occurrence.
            if id != nil, event.hasRecurrenceRules, saveSpan != .futureEvents { throw Failure.recurrenceScopeRequired }
            switch recurrence { case .clear: event.recurrenceRules = nil; case .set(let rule): event.recurrenceRules = [rule.rule()] }
        }
        try store.save(event, span: saveSpan, commit: true)
        saved = true
        return Self.eventSnapshot(event)
    }

    static func calendarDay(_ text: String, timezone: TimeZone) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw Failure.invalidEvent }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { throw Failure.invalidEvent }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { throw Failure.invalidEvent }
        return date
    }

    public func deleteEvent(id: String, span: String?) throws -> Event {
        let event = try resolveEvent(id)
        guard event.calendar.allowsContentModifications else { throw Failure.listCannotChange }
        let before = Self.eventSnapshot(event)
        try store.remove(event, span: Self.span(span, recurring: event.hasRecurrenceRules), commit: true)
        return before
    }

    private static func eventSnapshot(_ event: EKEvent) -> Event {
        var result = Event(title: event.title ?? "", start: event.startDate, end: event.endDate,
            allDay: event.isAllDay, location: event.location, calendar: event.calendar.title)
        result.id = EventReference(event).token; result.calendarID = event.calendar.calendarIdentifier
        result.account = event.calendar.source.title; result.notes = event.notes; result.timezone = event.timeZone?.identifier
        result.recurring = event.hasRecurrenceRules; result.occurrence = event.occurrenceDate
        result.recurrence = (event.recurrenceRules ?? []).map(MuseRecurrence.init)
        return result
    }
}
