import Foundation
import MuseLink
import Testing
import WireProtocol

@testable import CompanionRuntime

/// Muse's reminders tool: every list, not just the default one; edits and deletes by id; a named
/// list that isn't there is an error naming the lists, never an add somewhere else (2026-10-22:
/// "Grocery" landed in the default list because "Groceries" doesn't contain it). Under Ask first,
/// changes are asked about once per question, in general terms.
struct MuseRemindersTests {
    typealias List = MuseEventKitSource.ReminderList

    static let lists = [
        List(id: "L1", name: "TODO", isDefault: true),
        List(id: "L2", name: "Groceries", isDefault: false),
        List(id: "L3", name: "Work Errands", isDefault: false),
        List(id: "L4", name: "Work Projects", isDefault: false),
        List(id: "L5", name: "To-Do Later", isDefault: false),
        List(id: "L6", name: "Family (shared)", isDefault: false, canChange: false),
    ]

    // MARK: - Which list a name means

    @Test func aListNameMatchesExactlyThenLooselyThenNever() {
        func match(_ name: String) -> MuseReminders.ListMatch { MuseReminders.match(name, in: Self.lists) }
        #expect(match("groceries") == .found(Self.lists[1]))
        #expect(match("todo") == .found(Self.lists[0]))
        // Singular for plural, and "list" or "my" around the name.
        #expect(match("Grocery") == .found(Self.lists[1]))
        #expect(match("Grocery list") == .found(Self.lists[1]))
        #expect(match("my groceries list") == .found(Self.lists[1]))
        // Punctuation and spacing don't matter.
        #expect(match("to do later") == .found(Self.lists[4]))
        // One name inside the other, when only one list fits.
        #expect(match("Errands") == .found(Self.lists[2]))
        // Two lists fit as well as each other.
        #expect(match("Work") == .ambiguous([Self.lists[2], Self.lists[3]]))
        #expect(match("Shopping") == .notFound)
        #expect(match("  ") == .notFound)
    }

    // MARK: - Adding to a named list

    @Test func anAddLandsInTheNamedListAndSaysWhichOne() async throws {
        let fx = RemindersFixture(access: .allowed)
        let result = await fx.run(["action": "add", "title": "Small spatula", "list": "Grocery"])
        #expect(result["ok"]?.bool == true)
        let added = try #require(result["payload"]?["added"])
        #expect(added["list"]?.string == "Groceries")
        #expect(added["title"]?.string == "Small spatula")
        #expect(added["id"]?.string?.isEmpty == false)
        #expect(fx.eventKit.titles(in: "L2") == ["Small spatula"])
        #expect(fx.eventKit.titles(in: "L1").isEmpty)
    }

    @Test func anUnknownListIsAnErrorNamingTheListsAndNothingIsAdded() async {
        let fx = RemindersFixture(access: .allowed)
        let result = await fx.run(["action": "add", "title": "Small spatula", "list": "Hardware"])
        #expect(result["ok"]?.bool == false)
        let message = result["error"]?.string ?? ""
        #expect(message.hasPrefix("There is no reminders list called \"Hardware\"."))
        #expect(message.contains("\"TODO\", \"Groceries\""))
        #expect(message.contains(", and \"Family (shared)\""))
        #expect(result["lists"]?.array?.count == Self.lists.count)
        #expect(fx.eventKit.all().isEmpty)
    }

    @Test func noListMeansTheDefaultOneAndTheReplySaysSo() async {
        let fx = RemindersFixture(access: .allowed)
        let result = await fx.run(["action": "add", "title": "Call the vet", "due": "2026-10-23"])
        #expect(result["payload"]?["added"]?["list"]?.string == "TODO")
        #expect(result["payload"]?["added"]?["due"]?.string == "2026-10-23")
    }

    @Test func aReadOnlyListIsSaidPlainly() async {
        let fx = RemindersFixture(access: .allowed)
        let result = await fx.run(["action": "add", "title": "Milk", "list": "family"])
        #expect(result["error"]?.string == "The list \"Family (shared)\" is shared read only, so it can't be changed. Nothing was changed.")
        #expect(fx.eventKit.all().isEmpty)
    }

