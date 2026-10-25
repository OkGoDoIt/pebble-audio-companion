import AppDB
import CompanionRuntime
import Foundation
import Testing

// The follow-ups review and the day's summary (`docs/reminders.md`). What matters is the person's
// answers: every card's answer lands on the right row, the summary is the whole of today's
// decisions (and only today's, by the app's 5 AM day), a tap there flips one, and the entry rows'
// numbers agree with what the review will show. Plus the two ways in that are not a tap: the
// evening notification and a `companion://review` link.

@Suite("reminders review", .serialized)
@MainActor
struct RemindersReviewTests {

    /// 3:12 PM on the day the mockup is set, in the phone's zone.
    private let now: Date = {
        var parts = DateComponents(year: 2026, month: 10, day: 22, hour: 15, minute: 12)
        parts.timeZone = .current
        return Calendar.current.date(from: parts)!
    }()

    private func ms(hour: Int, minute: Int, dayOffset: Int = 0) -> Int64 {
        let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func item(
        _ id: String, said: Int64, stage: FollowUpStage, decided: Int64? = nil,
        due: Int64? = nil, origin: FollowUpOrigin = .ai
    ) -> FollowUpItem {
        FollowUpItem(
            id: id, text: "Follow up \(id)", done: false, dueAtMs: due, priority: .normal,
            origin: origin, createdAtMs: said, stage: stage, decidedAtMs: decided, saidAtMs: said)
    }

    /// The v4 day: three asked for (already reminders), three waiting, one from yesterday that
    /// must stay out of today's summary, and one an assistant added.
    private func source() -> FakeFollowUpsSource {
        let decidedThisMorning = ms(hour: 9, minute: 0)
        let fake = FakeFollowUpsSource(rows: [
            item("asked-1", said: ms(hour: 8, minute: 5), stage: .reminder,
                decided: decidedThisMorning),
            item("asked-2", said: ms(hour: 14, minute: 41), stage: .reminder,
                decided: decidedThisMorning),
            item("austin", said: ms(hour: 10, minute: 5), stage: .suggested),
            item("clinic", said: ms(hour: 11, minute: 20), stage: .suggested,
                due: ms(hour: 0, minute: 0)),
            item("shirt", said: ms(hour: 13, minute: 30), stage: .suggested),
            // Decided at 4 AM today: still yesterday's app day.
            item("yesterday", said: ms(hour: 22, minute: 0, dayOffset: -1), stage: .reminder,
                decided: ms(hour: 4, minute: 0)),
            item("muse", said: ms(hour: 12, minute: 0), stage: .reminder,
                decided: decidedThisMorning, origin: .assistant),
        ])
        fake.nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return fake
    }

    // MARK: The cards

    @Test func everyAnswerLandsAndTheSummaryIsTheWholeDay() async {
        let fake = source()
        var datedReminders = 0
        let model = ReminderReviewModel(source: fake, now: { now }) { datedReminders += 1 }

        await model.start(.review)
        #expect(model.phase == .cards)
        #expect(model.queue.map(\.id) == ["austin", "clinic", "shirt"])
        #expect(model.counter == "1 of 3")
        #expect(model.behind.map(\.id) == ["clinic", "shirt"])

        await model.decide(.skip)?.value
        #expect(model.counter == "2 of 3")
        await model.decide(.remind)?.value
        await model.decide(.remind)?.value

        #expect(fake.rows.first { $0.id == "austin" }?.stage == .skipped)
        #expect(fake.rows.first { $0.id == "clinic" }?.stage == .reminder)
        #expect(fake.rows.first { $0.id == "shirt" }?.stage == .reminder)
        // Alerts are asked about once, for the first dated reminder.
        #expect(datedReminders == 1)

        // Today's decisions, automatic ones included, in the order they were said; not
        // yesterday's, and not what an assistant added.
        #expect(model.phase == .summary)
        #expect(model.summary.map(\.id) == ["asked-1", "austin", "clinic", "shirt", "asked-2"])
        #expect(model.addedCount == 4)
    }

    @Test func aTapInTheSummaryIsTheUndo() async throws {
        let fake = source()
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.summary)
        #expect(model.addedCount == 2)

        let asked = try #require(model.summary.first { $0.id == "asked-1" })
        await model.flip(asked)
        #expect(model.addedCount == 1)
        #expect(fake.rows.first { $0.id == "asked-1" }?.stage == .skipped)

        await model.flip(model.summary.first { $0.id == "asked-1" }!)
        #expect(model.addedCount == 2)
        #expect(fake.rows.first { $0.id == "asked-1" }?.stage == .reminder)
    }

    /// Nothing waiting: the review goes straight to the summary, never an empty card stack.
    @Test func withNothingToReviewItOpensOnTheSummary() async {
        let fake = source()
        fake.rows.removeAll { $0.stage == .suggested }
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        #expect(model.phase == .summary)
        #expect(model.counter == nil)
    }

    @Test func editingKeepsTheCardPendingAndConfirmationUsesTheSavedDate() async throws {
        let fake = source()
        var alerts = 0
        let model = ReminderReviewModel(source: fake, now: { now }) { alerts += 1 }
        await model.start(.review)
        let original = try #require(model.current)
        try await model.saveDetails(id: original.id, text: "  Call Austin  ", dueAt: now, priority: .high)
        #expect(model.counter == "1 of 3")
        #expect(model.current?.text == "  Call Austin  ")
        #expect(model.current?.priority == .high)
        #expect(model.current?.stage == .suggested)
        #expect(fake.rows.first { $0.id == original.id }?.stage == .suggested)
        #expect(model.current?.quote == original.quote)
        #expect(alerts == 0)
        await model.decide(.remind)?.value
        #expect(alerts == 1)
        #expect(fake.rows.first { $0.id == original.id }?.text == "Call Austin")
    }

