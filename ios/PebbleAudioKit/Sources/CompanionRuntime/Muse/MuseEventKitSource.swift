import EventKit
import Foundation

/// The phone's Calendar and Reminders, for Muse's calendar and reminders tools.
///
/// Access is asked for on the Muse screen, where the person turns a source on, never in the
/// middle of a question: iOS shows its permission sheet only to an app on screen.
public final class MuseEventKitSource: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public static var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public static var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    /// The person said no in iOS; only Settings can change it now.
    public static var calendarRefused: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }
    public static var remindersRefused: Bool {
        [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func requestCalendar() async -> Bool {
        if Self.calendarAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func requestReminders() async -> Bool {
        if Self.remindersAuthorized { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    public struct Event: Sendable, Equatable {
        public let title: String
        public let start: Date
        public let end: Date
        public let allDay: Bool
        public let location: String?
        public let calendar: String
    }

    public struct Reminder: Sendable, Equatable {
        public let title: String
        public let due: Date?
        public let list: String
    }

    public func events(from start: Date, to end: Date, limit: Int) -> [Event] {
        guard Self.calendarAuthorized, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map {
                Event(
                    title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                    location: $0.location?.isEmpty == false ? $0.location : nil,
                    calendar: $0.calendar?.title ?? "")
            }
    }

    public enum Failure: Error, Equatable {
        case notAllowed
        case noDefaultList
    }

    public func addEvent(title: String, start: Date, end: Date?, notes: String?) throws -> Event {
        guard Self.calendarAuthorized else { throw Failure.notAllowed }
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure.noDefaultList }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(60 * 60)
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return Event(title: title, start: event.startDate, end: event.endDate, allDay: false, location: nil, calendar: calendar.title)
    }

    public func reminders(list: String?, limit: Int) async -> [Reminder] {
        guard Self.remindersAuthorized else { return [] }
        var calendars: [EKCalendar]?
        if let list, !list.isEmpty {
            calendars = store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveContains(list) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let found: [Reminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map {
                    Reminder(
                        title: $0.title ?? "",
                        due: $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        list: $0.calendar?.title ?? "")
                })
            }
        }
        return Array(found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(limit))
    }

    public func addReminder(title: String, due: Date?, dueHasTime: Bool, list: String?) throws -> Reminder {
        guard Self.remindersAuthorized else { throw Failure.notAllowed }
        var calendar = store.defaultCalendarForNewReminders()
        if let list, !list.isEmpty,
            let match = store.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveContains(list) })
        {
            calendar = match
        }
        guard let calendar else { throw Failure.noDefaultList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            let units: Set<Calendar.Component> = dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
            if dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        return Reminder(title: title, due: due, list: calendar.title)
    }
}
