import EventKit
import Foundation

/// What Muse's calendar and reminders tools need from the phone. `MuseEventKitSource` is the
/// real one; tests give `MuseTools` a fake.
public protocol MuseEventKitAccess: Sendable {
    var calendarAuthorized: Bool { get }
    var calendarRefused: Bool { get }
    var remindersAuthorized: Bool { get }
    var remindersRefused: Bool { get }

    func events(from start: Date, to end: Date, limit: Int) -> [MuseEventKitSource.Event]
    func addEvent(title: String, start: Date, end: Date?, notes: String?) throws -> MuseEventKitSource.Event

    func calendars() -> [MuseEventKitSource.ReminderList]
    func eventPage(from: Date, to: Date, calendarID: String?, offset: Int, limit: Int) throws -> [MuseEventKitSource.Event]
    func event(id: String) throws -> MuseEventKitSource.Event
    func saveEvent(id: String?, change: MuseEventChange, span: String?) throws -> MuseEventKitSource.Event
    func deleteEvent(id: String, span: String?) throws -> MuseEventKitSource.Event

    /// Every reminders list on the phone, the default one marked.
    func reminderLists() -> [MuseEventKitSource.ReminderList]
    /// Reminders not done yet in `listIDs` (all lists when nil), and with `completedSince`, also
    /// the ones completed since then.
    func reminders(inLists listIDs: [String]?, completedSince: Date?) async -> [MuseEventKitSource.Reminder]
    func reminder(id: String) -> MuseEventKitSource.Reminder?
    /// Adds a reminder to `listID`, or to the default list when nil.
    func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?) throws
        -> MuseEventKitSource.Reminder
    func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?,
                     priority: Int?, recurrence: MuseRecurrence.Change?) throws -> MuseEventKitSource.Reminder
    /// Applies `change` and returns the reminder as it is now.
    func updateReminder(id: String, _ change: MuseEventKitSource.ReminderChange) throws -> MuseEventKitSource.Reminder
    /// Deletes the reminder and returns what it was.
    func deleteReminder(id: String) throws -> MuseEventKitSource.Reminder
}

/// The phone's Calendar and Reminders, for Muse's calendar and reminders tools.
///
/// Access is asked for on the Muse screen, where the person turns a source on, never in the
/// middle of a question: iOS shows its permission sheet only to an app on screen.
public final class MuseEventKitSource: MuseEventKitAccess, @unchecked Sendable {
    let store = EKEventStore()

    public init() {}