    @Test func underAskFirstAnUnknownListNamesNoListsUntilReadingIsAllowed() async {
        let fx = RemindersFixture(access: .ask)
        let result = await fx.run(["action": "add", "title": "Small spatula", "list": "Hardware"])
        #expect(result["error"]?.string?.contains("Call reminders with action lists") == true)
        #expect(result["error"]?.string?.contains("Groceries") == false)
        // Nothing was asked on the watch for a call that can't happen.
        #expect(fx.watch.questions().isEmpty)
    }

    // MARK: - Reading

    @Test func listsSayWhichIsTheDefaultAndReadGivesIDs() async throws {
        let fx = RemindersFixture(access: .allowed)
        _ = fx.eventKit.seed("Eggs", list: "L2")
        _ = fx.eventKit.seed("Ship the deck", list: "L3", completed: true)
        let lists = await fx.run(["action": "lists"])
        #expect(lists["payload"]?["default_list"]?.string == "TODO")
        let names = lists["payload"]?["lists"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == Self.lists.map(\.name))
        #expect(lists["payload"]?["lists"]?.array?.last?["read_only"]?.bool == true)

        let read = await fx.run(["action": "read", "list": "grocery"])
        #expect(read["payload"]?["list"]?.string == "Groceries")
        let eggs = try #require(read["payload"]?["reminders"]?.array?.first)
        #expect(eggs["title"]?.string == "Eggs")
        #expect(eggs["id"]?.string?.isEmpty == false)
        #expect(eggs["completed"]?.bool == false)

        // Not done by default; done ones only when asked.
        #expect((await fx.run(["action": "read"]))["payload"]?["reminders"]?.array?.count == 1)
        #expect((await fx.run(["action": "read", "include_completed": "true"]))["payload"]?["reminders"]?.array?.count == 2)
        // The old action name still reads.
        #expect((await fx.run(["action": "list"]))["payload"]?["reminders"]?.array?.count == 1)
        // A list that isn't there is an error, not an empty list.
        #expect((await fx.run(["action": "read", "list": "Hardware"]))["ok"]?.bool == false)
    }

    // MARK: - Editing and deleting by id

    @Test func editRenamesCompletesMovesAndClearsTheDueDate() async throws {
        let fx = RemindersFixture(access: .allowed)
        let id = fx.eventKit.seed("Get a small spatula", list: "L1", due: Date(timeIntervalSince1970: 1_800_000_000))

        let moved = await fx.run(["action": "edit", "id": .string(id), "list": "Groceries", "title": "Small spatula"])
        #expect(moved["payload"]?["updated"]?["list"]?.string == "Groceries")
        #expect(moved["payload"]?["updated"]?["title"]?.string == "Small spatula")
        #expect(moved["payload"]?["moved_from"]?.string == "TODO")
        #expect(moved["payload"]?["changed"] == ["title", "list"])

        let cleared = await fx.run(["action": "edit", "id": .string(id), "due": "none"])
        #expect(cleared["payload"]?["updated"]?["due"] == nil)
        #expect(cleared["payload"]?["changed"] == ["due"])

        let done = await fx.run(["action": "complete", "id": .string(id)])
        #expect(done["payload"]?["updated"]?["completed"]?.bool == true)
        let again = await fx.run(["action": "edit", "id": .string(id), "completed": false])
        #expect(again["payload"]?["updated"]?["completed"]?.bool == false)
        #expect(fx.eventKit.all().first?.listID == "L2")

        // Nothing to change, and no id, are said plainly.
        #expect((await fx.run(["action": "edit", "id": .string(id)]))["error"]?.string?.hasPrefix("edit needs something to change") == true)
        #expect((await fx.run(["action": "edit", "title": "x"]))["error"]?.string?.hasPrefix("edit needs the reminder's id") == true)
    }

