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

    @Test func calendarAddAsksForChangesEvenAfterReadingWasAllowed() async {
        let fx = RemindersFixture(access: .allowed)
        fx.watch.answer(value: 0)
        _ = await fx.tools.run(MuseTools.calendarCommand, ["action": "list"], watch: fx.watch)
        fx.watch.answer(value: 2)
        let add: MuseJSON = ["action": "add", "title": "Lunch", "start": "2026-10-27T12:00:00+07:00"]
        let result = await fx.tools.run(MuseTools.calendarCommand, add, watch: fx.watch)
        #expect(result == MuseTools.reply(.changeDeclined, .calendar))
        #expect(fx.watch.questions() == [MuseTools.consentQuestion(.calendar), MuseTools.changeQuestion(.calendar)])
        #expect(await fx.tools.run(MuseTools.calendarCommand, add, watch: fx.watch) == result)
        #expect(fx.watch.questions().count == 2)
    }

    @Test func malformedCalendarDatesAreRejectedBeforePermissions() async {
        let fx = RemindersFixture(access: .allowed)
        for params: MuseJSON in [
            ["action": "add", "title": "Lunch", "start": "tomorrow"],
            ["action": "add", "title": "Lunch", "start": "2026-10-27", "end": "bad"],
            ["action": "add", "title": "Lunch", "start": "2026-10-27", "end": "2026-10-26"],
            ["action": "list", "from": "bad"],
        ] {
            #expect(await fx.tools.run(MuseTools.calendarCommand, params, watch: fx.watch)["ok"]?.bool == false)
        }
        #expect(fx.watch.questions().isEmpty)
    }

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

    @Test func duplicateNamesRequireAnIDAndPagingReachesEveryReminder() async throws {
        let same = [MuseEventKitSource.ReminderList(id: "personal", name: "Work", isDefault: true),
                    MuseEventKitSource.ReminderList(id: "business", name: "Work", isDefault: false)]
        #expect(MuseReminders.match("Work", in: same) == .ambiguous(same))
        let fx = RemindersFixture(access: .allowed)
        for index in 0..<75 { _ = fx.eventKit.seed("Task \(index)", list: "L2", due: Date(timeIntervalSince1970: 1_800_000_000)) }
        let first = await fx.run(["action": "read", "list_id": "L2"])
        let offset = try #require(first["payload"]?["next_offset"]?.number)
        #expect(offset == 60)
        let second = await fx.run(["action": "read", "list_id": "L2", "offset": .number(offset)])
        let a = try #require(first["payload"]?["reminders"]?.array)
        let b = try #require(second["payload"]?["reminders"]?.array)
        #expect(Set((a + b).compactMap { $0["id"]?.string }).count == 75)
        #expect(second["payload"]?["next_offset"] == .null)
        #expect(await fx.run(["action": "add", "title": "Eggs", "list_id": "missing"])["ok"]?.bool == false)
        #expect(fx.eventKit.all().count == 75)
    }

    @Test func oldCalendarReadAndAddGrantDoesNotAuthorizeDeletingEvents() async throws {
        let fx = RemindersFixture(access: .allowed)
        fx.preferences.update { $0.dataAccess[.calendar] = .allowed }
        // The default fake answer is Not Now. The API must not be reached on the old grant.
        let result = await fx.tools.run(MuseTools.calendarCommand, ["action": "delete", "id": "event-id"], watch: fx.watch)
        #expect(result["ok"]?.bool == false)
        #expect(fx.watch.questions() == [MuseTools.changeQuestion(.calendar)])
        #expect(!fx.preferences.current.value.additionalChangeScopes.contains("calendar_full"))
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

    // MARK: - The Pebble Audio list

    @Test func keptInTheAppTheyAreOneMoreListCalledPebbleAudio() async throws {
        let data = FakeMuseData(home: .app)
        data.seedReminder("Call the vet")
        let fx = RemindersFixture(access: .allowed, data: data)

        let lists = await fx.run(["action": "lists"])
        let names = lists["payload"]?["lists"]?.array?.compactMap { $0["name"]?.string }
        #expect(names?.first == "Pebble Audio")
        // The person's own default list stays the default for an add that names none.
        #expect(lists["payload"]?["default_list"]?.string == "TODO")

        let timed = await fx.run(["action": "add", "title": "Eggs", "list": "pebble audio", "due": "2026-10-23T09:00:00-05:00"])
        #expect(timed["ok"]?.bool == false)
        #expect(data.open().count == 1)
        let added = await fx.run(["action": "add", "title": "Eggs", "list": "pebble audio", "due": "2026-10-23"])
        let reminder = try #require(added["payload"]?["added"])
        #expect(reminder["list"]?.string == "Pebble Audio")
        // Kept by the day: the reply says the day, not a time it didn't keep.
        #expect(reminder["due"]?.string?.count == 10)
        let id = try #require(reminder["id"]?.string)
        #expect(id.hasPrefix("pa:"))
        #expect(fx.eventKit.all().isEmpty)
        #expect(data.open().map(\.title) == ["Call the vet", "Eggs"])

        let read = await fx.run(["action": "read", "list": "Pebble Audio"])
        #expect(read["payload"]?["reminders"]?.array?.compactMap { $0["title"]?.string }.sorted() == ["Call the vet", "Eggs"])

        let done = await fx.run(["action": "edit", "id": .string(id), "completed": true])
        #expect(done["payload"]?["updated"]?["completed"]?.bool == true)
        #expect(done["payload"]?["changed"] == ["completed"])

        let deleted = await fx.run(["action": "delete", "id": .string(id)])
        #expect(deleted["payload"]?["deleted"]?["title"]?.string == "Eggs")
        #expect(deleted["payload"]?["filed_away"]?.bool == true)
        #expect(data.filedAway() == ["Eggs"])
        let after = await fx.run(["action": "read", "list": "Pebble Audio"])
        #expect(after["payload"]?["reminders"]?.array?.compactMap { $0["title"]?.string } == ["Call the vet"])
    }

    @Test func pebbleAudioRemindersHaveNoNotesAndDoNotCrossToAppleLists() async {
        let data = FakeMuseData(home: .app)
        let id = "pa:" + data.seedReminder("Call the vet")
        let fx = RemindersFixture(access: .allowed, data: data)
        #expect(await fx.run(["action": "add", "title": "Eggs", "list": "Pebble Audio", "notes": "Dozen"]) == MuseReminders.appNoNotes)
        #expect(await fx.run(["action": "edit", "id": .string(id), "list": "Groceries"]) == MuseReminders.noMoveAcrossHomes)
        let appleID = fx.eventKit.seed("Milk", list: "L2")
        #expect(await fx.run(["action": "edit", "id": .string(appleID), "list": "Pebble Audio"]) == MuseReminders.noMoveAcrossHomes)
        #expect(data.open().map(\.title) == ["Call the vet"])
    }

    @Test func withoutAppleAccessThePebbleAudioListStillWorksAlone() async {
        let data = FakeMuseData(home: .app)
        let fx = RemindersFixture(access: .allowed, data: data, authorized: false, refused: true)
        let lists = await fx.run(["action": "lists"])
        #expect(lists["payload"]?["lists"]?.array?.compactMap { $0["name"]?.string } == ["Pebble Audio"])
        #expect(lists["payload"]?["default_list"]?.string == "Pebble Audio")
        #expect(lists["payload"]?["note"]?.string == MuseReminders.noAppleAccess)
        // No list named: Pebble Audio, the only one there is.
        let added = await fx.run(["action": "add", "title": "Eggs"])
        #expect(added["payload"]?["added"]?["list"]?.string == "Pebble Audio")
        #expect(fx.watch.notices().isEmpty)
        // An Apple list needs iOS's access, which was refused: said so, on the watch too.
        let groceries = await fx.run(["action": "add", "title": "Milk", "list": "Groceries"])
        #expect(groceries == MuseTools.reply(.phoneRefused, .reminders))
        #expect(fx.watch.notices().count == 1)
        #expect(data.open().map(\.title) == ["Eggs"])
    }

    @Test func keptInAppleRemindersTheyAreNotListedTwice() async {
        let data = FakeMuseData(home: .apple)
        data.seedReminder("Call the vet")
        let fx = RemindersFixture(access: .allowed, data: data)
        _ = fx.eventKit.seed("Call the vet", list: "L1")
        let names = (await fx.run(["action": "lists"]))["payload"]?["lists"]?.array?.compactMap { $0["name"]?.string }
        #expect(names?.contains("Pebble Audio") == false)
        let read = await fx.run(["action": "read"])
        #expect(read["payload"]?["reminders"]?.array?.count == 1)
    }

    // MARK: - Follow-ups: the review queue

    @Test func followUpsAreTheReviewQueueAndCanBecomeRemindersOrBeSkipped() async throws {
        let data = FakeMuseData(home: .app)
        data.seedReminder("Already a reminder")
        data.seedSuggestion("f1", "Send Sam the deck")
        data.seedSuggestion("f2", "Book the dentist")
        let fx = RemindersFixture(access: .allowed, data: data, followUps: .allowed)

        let read = await fx.runFollowUps(["action": "read"])
        let items = try #require(read["payload"]?["follow_ups"]?.array)
        #expect(items.compactMap { $0["task"]?.string } == ["Send Sam the deck", "Book the dentist"])
        #expect(items.first?["id"]?.string == "f1")
        #expect(items.first?["conversation"]?.string == "Planning")
        #expect(items.first?["quote"]?.string == "I'll send Sam the deck")
        #expect(items.first?["why"]?.string?.isEmpty == false)
        #expect(items.first?["said_at"]?.string?.isEmpty == false)

        let reminded = await fx.runFollowUps(["action": "remind", "id": "f1"])
        #expect(reminded["payload"]?["reminder"]?["kept_in"]?.string == "Pebble Audio")
        #expect(reminded["payload"]?["reminder"]?["list"]?.string == "Pebble Audio")
        #expect(reminded["payload"]?["reminder"]?["id"]?.string == "pa:f1")
        let skipped = await fx.runFollowUps(["action": "skip", "id": "f2"])
        #expect(skipped["payload"]?["skipped"]?["task"]?.string == "Book the dentist")
        #expect(data.stages() == ["f1": "reminder", "f2": "skipped"])
        // It is a reminder now, in the reminders tool.
        let reminders = await fx.run(["action": "read", "list": "Pebble Audio"])
        #expect(reminders["payload"]?["reminders"]?.array?.compactMap { $0["title"]?.string }.sorted() == [
            "Already a reminder", "Send Sam the deck",
        ])
        // Nothing waits now; deciding one twice is said plainly.
        #expect((await fx.runFollowUps(["action": "read"]))["payload"]?["follow_ups"]?.array?.isEmpty == true)
        #expect((await fx.runFollowUps(["action": "skip", "id": "f1"]))["ok"]?.bool == false)
    }

    @Test func aFollowUpCantBeAddedOnlyAReminderCan() async {
        let data = FakeMuseData(home: .app)
        let fx = RemindersFixture(access: .allowed, data: data, followUps: .allowed)
        let result = await fx.runFollowUps(["action": "add", "text": "Book flights"])
        #expect(result == MuseTools.followUpAddRefused)
        #expect(result["error"]?.string?.contains("reminders tool") == true)
        #expect(data.open().isEmpty)
    }

    @Test func inAppleRemindersARemindedFollowUpSaysWhichList() async {
        let data = FakeMuseData(home: .apple, appleList: "Groceries")
        data.seedSuggestion("f1", "Buy a spatula")
        let fx = RemindersFixture(access: .allowed, data: data, followUps: .allowed)
        let reminded = await fx.runFollowUps(["action": "remind", "id": "f1"])
        #expect(reminded["payload"]?["reminder"]?["kept_in"]?.string == "Apple Reminders")
        #expect(reminded["payload"]?["reminder"]?["list"]?.string == "Groceries")
    }

    @Test func decidingFollowUpsIsAskedOncePerQuestion() async {
        let data = FakeMuseData(home: .app)
        for index in 1...3 { data.seedSuggestion("f\(index)", "Task \(index)") }
        let fx = RemindersFixture(access: .allowed, data: data, followUps: .ask)
        fx.watch.answer(value: 0)
        _ = await fx.runFollowUps(["action": "remind", "id": "f1"])
        _ = await fx.runFollowUps(["action": "skip", "id": "f2"])
        _ = await fx.runFollowUps(["action": "read"])
        #expect(fx.watch.questions() == [MuseTools.changeQuestion(.followUps)])
        #expect(MuseTools.changeQuestion(.followUps).utf8.count <= ProtocolConstants.watchActionQuestionMaxBytes)
        // Reading alone keeps its own question.
        await fx.tools.questionBegan()
        _ = await fx.runFollowUps(["action": "read"])
        #expect(fx.watch.questions().last == "Let Muse read your follow-ups? What it reads goes to Meta.")
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
    let eventKit: FakeReminderStore
    let watch = FakeWatchSide()
    let clock: RemindersClock
    let tools: MuseTools

    init(
        access: MuseSourceAccess, data: FakeMuseData? = nil, authorized: Bool = true, refused: Bool = false,
        followUps: MuseSourceAccess = .ask
    ) {
        preferences.update {
            $0.dataAccess[.reminders] = access
            $0.dataAccess[.followUps] = followUps
        }
        let clock = RemindersClock()
        self.clock = clock
        eventKit = FakeReminderStore(lists: MuseRemindersTests.lists, authorized: authorized, refused: refused)
        tools = MuseTools(
            preferences: preferences, data: data, eventKit: eventKit, clock: { clock.now() }, holdLimit: .seconds(5))
    }

    func run(_ params: MuseJSON) async -> MuseJSON {
        await tools.run(MuseTools.remindersCommand, params, watch: watch)
    }

    func runFollowUps(_ params: MuseJSON) async -> MuseJSON {
        await tools.run(MuseTools.followUpsCommand, params, watch: watch)
    }
}

