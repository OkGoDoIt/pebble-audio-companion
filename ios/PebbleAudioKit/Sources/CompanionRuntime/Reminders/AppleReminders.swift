import EventKit
import Foundation

/// A reminder as Apple Reminders holds it.
public struct AppleReminder: Equatable, Sendable {
    public var id: String
    public var listId: String
    public var title: String
    public var done: Bool
    /// The due day (or moment), epoch ms; nil for none.
    public var dueAtMs: Int64?
    public var dueHasTime: Bool
    /// When it last changed in Apple Reminders, epoch ms: which side's change is newer.
    public var modifiedAtMs: Int64
    /// The link back to the app it carries (`ReminderLink`); nil for none.
    public var link: URL?
    /// When it was made, epoch ms; 0 when Reminders doesn't say.
    public var createdAtMs: Int64

    public init(
        id: String, listId: String, title: String, done: Bool, dueAtMs: Int64?, dueHasTime: Bool,
        modifiedAtMs: Int64 = 0, link: URL? = nil, createdAtMs: Int64 = 0
    ) {
        self.createdAtMs = createdAtMs
        self.modifiedAtMs = modifiedAtMs
        self.link = link
        self.id = id
        self.listId = listId
        self.title = title
        self.done = done
        self.dueAtMs = dueAtMs
        self.dueHasTime = dueHasTime
    }
}

/// One Apple Reminders list.
public struct AppleReminderList: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The list's color, `#RRGGBB`.
    public var colorHex: String
    public var isDefault: Bool
    public var writable: Bool

    public init(id: String, title: String, colorHex: String, isDefault: Bool, writable: Bool) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.isDefault = isDefault
        self.writable = writable
    }
}

/// What a reminder should say in Apple Reminders.
public struct AppleReminderDraft: Equatable, Sendable {
    public var title: String
    /// Written when the reminder is made and never again: after that the notes are the person's.
    public var notes: String?
    /// The link back to the app (`ReminderLink`).
    public var url: URL?
    public var dueAtMs: Int64?
    /// When to alert, epoch ms (the due day at the person's alert time); nil for none.
    public var alarmAtMs: Int64?
    public var done: Bool

    public init(
        title: String, notes: String? = nil, url: URL? = nil, dueAtMs: Int64? = nil,
        alarmAtMs: Int64? = nil, done: Bool = false
    ) {
        self.title = title
        self.notes = notes
        self.url = url
        self.dueAtMs = dueAtMs
        self.alarmAtMs = alarmAtMs
        self.done = done
    }
}

/// What `RemindersHome` needs of Apple Reminders. `EventKitReminders` is the real one; tests use a
/// fake.
public protocol AppleRemindersAccess: Sendable {
    var authorized: Bool { get }
    /// The person said no in iOS; only Settings can change it.
    var refused: Bool { get }
    /// Asks iOS for full access to Reminders. Only from a screen the person is using.
    func requestAccess() async -> Bool
    func lists() -> [AppleReminderList]
    /// Makes a list called `title` in the default source, and returns its id.
    func makeList(title: String) throws -> String
    func create(_ draft: AppleReminderDraft, inList listId: String) throws -> AppleReminder
    /// Brings the title, the due day, the tick, and the link to `draft`, keeping everything else
    /// the person has on it: its list, notes, time of day, and alarms. Nil when it is gone.
    func update(id: String, to draft: AppleReminderDraft) throws -> AppleReminder?
    func move(id: String, toList listId: String) throws -> AppleReminder?
    func delete(id: String) throws
    /// Puts the link back to the app on a reminder already there.
    func setLink(_ link: URL, on id: String) throws
    /// Every reminder carrying a link to one of these follow-ups, by follow-up id.
    func linked(to followUpIds: Set<String>) async -> [String: AppleReminder]
    /// Every reminder carrying a link to any follow-up; nil when Reminders could not be read.
    func allLinked() async -> [AppleReminder]?
    /// The reminders with these ids that still exist.
    func reminders(ids: [String]) -> [AppleReminder]
    /// Calls `onChange` whenever Reminders' data changes, here or anywhere.
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject
}