    @Test func deleteRemovesItOnceAndARepeatGetsTheFirstAnswer() async {
        let fx = RemindersFixture(access: .allowed)
        let id = fx.eventKit.seed("Small spatula", list: "L1")
        let deleted = await fx.run(["action": "delete", "id": .string(id)])
        #expect(deleted["payload"]?["deleted"]?["title"]?.string == "Small spatula")
        #expect(deleted["payload"]?["deleted"]?["list"]?.string == "TODO")
        #expect(fx.eventKit.all().isEmpty)
        // Muse retries a call whose reply it never got.
        #expect(await fx.run(["action": "delete", "id": .string(id)]) == deleted)
        // An id that was never there.
        let missing = await fx.run(["action": "delete", "id": "nope"])
        #expect(missing["error"]?.string?.hasPrefix("There is no reminder with that id") == true)
    }

    // MARK: - Asking first, once per question

    static let changeQuestion = "Let Muse add to, change, or delete your reminders? What it reads goes to Meta."

    @Test func oneGeneralQuestionCoversEveryKindOfChangeAndReading() async {
        #expect(MuseTools.changeQuestion(.reminders) == Self.changeQuestion)
        #expect(Self.changeQuestion.utf8.count <= ProtocolConstants.watchActionQuestionMaxBytes)
        let fx = RemindersFixture(access: .ask)
        let id = fx.eventKit.seed("Small spatula", list: "L1")
        fx.watch.answer(value: 0)  // Allow Once

        // "Add eggs to my grocery list": one question, which covers reading the lists too.
        let added = await fx.run(["action": "add", "title": "Eggs", "list": "groceries"])
        #expect(added["payload"]?["added"]?["list"]?.string == "Groceries")
        #expect((await fx.run(["action": "lists"]))["ok"]?.bool == true)
        #expect((await fx.run(["action": "edit", "id": .string(id), "completed": true]))["ok"]?.bool == true)
        #expect((await fx.run(["action": "edit", "id": .string(id), "list": "Groceries"]))["ok"]?.bool == true)
        #expect((await fx.run(["action": "read"]))["ok"]?.bool == true)
        let deleted = await fx.run(["action": "delete", "id": .string(id)])
        #expect(deleted["payload"]?["deleted"]?["title"]?.string == "Small spatula")
        #expect(fx.watch.questions() == [Self.changeQuestion])
        #expect(fx.eventKit.titles(in: "L2") == ["Eggs"])
        #expect(fx.preferences.current.value.access(.reminders) == .ask)
    }

    @Test func allowOnceCoversTenChangesThenAsksAgainAndANewQuestionAsksAgain() async {
        let fx = RemindersFixture(access: .ask)
        fx.watch.answer(value: 0)
        for item in 1...MuseTools.changesPerAllowOnce {
            #expect((await fx.run(["action": "add", "title": .string("Item \(item)"), "list": "Groceries"]))["ok"]?.bool == true)
        }
        #expect(fx.watch.questions().count == 1)
        // The eleventh asks again, once, and that answer covers ten more.
        _ = await fx.run(["action": "add", "title": "Item 11", "list": "Groceries"])
        _ = await fx.run(["action": "add", "title": "Item 12", "list": "Groceries"])
        #expect(fx.watch.questions() == [Self.changeQuestion, Self.changeQuestion])
        #expect(fx.eventKit.titles(in: "L2").count == 12)

        // A new question from the watch starts over.
        await fx.tools.questionBegan()
        _ = await fx.run(["action": "add", "title": "Item 13", "list": "Groceries"])
        #expect(fx.watch.questions().count == 3)
    }

    @Test func allowOnceEndsWithTheQuestionsWindow() async {
        let fx = RemindersFixture(access: .ask)
        fx.watch.answer(value: 0)
        _ = await fx.run(["action": "add", "title": "Eggs", "list": "Groceries"])
        fx.clock.advance(MuseTools.changeSession + 1)
        _ = await fx.run(["action": "add", "title": "Milk", "list": "Groceries"])
        #expect(fx.watch.questions().count == 2)
    }

