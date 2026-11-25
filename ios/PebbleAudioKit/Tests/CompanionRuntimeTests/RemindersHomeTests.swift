import AppDB
import EventKit
import Foundation
import Testing

@testable import CompanionRuntime

// Where reminders are kept (`docs/reminders.md`): moving them between the app and Apple
// Reminders, a change of list, and both sides staying in step.

private final class FakeAppleReminders: AppleRemindersAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _lists: [AppleReminderList] = [
        AppleReminderList(id: "todo", title: "TODO", colorHex: "#FF9500", isDefault: true, writable: true),
        AppleReminderList(id: "groceries", title: "Groceries", colorHex: "#34C759", isDefault: false, writable: true),
    ]
    private var _items: [String: AppleReminder] = [:]
    private var counter = 0
    var clock: Int64 = 1_000

    var failDelete = false
    var authorized = true
    var refused = false
    func requestAccess() async -> Bool { authorized }
    func lists() -> [AppleReminderList] { lock.withLock { _lists } }
    var items: [AppleReminder] { lock.withLock { Array(_items.values) } }
    func item(_ id: String) -> AppleReminder? { lock.withLock { _items[id] } }

    func makeList(title: String) throws -> String {
        lock.withLock {
            let id = "list-\(title)"
            _lists.append(AppleReminderList(id: id, title: title, colorHex: "#5B5BD6", isDefault: false, writable: true))
            return id
        }
    }
    func create(_ draft: AppleReminderDraft, inList listId: String) throws -> AppleReminder {
        lock.withLock {
            counter += 1
            let item = AppleReminder(
                id: "apple-\(counter)", listId: listId, title: draft.title, done: draft.done,
                dueAtMs: draft.dueAtMs, dueHasTime: false, modifiedAtMs: clock, link: draft.url)
            _items[item.id] = item
            return item
        }
        .announced(by: self)
    }
    func update(id: String, to draft: AppleReminderDraft) throws -> AppleReminder? {
        lock.withLock {
            guard var item = _items[id] else { return nil }
            item.title = draft.title
            item.done = draft.done
            item.dueAtMs = draft.dueAtMs
            item.link = draft.url ?? item.link
            item.modifiedAtMs = clock
            _items[id] = item
            return item
        }
    }
    func move(id: String, toList listId: String) throws -> AppleReminder? {
        lock.withLock {
            guard var item = _items[id] else { return nil }
            item.listId = listId
            _items[id] = item
            return item
        }
    }
    func delete(id: String) throws {
        if failDelete { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { _items[id] = nil }
    }
    private(set) var linkWrites = 0
    /// A list that takes the save and keeps no link.
    var dropsLinks = false
    func setLink(_ link: URL, on id: String) throws {
        lock.withLock {
            linkWrites += 1
            if !dropsLinks { _items[id]?.link = link }
        }
    }
    func linked(to followUpIds: Set<String>) async -> [String: AppleReminder] {
        lock.withLock {
            var found: [String: AppleReminder] = [:]
            for item in _items.values {
                if let id = ReminderLink.followUpId(in: item.link), followUpIds.contains(id) { found[id] = item }
            }
            return found
        }
    }
    /// The same reminder under a new identifier, as a move to another account leaves it.
    func reidentify(_ id: String, as new: String, listId: String) {
        lock.withLock {
            guard var item = _items.removeValue(forKey: id) else { return }
            item.id = new
            item.listId = listId
            _items[new] = item
        }
    }
    func reminders(ids: [String]) -> [AppleReminder] { lock.withLock { ids.compactMap { _items[$0] } } }
    /// What Reminders does after every save of ours: it says its data changed.
    private var onChange: (@Sendable () -> Void)?
    /// Runs first, before a save is announced.
    var beforeAnnouncing: (@Sendable () -> Void)?
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        lock.withLock { self.onChange = onChange }
        return NSObject()
    }
    func announce() {
        beforeAnnouncing?()
        lock.withLock { onChange }?()
    }

    /// The person, in Apple Reminders.
    func edit(_ id: String, at ms: Int64, _ change: (inout AppleReminder) -> Void) {
        lock.withLock {
            guard var item = _items[id] else { return }
            change(&item)
            item.modifiedAtMs = ms
            _items[id] = item
        }
    }
}

extension AppleReminder {
    fileprivate func announced(by apple: FakeAppleReminders) -> AppleReminder {
        apple.announce()
        return self
    }
}