/// The app's side: its own reminders and the follow-ups waiting for review.
private final class FakeMuseData: MuseDataProvider, @unchecked Sendable {
    private struct Item {
        var id: String
        var text: String
        var stage: String
        var done = false
        var due: Date?
        var filedAway = false
    }

    private let lock = NSLock()
    private let home: ReminderHome
    private let appleList: String
    private var items: [Item] = []
    private var next = 1

    init(home: ReminderHome, appleList: String = "Pebble Audio") {
        self.home = home
        self.appleList = appleList
    }

    @discardableResult
    func seedReminder(_ text: String) -> String {
        lock.withLock {
            let id = "r\(next)"
            next += 1
            items.append(Item(id: id, text: text, stage: "reminder"))
            return id
        }
    }

    func seedSuggestion(_ id: String, _ text: String) {
        lock.withLock { items.append(Item(id: id, text: text, stage: "suggested")) }
    }

    func open() -> [MuseAppReminder] {
        lock.withLock { items.filter { $0.stage == "reminder" && !$0.filedAway && !$0.done }.map(Self.reminder) }
    }

    func filedAway() -> [String] { lock.withLock { items.filter(\.filedAway).map(\.text) } }
    func stages() -> [String: String] {
        lock.withLock { Dictionary(uniqueKeysWithValues: items.filter { $0.id.hasPrefix("f") }.map { ($0.id, $0.stage) }) }
    }