    @Test func notNowDeclinesTheRestOfTheQuestionsChangesWithoutAskingAgain() async {
        let fx = RemindersFixture(access: .ask)
        let id = fx.eventKit.seed("Small spatula", list: "L2")
        fx.watch.answer(value: 2)  // Not Now
        let result = await fx.run(["action": "delete", "id": .string(id)])
        #expect(result == MuseTools.reply(.changeDeclined, .reminders))
        #expect(MuseTools.outcome(of: result) == .declined)
        // More changes: refused at once, nothing asked, nothing changed.
        #expect(await fx.run(["action": "add", "title": "Eggs", "list": "Groceries"]) == MuseTools.reply(.changeDeclined, .reminders))
        #expect(await fx.run(["action": "edit", "id": .string(id), "completed": true]) == MuseTools.reply(.changeDeclined, .reminders))
        #expect(fx.watch.questions() == [Self.changeQuestion])
        #expect(fx.eventKit.all().count == 1)
        #expect(fx.preferences.current.value.access(.reminders) == .ask)
        // Reading is asked about as before.
        fx.watch.answer(value: 0)
        #expect((await fx.run(["action": "read"]))["ok"]?.bool == true)
        #expect(fx.watch.questions().last == "Let Muse read your reminders? What it reads goes to Meta.")
        // A new question may ask about changes again.
        await fx.tools.questionBegan()
        #expect((await fx.run(["action": "add", "title": "Eggs", "list": "Groceries"]))["ok"]?.bool == true)
        #expect(fx.watch.questions().last == Self.changeQuestion)
    }

    @Test func readingAllowedOnceDoesNotAllowAChange() async {
        let fx = RemindersFixture(access: .ask)
        let id = fx.eventKit.seed("Small spatula", list: "L2")
        fx.watch.answer(value: 0)
        _ = await fx.run(["action": "read"])
        #expect(fx.watch.questions() == ["Let Muse read your reminders? What it reads goes to Meta."])
        _ = await fx.run(["action": "delete", "id": .string(id)])
        #expect(fx.watch.questions().last == Self.changeQuestion)
        #expect(fx.eventKit.all().isEmpty)
    }

    @Test func alwaysAllowOnAChangeMakesRemindersAllowed() async {
        let fx = RemindersFixture(access: .ask)
        fx.watch.answer(value: 1)
        _ = await fx.run(["action": "add", "title": "Eggs", "list": "Groceries"])
        #expect(fx.preferences.current.value.access(.reminders) == .allowed)
        await fx.tools.questionBegan()
        _ = await fx.run(["action": "add", "title": "Milk", "list": "Groceries"])
        #expect(fx.watch.questions().count == 1)
        #expect(fx.eventKit.titles(in: "L2") == ["Eggs", "Milk"])
    }

    // MARK: - What Muse is told exists

    @Test func theToolOffersListsReadAddEditAndDeleteOrNothingWhenOff() {
        var prefs = MusePreferences()
        let offered = MuseTools.commands(for: prefs, hasData: true)[MuseTools.remindersCommand]
        #expect(offered?["required"]?["action"]?["description"]?.string == "One of: lists, read, add, edit, delete.")
        #expect(offered?["optional"]?["id"] != nil)
        #expect(offered?["optional"]?["completed"] != nil)
        prefs.dataAccess[.reminders] = .off
        #expect(MuseTools.commands(for: prefs, hasData: true)[MuseTools.remindersCommand] == nil)
    }
}

// MARK: - Fakes

private struct RemindersFixture {
    let preferences = MusePreferencesStore(defaults: UserDefaults(suiteName: "muse-reminders-\(UUID().uuidString)")!)
    let eventKit = FakeReminderStore(lists: MuseRemindersTests.lists)
    let watch = FakeWatchSide()
    let clock: RemindersClock
    let tools: MuseTools

    init(access: MuseSourceAccess) {
        preferences.update { $0.dataAccess[.reminders] = access }
        let clock = RemindersClock()
        self.clock = clock
        tools = MuseTools(
            preferences: preferences, data: nil, eventKit: eventKit, clock: { clock.now() }, holdLimit: .seconds(5))
    }

    func run(_ params: MuseJSON) async -> MuseJSON {
        await tools.run(MuseTools.remindersCommand, params, watch: watch)
    }
}

private final class RemindersClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    func now() -> Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

