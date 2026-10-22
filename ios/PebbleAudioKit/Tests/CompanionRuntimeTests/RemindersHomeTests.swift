import AppDB
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
                dueAtMs: draft.dueAtMs, dueHasTime: false, modifiedAtMs: clock)
            _items[item.id] = item
            return item
        }
    }
    func update(id: String, to draft: AppleReminderDraft) throws -> AppleReminder? {
        lock.withLock {
            guard var item = _items[id] else { return nil }
            item.title = draft.title
            item.done = draft.done
            item.dueAtMs = draft.dueAtMs
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
    func delete(id: String) throws { lock.withLock { _items[id] = nil } }
    func reminders(ids: [String]) -> [AppleReminder] { lock.withLock { ids.compactMap { _items[$0] } } }
    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject { NSObject() }

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