    private static func reminder(_ item: Item) -> MuseAppReminder {
        MuseAppReminder(id: item.id, title: item.text, due: item.due, done: item.done)
    }

    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText] { [] }
    func answerFromRecordings(_ question: String) async -> String? { nil }
    func recap(day: Date, week: Bool) async -> String? { nil }
    func pauseRecording(minutes: Int) async -> Bool { false }
    func resumeRecording() async -> Bool { false }
    func markMoment(_ label: String?) async -> Bool { false }

    func reminderHome() async -> ReminderHome { home }

    func appReminders(completedSince: Date?) async -> [MuseAppReminder] {
        lock.withLock {
            items.filter { $0.stage == "reminder" && !$0.filedAway && (!$0.done || completedSince != nil) }.map(Self.reminder)
        }
    }

    func appReminder(id: String) async -> MuseAppReminder? {
        lock.withLock { items.first { $0.id == id && $0.stage == "reminder" && !$0.filedAway }.map(Self.reminder) }
    }

    func addAppReminder(title: String, due: Date?) async -> MuseAppReminder? {
        lock.withLock {
            let id = "r\(next)"
            next += 1
            let item = Item(id: id, text: title, stage: "reminder", due: due.map { Calendar.current.startOfDay(for: $0) })
            items.append(item)
            return Self.reminder(item)
        }
    }

    func updateAppReminder(id: String, _ change: MuseEventKitSource.ReminderChange) async -> MuseAppReminder? {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            if let title = change.title { items[index].text = title }
            if let done = change.completed { items[index].done = done }
            switch change.due {
            case .set(let date, _)?: items[index].due = Calendar.current.startOfDay(for: date)
            case .clear?: items[index].due = nil
            case nil: break
            }
            return Self.reminder(items[index])
        }
    }

    func fileAwayAppReminder(id: String) async -> MuseAppReminder? {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id && !$0.filedAway }) else { return nil }
            items[index].filedAway = true
            return Self.reminder(items[index])
        }
    }

    func followUpsToReview(limit: Int) async -> [MuseFollowUp] {
        lock.withLock {
            items.filter { $0.stage == "suggested" }.prefix(limit).map {
                MuseFollowUp(
                    id: $0.id, text: $0.text, due: nil, saidAt: Date(timeIntervalSince1970: 1_800_000_000),
                    conversation: "Planning", quote: "I'll \($0.text.prefix(1).lowercased())\($0.text.dropFirst())",
                    why: "Sam is waiting for it.")
            }
        }
    }

    func decideFollowUp(id: String, remind: Bool) async -> MuseFollowUpDecision? {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id && $0.stage == "suggested" }) else { return nil }
            items[index].stage = remind ? "reminder" : "skipped"
            return MuseFollowUpDecision(
                id: id, title: items[index].text, keptInApple: home == .apple,
                list: home == .apple ? appleList : "Pebble Audio", reminderID: home == .app && remind ? "pa:\(id)" : nil)
        }
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
    private var told: [String] = []
    private var choice = 2

    func answer(value: Int) { lock.withLock { choice = value } }
    func questions() -> [String] { lock.withLock { asked } }
    func notices() -> [String] { lock.withLock { told } }

    func runWatchAction(_ request: WatchActionRequest, wait: Duration) async -> WatchActionResult? {
        let value: Int = lock.withLock {
            if case .choose(let question, _, _) = request { asked.append(question) }
            if case .notice(let text) = request { told.append(text) }
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

    private let authorized: Bool
    private let refused: Bool

    init(lists: [MuseEventKitSource.ReminderList], authorized: Bool = true, refused: Bool = false) {
        self.lists = lists
        self.authorized = authorized
        self.refused = refused
    }

    var calendarAuthorized: Bool { true }
    var calendarRefused: Bool { false }
    var remindersAuthorized: Bool { authorized }
    var remindersRefused: Bool { refused }

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

    func reminderLists() -> [MuseEventKitSource.ReminderList] { authorized ? lists : [] }

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