/// The watch: answers every question with the same choice, and keeps what it was asked.
private final class FakeWatchSide: MuseWatchSide, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var choice = 2

    func answer(value: Int) { lock.withLock { choice = value } }
    func questions() -> [String] { lock.withLock { asked } }

    func runWatchAction(_ request: WatchActionRequest, wait: Duration) async -> WatchActionResult? {
        let value: Int = lock.withLock {
            if case .choose(let question, _, _) = request { asked.append(question) }
            return choice
        }
        return WatchActionResult(actionId: 1, statusRaw: WatchActionStatus.done.rawValue, value: value, text: [])
    }

    func showStatus(_ text: String) async {}
}

/// Reminders in memory, with iOS access given.
private final class FakeReminderStore: MuseEventKitAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let lists: [MuseEventKitSource.ReminderList]
    private var items: [MuseEventKitSource.Reminder] = []
    private var nextID = 1

    init(lists: [MuseEventKitSource.ReminderList]) { self.lists = lists }

    var calendarAuthorized: Bool { true }
    var calendarRefused: Bool { false }
    var remindersAuthorized: Bool { true }
    var remindersRefused: Bool { false }

    func events(from start: Date, to end: Date, limit: Int) -> [MuseEventKitSource.Event] { [] }
    func addEvent(title: String, start: Date, end: Date?, notes: String?) throws -> MuseEventKitSource.Event {
        throw MuseEventKitSource.Failure.notAllowed
    }

    func all() -> [MuseEventKitSource.Reminder] { lock.withLock { items } }
    func titles(in listID: String) -> [String] { all().filter { $0.listID == listID }.map(\.title) }

    func seed(_ title: String, list: String, due: Date? = nil, completed: Bool = false) -> String {
        lock.withLock {
            let id = "R\(nextID)"
            nextID += 1
            let name = lists.first { $0.id == list }?.name ?? ""
            items.append(.init(id: id, title: title, due: due, dueHasTime: due != nil, list: name, listID: list, completed: completed))
            return id
        }
    }

    func reminderLists() -> [MuseEventKitSource.ReminderList] { lists }

    func reminders(inLists listIDs: [String]?, completedSince: Date?) async -> [MuseEventKitSource.Reminder] {
        all().filter { (listIDs?.contains($0.listID) ?? true) && (!$0.completed || completedSince != nil) }
    }

    func reminder(id: String) -> MuseEventKitSource.Reminder? { all().first { $0.id == id } }

    func addReminder(title: String, due: Date?, dueHasTime: Bool, notes: String?, listID: String?) throws
        -> MuseEventKitSource.Reminder
    {
        guard let list = listID.flatMap({ id in lists.first { $0.id == id } }) ?? lists.first(where: \.isDefault) else {
            throw MuseEventKitSource.Failure.noSuchList
        }
        let id = seed(title, list: list.id, due: due)
        return try update(id) { _ in
            MuseEventKitSource.Reminder(
                id: id, title: title, due: due, dueHasTime: dueHasTime, notes: notes, list: list.name, listID: list.id)
        }
    }

    func updateReminder(id: String, _ change: MuseEventKitSource.ReminderChange) throws -> MuseEventKitSource.Reminder {
        try update(id) { old in
            let list = change.listID.flatMap { id in self.lists.first { $0.id == id } }
            var due = old.due
            var hasTime = old.dueHasTime
            switch change.due {
            case .set(let date, let time)?: (due, hasTime) = (date, time)
            case .clear?: (due, hasTime) = (nil, false)
            case nil: break
            }
            return MuseEventKitSource.Reminder(
                id: old.id, title: change.title ?? old.title, due: due, dueHasTime: hasTime,
                notes: change.notes.map { $0.isEmpty ? nil : $0 } ?? old.notes,
                list: list?.name ?? old.list, listID: list?.id ?? old.listID, completed: change.completed ?? old.completed)
        }
    }

    func deleteReminder(id: String) throws -> MuseEventKitSource.Reminder {
        try lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw MuseEventKitSource.Failure.noSuchReminder }
            return items.remove(at: index)
        }
    }

    private func update(
        _ id: String, _ change: (MuseEventKitSource.Reminder) -> MuseEventKitSource.Reminder
    ) throws -> MuseEventKitSource.Reminder {
        try lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw MuseEventKitSource.Failure.noSuchReminder }
            items[index] = change(items[index])
            return items[index]
        }
    }
}