private final class FakeAlerts: ReminderAlertScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled: [String: (String, String, Date)] = [:]
    var scheduled: [String: (String, String, Date)] { lock.withLock { _scheduled } }
    func pending(prefix: String) async -> Set<String> {
        lock.withLock { Set(_scheduled.keys.filter { $0.hasPrefix(prefix) }) }
    }
    func schedule(id: String, title: String, body: String, at date: Date, route: String) async {
        lock.withLock { _scheduled[id] = (title, body, date) }
    }
    func remove(ids: [String]) async { lock.withLock { ids.forEach { _scheduled[$0] = nil } } }
    func allowed() async -> Bool { true }
    func requestPermission() async -> Bool { true }
}

@Suite struct RemindersHomeTests {
    let db: AppDatabase
    let store: FollowUpStore
    fileprivate let apple = FakeAppleReminders()
    fileprivate let alerts = FakeAlerts()
    let preferences = ReminderPreferencesStore(
        defaults: UserDefaults(suiteName: "reminders-\(UUID().uuidString)")!)
    let now: Int64 = 1_788_000_000_000

    init() throws {
        db = try AppDatabase.inMemory()
        store = FollowUpStore(db: db)
    }

    func home() -> RemindersHome {
        let now = self.now
        return RemindersHome(
            followUps: store, apple: apple, alerts: alerts, preferences: preferences,
            nowMs: { now })
    }

    func put(_ id: String, stage: FollowUpStage = .reminder, due: Int64? = nil) async throws {
        try await store.upsertExtracted(
            FollowUp(
                id: id, text: "task \(id)", done: false, sourceConversationId: "c",
                sourceSegmentId: nil, createdAtMs: now - 10_000, dueAtMs: due, stage: stage,
                decidedAtMs: stage == .suggested ? nil : now - 10_000))
    }

    @Test func switchingToAppleMovesEveryOpenReminderToTheListPicked() async throws {
        try await put("a")
        try await put("b")
        try await put("s", stage: .suggested)
        try await put("k", stage: .skipped)
        let home = home()
        #expect(await home.openReminderCount() == 2)

        #expect(try await home.switchToApple(.existing(id: "groceries")) == 2)
        #expect(preferences.current.value.home == .apple)
        #expect(preferences.current.value.appleListId == "groceries")
        #expect(Set(apple.items.map(\.title)) == ["task a", "task b"])
        #expect(apple.items.allSatisfy { $0.listId == "groceries" })
        #expect(try await store.load(id: "a")?.appleId != nil)
        #expect(try await store.load(id: "s")?.appleId == nil)
    }