    public static var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public static var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    /// The person said no in iOS; only Settings can change it now.
    public static var calendarRefused: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }
    public static var remindersRefused: Bool {
        [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))
    }

    public var calendarAuthorized: Bool { Self.calendarAuthorized }
    public var calendarRefused: Bool { Self.calendarRefused }
    public var remindersAuthorized: Bool { Self.remindersAuthorized }
    public var remindersRefused: Bool { Self.remindersRefused }

    public func requestCalendar() async -> Bool {
        if Self.calendarAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func requestReminders() async -> Bool {
        if Self.remindersAuthorized { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    public struct Event: Sendable, Equatable {
        public var id: String = ""
        public var calendarID: String = ""
        public var account: String = ""
        public var notes: String? = nil
        public var timezone: String? = nil
        public var recurring: Bool = false
        public var occurrence: Date? = nil
        public var recurrence: [MuseRecurrence] = []
        public let title: String
        public let start: Date
        public let end: Date
        public let allDay: Bool
        public let location: String?
        public let calendar: String

        public init(title: String, start: Date, end: Date, allDay: Bool, location: String?, calendar: String) {
            self.title = title
            self.start = start
            self.end = end
            self.allDay = allDay
            self.location = location
            self.calendar = calendar
        }
    }

    public struct ReminderList: Sendable, Equatable {
        public var account: String = ""
        public let id: String
        public let name: String
        public let isDefault: Bool
        /// False for a list shared or subscribed to read only.
        public let canChange: Bool

        public init(id: String, name: String, isDefault: Bool, canChange: Bool = true) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
            self.canChange = canChange
        }
    }

    public struct Reminder: Sendable, Equatable {
        public var priority: Int = 0
        public var recurrence: [MuseRecurrence] = []
        /// EventKit's `calendarItemIdentifier`: stays the same across edits and moves.
        public let id: String
        public let title: String
        public let due: Date?
        /// False for a due date without a time of day.
        public let dueHasTime: Bool
        public let notes: String?
        public let list: String
        public let listID: String
        public let completed: Bool

        public init(
            id: String, title: String, due: Date? = nil, dueHasTime: Bool = false, notes: String? = nil, list: String,
            listID: String, completed: Bool = false
        ) {
            self.id = id
            self.title = title
            self.due = due
            self.dueHasTime = dueHasTime
            self.notes = notes
            self.list = list
            self.listID = listID
            self.completed = completed
        }
    }

    /// What an edit sets. Nil fields stay as they are.
    public struct ReminderChange: Sendable, Equatable {
        public enum Due: Sendable, Equatable {
            case set(Date, hasTime: Bool)
            case clear
        }

        public var title: String?
        public var due: Due?
        /// An empty string removes the notes.
        public var notes: String?
        /// Moves it to this list.
        public var listID: String?
        public var completed: Bool?
        public var priority: Int? = nil
        public var recurrence: MuseRecurrence.Change? = nil

        public init(title: String? = nil, due: Due? = nil, notes: String? = nil, listID: String? = nil, completed: Bool? = nil) {
            self.title = title
            self.due = due
            self.notes = notes
            self.listID = listID
            self.completed = completed
        }

        public var isEmpty: Bool { title == nil && due == nil && notes == nil && listID == nil && completed == nil && priority == nil && recurrence == nil }
    }

    public enum Failure: Error, Equatable {
        case notAllowed
        case noDefaultList
        case noSuchList
        case noSuchReminder
        case listCannotChange
        case noSuchEvent
        case recurrenceScopeRequired
        case invalidEvent
        case unsupported
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

    // MARK: - Reminders

    public func reminderLists() -> [ReminderList] {
        guard Self.remindersAuthorized else { return [] }
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .map {
                var list = ReminderList(
                    id: $0.calendarIdentifier, name: $0.title, isDefault: $0.calendarIdentifier == defaultID,
                    canChange: $0.allowsContentModifications)
                list.account = $0.source.title
                return list
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func reminders(inLists listIDs: [String]?, completedSince: Date?) async -> [Reminder] {
        guard Self.remindersAuthorized else { return [] }
        let calendars = listIDs.map { ids in ids.compactMap { store.calendar(withIdentifier: $0) } }
        if calendars?.isEmpty == true { return [] }
        var predicates = [store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)]
        if let completedSince {
            predicates.append(store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: calendars))
        }
        var found: [Reminder] = []
        for predicate in predicates {
            found += await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: (reminders ?? []).map(Self.snapshot))
                }
            }
        }
        return found
    }

    public func reminder(id: String) -> Reminder? {
        guard Self.remindersAuthorized, let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.snapshot(item)
    }

    public func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?) throws -> Reminder {
        try addReminder(title: title, due: due, dueHasTime: dueHasTime, notes: notes, listID: listID, priority: nil, recurrence: nil)
    }

    public func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?,
                            priority: Int?, recurrence: MuseRecurrence.Change?) throws -> Reminder {
        guard Self.remindersAuthorized else { throw Failure.notAllowed }
        let calendar: EKCalendar
        if let listID {
            guard let list = store.calendar(withIdentifier: listID) else { throw Failure.noSuchList }
            calendar = list
        } else {
            guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noDefaultList }
            calendar = list
        }
        guard calendar.allowsContentModifications else { throw Failure.listCannotChange }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let due { Self.setDue(reminder, due, hasTime: dueHasTime) }
        if let priority { reminder.priority = priority }
        if case .set(let rule)? = recurrence { reminder.recurrenceRules = [rule.rule()] }
        try store.save(reminder, commit: true)
        return Self.snapshot(reminder)
    }

    public func updateReminder(id: String, _ change: ReminderChange) throws -> Reminder {
        guard Self.remindersAuthorized else { throw Failure.notAllowed }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Failure.noSuchReminder }
        guard reminder.calendar?.allowsContentModifications != false else { throw Failure.listCannotChange }
        if let listID = change.listID, listID != reminder.calendar?.calendarIdentifier {
            guard let list = store.calendar(withIdentifier: listID) else { throw Failure.noSuchList }
            guard list.allowsContentModifications else { throw Failure.listCannotChange }
            reminder.calendar = list
        }
        if let title = change.title { reminder.title = title }
        if let notes = change.notes { reminder.notes = notes.isEmpty ? nil : notes }
        switch change.due {
        case .set(let date, let hasTime)?:
            Self.removeDueAlarm(reminder)
            Self.setDue(reminder, date, hasTime: hasTime)
        case .clear?:
            Self.removeDueAlarm(reminder)
            reminder.dueDateComponents = nil
        case nil:
            break
        }
        if let priority = change.priority { reminder.priority = priority }
        if let recurrence = change.recurrence {
            switch recurrence { case .clear: reminder.recurrenceRules = nil; case .set(let rule): reminder.recurrenceRules = [rule.rule()] }
        }
        if let completed = change.completed { reminder.isCompleted = completed }
        try store.save(reminder, commit: true)
        // Read back: a repeating reminder marked done comes back as its next occurrence.
        return (store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder).map(Self.snapshot)
            ?? Self.snapshot(reminder)
    }

    public func deleteReminder(id: String) throws -> Reminder {
        guard Self.remindersAuthorized else { throw Failure.notAllowed }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Failure.noSuchReminder }
        guard reminder.calendar?.allowsContentModifications != false else { throw Failure.listCannotChange }
        let before = Self.snapshot(reminder)
        try store.remove(reminder, commit: true)
        return before
    }

    private static func setDue(_ reminder: EKReminder, _ due: Date, hasTime: Bool) {
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
        if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
    }

    /// The alarm that rings at the due time, as Reminders sets it; other alarms stay.
    private static func removeDueAlarm(_ reminder: EKReminder) {
        guard let components = reminder.dueDateComponents, components.hour != nil,
            let due = Calendar.current.date(from: components)
        else { return }
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate.map({ abs($0.timeIntervalSince(due)) < 60 }) == true {
            reminder.removeAlarm(alarm)
        }
    }

    private static func snapshot(_ item: EKReminder) -> Reminder {
        let components = item.dueDateComponents
        var result = Reminder(
            id: item.calendarItemIdentifier,
            title: item.title ?? "",
            due: components.flatMap { Calendar.current.date(from: $0) },
            dueHasTime: components?.hour != nil,
            notes: item.notes?.isEmpty == false ? item.notes : nil,
            list: item.calendar?.title ?? "",
            listID: item.calendar?.calendarIdentifier ?? "",
            completed: item.isCompleted)
        result.priority = item.priority
        result.recurrence = (item.recurrenceRules ?? []).map(MuseRecurrence.init)
        return result
    }
}