/// Apple Reminders through EventKit.
public final class EventKitReminders: AppleRemindersAccess, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    public var refused: Bool {
        [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func requestAccess() async -> Bool {
        if authorized { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    public func lists() -> [AppleReminderList] {
        guard authorized else { return [] }
        let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .map {
                AppleReminderList(
                    id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex($0.cgColor),
                    isDefault: $0.calendarIdentifier == defaultId,
                    writable: $0.allowsContentModifications)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func makeList(title: String) throws -> String {
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
        else { throw CocoaError(.featureUnsupported) }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    public func create(_ draft: AppleReminderDraft, inList listId: String) throws -> AppleReminder {
        guard let calendar = store.calendar(withIdentifier: listId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        if let link = draft.url { Self.setLink(link, on: reminder) }
        if let due = draft.dueAtMs {
            reminder.dueDateComponents = Self.dayComponents(due)
            if let alarm = draft.alarmAtMs { reminder.addAlarm(Self.alarm(alarm)) }
        }
        if draft.done { reminder.isCompleted = true }
        try store.save(reminder, commit: true)
        return Self.snapshot(reminder)
    }

    public func update(id: String, to draft: AppleReminderDraft) throws -> AppleReminder? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        reminder.title = draft.title
        if let link = draft.url { Self.setLink(link, on: reminder) }
        Self.setDueDay(draft.dueAtMs, alarmAtMs: draft.alarmAtMs, on: reminder)
        if reminder.isCompleted != draft.done { reminder.isCompleted = draft.done }
        try store.save(reminder, commit: true)
        return Self.snapshot(reminder)
    }

    public func move(id: String, toList listId: String) throws -> AppleReminder? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
            let calendar = store.calendar(withIdentifier: listId)
        else { return nil }
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
        return Self.snapshot(reminder)
    }

    public func delete(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    public func setLink(_ link: URL, on id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        Self.setLink(link, on: reminder)
        try store.save(reminder, commit: true)
    }

    public func linked(to followUpIds: Set<String>) async -> [String: AppleReminder] {
        guard authorized, !followUpIds.isEmpty else { return [:] }
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                var found: [String: AppleReminder] = [:]
                for reminder in reminders ?? [] {
                    guard let id = ReminderLink.followUpId(in: reminder.url), followUpIds.contains(id)
                    else { continue }
                    found[id] = Self.snapshot(reminder)
                }
                continuation.resume(returning: found)
            }
        }
    }

    public func allLinked() async -> [AppleReminder]? {
        guard authorized else { return nil }
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(
                    returning: reminders?
                        .filter { ReminderLink.followUpId(in: $0.url) != nil }
                        .map(Self.snapshot))
            }
        }
    }

    public func reminders(ids: [String]) -> [AppleReminder] {
        guard authorized else { return [] }
        return ids.compactMap { (store.calendarItem(withIdentifier: $0) as? EKReminder) }
            .map(Self.snapshot)
    }

    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil
        ) { _ in onChange() }
    }

    /// Writes the link in both places a reminder can hold one. `url` is the public field: the
    /// Reminders app never shows it, but it is what tells a reminder apart as ours after its
    /// identifier changes. `action` is what Reminders draws: the app's icon under the title, and
    /// a "Shared from Pebble Audio" row in Details that opens the link. It is not in EventKit's
    /// headers, so it is only set where this iOS has it; without it, there is no row.
    static func setLink(_ link: URL, on reminder: EKReminder) {
        reminder.url = link
        let setAction = NSSelectorFromString("setAction:")
        if reminder.responds(to: setAction) {
            _ = reminder.perform(setAction, with: link as NSURL)
        }
    }

    /// Moves the due day. A time of day the person set is kept, and so is every alarm but the one
    /// that rang for the old due date. The same day changes nothing.
    static func setDueDay(_ dueAtMs: Int64?, alarmAtMs: Int64?, on reminder: EKReminder) {
        let old = reminder.dueDateComponents
        let oldDate = old.flatMap { Calendar.current.date(from: $0) }
        let oldMs = oldDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        guard !RemindersHome.sameDay(oldMs, dueAtMs) else { return }
        let hasTime = old?.hour != nil
        if let oldDate {
            for alarm in reminder.alarms ?? [] {
                guard let at = alarm.absoluteDate, alarm.structuredLocation == nil else { continue }
                let rangForDue = hasTime
                    ? abs(at.timeIntervalSince(oldDate)) < 60
                    : Calendar.current.isDate(at, inSameDayAs: oldDate)
                if rangForDue { reminder.removeAlarm(alarm) }
            }
        }
        guard let dueAtMs else {
            reminder.dueDateComponents = nil
            return
        }
        var due = dayComponents(dueAtMs)
        if hasTime, let old {
            due.hour = old.hour
            due.minute = old.minute
            due.timeZone = old.timeZone
        }
        reminder.dueDateComponents = due
        if hasTime, let date = Calendar.current.date(from: due) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        } else if let alarmAtMs {
            reminder.addAlarm(alarm(alarmAtMs))
        }
    }

    private static func dayComponents(_ ms: Int64) -> DateComponents {
        Calendar.current.dateComponents(
            [.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static func alarm(_ ms: Int64) -> EKAlarm {
        EKAlarm(absoluteDate: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func snapshot(_ reminder: EKReminder) -> AppleReminder {
        let components = reminder.dueDateComponents
        let due = components.flatMap { Calendar.current.date(from: $0) }
        return AppleReminder(
            id: reminder.calendarItemIdentifier,
            listId: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            done: reminder.isCompleted,
            dueAtMs: due.map { Int64($0.timeIntervalSince1970 * 1000) },
            dueHasTime: components?.hour != nil,
            modifiedAtMs: reminder.lastModifiedDate.map { Int64($0.timeIntervalSince1970 * 1000) }
                ?? 0,
            link: reminder.url,
            createdAtMs: reminder.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
    }

    static func hex(_ color: CGColor?) -> String {
        guard let components = color?.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components, components.count >= 3
        else { return "#8E8E93" }
        let value = components.prefix(3).map { min(255, max(0, Int(($0 * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", value[0], value[1], value[2])
    }
}