    @Test func concurrentSyncDeliversOnceToTheSelectedListAndReopenRemovesIt() async throws {
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        try await put("selected", stage: .suggested)
        #expect(try await store.reviewFromAssistant(id: "selected", stage: .reminder, appleListId: "groceries"))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await home.sync() } }
        }
        #expect(apple.items.count == 1)
        #expect(apple.items.first?.listId == "groceries")
        #expect(try await store.reviewFromAssistant(id: "selected", stage: .suggested, reopen: true))
        apple.failDelete = true
        await home.sync()
        #expect(apple.items.count == 1)
        #expect(try await store.load(id: "selected")?.appleId != nil)
        apple.failDelete = false
        await home.sync()
        #expect(apple.items.isEmpty)
        #expect(try await store.load(id: "selected")?.appleId == nil)
    }

    /// 2026-11-25: Reminders announced each reminder the app made, the announcement cancelled the
    /// pass that was saving its identifier, and the next pass made it again.
    @Test func aReminderIsMadeOnceHoweverReminderChangesArrive() async throws {
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        await home.start(database: db)
        // The database is busy when the identifier is to be saved, as it is on the phone.
        let writer = db.writer
        apple.beforeAnnouncing = {
            writer.asyncWriteWithoutTransaction { _ in Thread.sleep(forTimeInterval: 0.2) }
        }
        try await put("a")
        try await Task.sleep(for: .seconds(4))
        #expect(apple.items.count == 1)
        #expect(try await store.load(id: "a")?.appleId == apple.items.first?.id)
    }

    @Test func aScreenThatGoesAwayMidMoveLeavesNoReminderTheAppLostTrackOf() async throws {
        try await put("a")
        try await put("b")
        let home = home()
        let writer = db.writer
        apple.beforeAnnouncing = {
            writer.asyncWriteWithoutTransaction { _ in Thread.sleep(forTimeInterval: 0.2) }
        }
        let screen = Task { try await home.switchToApple(.existing(id: "todo")) }
        try await Task.sleep(for: .milliseconds(100))
        screen.cancel()
        _ = try? await screen.value
        await home.sync()
        #expect(apple.items.count == 2)
        let kept = try await store.list(scope: .open, nowMs: now).compactMap(\.appleId)
        #expect(Set(kept) == Set(apple.items.map(\.id)))
    }

    @Test func theNewListIsMadeOnceAndUsed() async throws {
        try await put("a")
        let home = home()
        try await home.switchToApple(.newList)
        let list = try #require(preferences.current.value.appleListId)
        #expect(apple.lists().filter { $0.title == RemindersHome.newListTitle }.count == 1)
        #expect(apple.items.first?.listId == list)
        // Picking it again does not make a second one.
        try await home.changeList(.newList, moveOpen: true)
        #expect(apple.lists().filter { $0.title == RemindersHome.newListTitle }.count == 1)
    }

    @Test func aChangeOfListMovesOnlyWhatWasInTheOldListAndOnlyWhenAsked() async throws {
        try await put("a")
        try await put("b")
        try await put("c")
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        // The person moved one to Groceries themselves, in the Reminders app.
        let movedByHand = try #require(try await store.load(id: "c")?.appleId)
        _ = try apple.move(id: movedByHand, toList: "groceries")
        await home.sync()
        #expect(await home.openCount(inList: "todo") == 2)

        // Only new ones: nothing moves.
        #expect(try await home.changeList(.newList, moveOpen: false) == 0)
        #expect(apple.items.filter { $0.listId == "todo" }.count == 2)

        // Back to TODO, then to Groceries with the open ones: the two in TODO go; the hand-moved
        // one was already somewhere the person chose.
        try await home.changeList(.existing(id: "todo"), moveOpen: false)
        #expect(try await home.changeList(.existing(id: "groceries"), moveOpen: true) == 2)
        #expect(apple.items.allSatisfy { $0.listId == "groceries" })
    }

    @Test func aTickOrADeleteInAppleRemindersReachesTheApp() async throws {
        try await put("a")
        try await put("b")
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        let a = try #require(try await store.load(id: "a")?.appleId)
        let b = try #require(try await store.load(id: "b")?.appleId)

        apple.edit(a, at: now + 5_000) {
            $0.done = true
            $0.title = "Renamed in Reminders"
        }
        try apple.delete(id: b)
        await home.sync()
        let ticked = try await store.load(id: "a")
        #expect(ticked?.done == true)
        #expect(ticked?.text == "Renamed in Reminders")
        #expect(try await store.load(id: "b")?.archivedAtMs != nil)

        // Nothing changed since: a pass writes nothing on either side.
        let before = apple.item(a)
        await home.sync()
        #expect(apple.item(a) == before)
    }

    @Test func aTickOrASkipInTheAppReachesAppleReminders() async throws {
        try await put("a")
        try await put("b")
        let home = home()
        apple.clock = now - 60_000
        try await home.switchToApple(.existing(id: "todo"))
        let a = try #require(try await store.load(id: "a")?.appleId)
        let b = try #require(try await store.load(id: "b")?.appleId)

        try await store.setDone(id: "a", true, nowMs: now)
        try await store.setStage(id: "b", .skipped, nowMs: now)
        await home.sync()
        #expect(apple.item(a)?.done == true)
        #expect(apple.item(b) == nil)
        #expect(try await store.load(id: "b")?.appleId == nil)
    }

    @Test func aReminderLinksBackAndOlderOnesGetTheirLinkOnce() async throws {
        try await put("a")
        try await put("b")
        try await put("finished")
        let home = home()
        apple.clock = now - 60_000
        try await home.switchToApple(.existing(id: "todo"))
        let a = try #require(try await store.load(id: "a")?.appleId)
        let finished = try #require(try await store.load(id: "finished")?.appleId)
        #expect(apple.item(a)?.link?.absoluteString == "companion://followup/a")

        // Made before the link worked, in the form the app could not open.
        apple.edit(a, at: now - 60_000) { $0.link = URL(string: "companion://followup?id=a") }
        apple.edit(finished, at: now + 5_000) {
            $0.link = nil
            $0.done = true
        }
        await home.sync()
        await home.sync()
        #expect(apple.item(a)?.link?.absoluteString == "companion://followup/a")
        #expect(apple.linkWrites == 1)

        // One that won't hold a link is tried once, not on every change it causes.
        let b = try #require(try await store.load(id: "b")?.appleId)
        apple.dropsLinks = true
        apple.edit(b, at: now - 60_000) { $0.link = nil }
        for _ in 0..<3 { await home.sync() }
        #expect(apple.linkWrites == 2)
    }

    @Test func aReminderWithANewIdentifierIsFoundByItsLinkNotFiledAway() async throws {
        try await put("a")
        try await put("b")
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        let a = try #require(try await store.load(id: "a")?.appleId)
        let b = try #require(try await store.load(id: "b")?.appleId)
        apple.reidentify(a, as: "moved", listId: "groceries")
        apple.edit("moved", at: now + 5_000) { $0.done = true }
        try apple.delete(id: b)
        await home.sync()

        let found = try await store.load(id: "a")
        #expect(found?.appleId == "moved" && found?.appleListId == "groceries")
        #expect(found?.archivedAtMs == nil && found?.done == true)
        // One that is really gone still leaves the list.
        #expect(try await store.load(id: "b")?.archivedAtMs != nil)
    }

    @Test func anAppSideChangeKeepsWhatThePersonPutOnTheReminder() throws {
        let day = RemindersHome.startOfDay(now)
        let date = { (ms: Int64) in Date(timeIntervalSince1970: Double(ms) / 1000) }
        let reminder = EKReminder(eventStore: EKEventStore())
        let place = EKAlarm()
        place.structuredLocation = EKStructuredLocation(title: "Home")
        place.proximity = .enter

        // Due at 3:30 PM, set in Reminders, with its alarm and one for a place.
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: date(day))
        parts.hour = 15
        parts.minute = 30
        reminder.dueDateComponents = parts
        reminder.alarms = [EKAlarm(absoluteDate: Calendar.current.date(from: parts)!), place]

        // The same day: nothing moves.
        EventKitReminders.setDueDay(day, alarmAtMs: day + 9 * 3_600_000, on: reminder)
        #expect(reminder.dueDateComponents?.hour == 15 && reminder.alarms?.count == 2)

        // The next day: still 3:30 PM, its alarm with it, the place alarm untouched.
        EventKitReminders.setDueDay(day + 86_400_000, alarmAtMs: nil, on: reminder)
        #expect(reminder.dueDateComponents?.hour == 15 && reminder.dueDateComponents?.minute == 30)
        let moved = date(day + 86_400_000 + (15 * 60 + 30) * 60_000)
        #expect(reminder.alarms?.compactMap(\.absoluteDate) == [moved])
        #expect(reminder.alarms?.contains { $0.structuredLocation != nil } == true)

        // No date: the due alarm goes, the place alarm stays.
        EventKitReminders.setDueDay(nil, alarmAtMs: nil, on: reminder)
        #expect(reminder.dueDateComponents == nil)
        #expect(reminder.alarms?.count == 1 && reminder.alarms?.first?.structuredLocation != nil)
    }

    @Test func switchingBackBringsOpenRemindersHome() async throws {
        try await put("a")
        let home = home()
        try await home.switchToApple(.existing(id: "todo"))
        #expect(try await home.switchToApp() == 1)
        #expect(preferences.current.value.home == .app)
        #expect(apple.items.isEmpty)
        #expect(try await store.load(id: "a")?.appleId == nil)
        #expect(try await store.list(scope: .open, nowMs: now).map(\.id) == ["a"])
    }

    @Test func inTheAppADatedReminderAlertsOnItsDayAndNotOnceItIsDone() async throws {
        let tomorrow = RemindersHome.startOfDay(now) + 86_400_000
        try await put("dated", due: tomorrow)
        try await put("undated")
        try await put("suggested", stage: .suggested, due: tomorrow)
        let home = home()
        await home.sync()
        let due = alerts.scheduled.filter { $0.key.hasPrefix("reminder-due-") }
        #expect(due.count == 1)
        #expect(due.first?.value.0 == "task dated")
        #expect(
            due.first.map { Int64($0.value.2.timeIntervalSince1970 * 1000) }
                == tomorrow + 9 * 3_600_000)

        try await store.setDone(id: "dated", true, nowMs: now)
        await home.sync()
        #expect(alerts.scheduled.filter { $0.key.hasPrefix("reminder-due-") }.isEmpty)
    }

    @Test func theEveningReviewSaysWhatThereIsAndNothingWhenThereIsNothing() async throws {
        let home = home()
        preferences.update { $0.eveningReview = true }
        await home.sync()
        #expect(alerts.scheduled.isEmpty)

        try await put("s1", stage: .suggested)
        try await put("s2", stage: .suggested)
        await home.sync()
        let evening = alerts.scheduled.filter { $0.key.hasPrefix("reminder-evening-") }
        #expect(evening.count == 1)
        #expect(evening.first?.value.0 == "2 follow-ups to review")
        #expect(RemindersHome.eveningTitle(toReview: 0, added: 4) == "4 reminders added today")
        #expect(RemindersHome.eveningBody(toReview: 3, added: 4) == "4 reminders added from today.")
    }
}