    @Test func clearingADateThenSkippingPreservesEditsWithoutRequestingAlerts() async throws {
        let fake = source()
        var alerts = 0
        let model = ReminderReviewModel(source: fake, now: { now }) { alerts += 1 }
        await model.start(.review)
        await model.decide(.skip)?.value
        try await model.saveDetails(id: "clinic", text: "Call clinic", dueAt: nil, priority: .low)
        #expect(model.current?.dueAtMs == nil)
        await model.decide(.skip)?.value
        let saved = try #require(fake.rows.first { $0.id == "clinic" })
        #expect(saved.stage == .skipped)
        #expect(saved.dueAtMs == nil)
        #expect(saved.priority == .low)
        #expect(alerts == 0)
    }

    @Test func failedSaveKeepsTheDraftAndCanBeRetried() async throws {
        let fake = source()
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        let original = model.current
        fake.failReviewSave = true
        await #expect(throws: (any Error).self) {
            try await model.saveDetails(id: "austin", text: "Call Austin", dueAt: nil, priority: .high)
        }
        #expect(model.current?.id == original?.id)
        #expect(model.current?.text == "Call Austin")
        #expect(model.saveError != nil)
        #expect(!model.canDecide)
        #expect(fake.rows.first { $0.id == "austin" } == original)
        #expect(!model.savingDetails)
        fake.failReviewSave = false
        try await model.saveDetails(id: "austin", text: "Call Austin", dueAt: nil, priority: .high)
        #expect(model.current?.text == "Call Austin")
        #expect(model.position == 0)
    }

    @Test func saveBlocksDecisionsAndRejectsBlankOrWrongCardEdits() async throws {
        let fake = source()
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        fake.beforeReviewSave = {
            #expect(model.savingDetails)
            #expect(model.decide(.remind) == nil)
            #expect(model.position == 0)
        }
        try await model.saveDetails(id: "austin", text: "Call Austin", dueAt: nil, priority: .normal)
        await #expect(throws: (any Error).self) {
            try await model.saveDetails(id: "clinic", text: "Wrong card", dueAt: nil, priority: .high)
        }
        await #expect(throws: (any Error).self) {
            try await model.saveDetails(id: "austin", text: "  ", dueAt: nil, priority: .high)
        }
        #expect(!model.canDecide)
        #expect(fake.rows.first { $0.id == "austin" }?.text == "Call Austin")
    }

    @Test func rapidTypingSavesOnlyTheLatestDraft() async throws {
        let fake = source()
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        let first = model.editDetails(id: "austin", text: "Call", dueAt: nil, priority: .normal)
        let last = model.editDetails(id: "austin", text: "Call Austin", dueAt: now, priority: .high)
        try await first?.value
        try await last?.value
        #expect(fake.reviewSavedTexts == ["Call Austin"])
        #expect(model.current?.dueDate == now)
        #expect(model.current?.priority == .high)
        #expect(model.canDecide)
    }

    @Test func anOlderFailureCannotReplaceNewTypingOrUnlockAnUnfinishedSave() async throws {
        let fake = source()
        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        let (started, signal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        fake.beforeReviewSave = {
            signal.yield(())
            await withCheckedContinuation { release = $0 }
            throw CocoaError(.fileWriteUnknown)
        }
        let first = model.editDetails(id: "austin", text: "Older", dueAt: nil, priority: .low)
        for await _ in started { break }
        let last = model.editDetails(id: "austin", text: "Latest", dueAt: now, priority: .high)
        fake.beforeReviewSave = nil
        release?.resume()
        _ = try? await first?.value
        #expect(model.current?.text == "Latest")
        #expect(model.saveError == nil)
        #expect(!model.canDecide)
        try await last?.value
        #expect(fake.reviewSavedTexts == ["Latest"])
        #expect(model.canDecide)
    }

    // MARK: The entry rows

    @Test func theEntryRowsCountWhatTheReviewWillShow() async {
        let fake = source()
        let digest = ReminderDigestModel(source: fake, now: { now })
        await digest.reload()
        #expect(digest.toReview == 3)
        #expect(digest.firstToReview == "Follow up austin")
        #expect(digest.addedToday == 2)

        let model = ReminderReviewModel(source: fake, now: { now })
        await model.start(.review)
        for _ in 0..<3 { await model.decide(.remind)?.value }
        await digest.reload()
        #expect(digest.toReview == 0)
        #expect(digest.addedToday == model.addedCount)
    }

    // MARK: Ways in

    @Test func theEveningNotificationOpensTheReviewOrTheSummary() {
        #expect(
            LossNotificationRouter.route(for: [reminderNotificationRouteKey: "review"])
                == .review(summary: false))
        #expect(
            LossNotificationRouter.route(for: [reminderNotificationRouteKey: "summary"])
                == .review(summary: true))
        #expect(
            LossNotificationRouter.route(for: [reminderNotificationRouteKey: "reminders"])
                == .followUps(scope: nil))
    }

    @Test func aReviewLinkOpensTheSheetOverTheRemindersTab() throws {
        let url = try #require(URL(string: "companion://review?show=summary"))
        let route = try #require(Route.parse(url))
        #expect(route == .review(summary: true))
        #expect(Route.parse(Route.review(summary: false).url) == .review(summary: false))

        let router = AppRouter()
        router.followUpsPath = [.followUp(id: "x")]
        router.navigate(to: route)
        #expect(router.selectedTab == .followUps)
        #expect(router.followUpsPath.isEmpty)
        #expect(router.reminderSheet == .summary)
    }
}
