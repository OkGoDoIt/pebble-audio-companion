import AppDB
import Foundation
import Testing

// The one line under a follow-up's text. It is the only place the list says WHEN, so every
// wrong answer here is a row that either shouts when it should not or stays quiet when the
// thing is already late.

@Suite("follow-up formatting")
@MainActor
struct FollowUpFormattingTests {
    private let calendar = Calendar.current
    /// A fixed afternoon, so "1 hr ago" cannot pass by being run at the right moment.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 40, second: 0,
        of: Date(timeIntervalSince1970: 1_788_000_000))!

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func at(hour: Int, minute: Int, daysFromNow: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: daysFromNow, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func item(
        done: Bool = false,
        due: Date? = nil,
        completed: Date? = nil,
        archived: Date? = nil,
        snoozed: Date? = nil,
        priority: FollowUpPriority = .normal,
        conversationTitle: String? = nil
    ) -> FollowUpItem {
        FollowUpItem(
            id: "fu", text: "Take Theo at 7:00", done: done, dueAtMs: due.map(ms),
            priority: priority, quote: nil, why: nil, origin: .ai,
            createdAtMs: ms(at(hour: 9, minute: 0)), completedAtMs: completed.map(ms),
            archivedAtMs: archived.map(ms), snoozedUntilMs: snoozed.map(ms),
            sourceConversationId: conversationTitle == nil ? nil : "conv-1",
            sourceConversationTitle: conversationTitle)
    }

    // MARK: Due dates

    @Test func overdueIsUrgentAndCountsTheDays() {
        let meta = FollowUpFormatting.metaLine(
            item(due: at(hour: 0, minute: 0, daysFromNow: -1)), now: now)
        #expect(meta?.text == "1 day overdue")
        #expect(meta?.isUrgent == true)

        let older = FollowUpFormatting.metaLine(
            item(due: at(hour: 0, minute: 0, daysFromNow: -4)), now: now)
        #expect(older?.text == "4 days overdue")
    }

    /// The whole of today counts as due today — an item due "today" is not overdue at 12:41.
    @Test func dueTodayIsUrgentAllDay() {
        let morning = FollowUpFormatting.metaLine(item(due: at(hour: 0, minute: 0)), now: now)
        #expect(morning?.text == "Due today")
        #expect(morning?.isUrgent == true)
    }

    @Test func aFutureDateIsNamedButNotUrgent() {
        let tomorrow = FollowUpFormatting.metaLine(
            item(due: at(hour: 0, minute: 0, daysFromNow: 1)), now: now)
        #expect(tomorrow?.text == "Due tomorrow")
        #expect(tomorrow?.isUrgent == false)

        // Inside the week it is a weekday name; past that, a date. Nobody reads "2026-09-12"
        // as a day of their life.
        let weekday = FollowUpFormatting.day(at(hour: 0, minute: 0, daysFromNow: 3), now: now)
        #expect(weekday.count > 3 && !weekday.contains("-"))
        let far = FollowUpFormatting.day(at(hour: 0, minute: 0, daysFromNow: 40), now: now)
        #expect(far.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    // MARK: Completion, archiving, snoozing

    @Test func aCompletedItemSaysWhenItWasDone() {
        #expect(
            FollowUpFormatting.metaLine(
                item(done: true, completed: at(hour: 11, minute: 15)), now: now)?.text
                == "Done 1 hr ago")
        #expect(
            FollowUpFormatting.metaLine(
                item(done: true, completed: secondsAgo(30)), now: now)?
                .text == "Done just now")
        #expect(
            FollowUpFormatting.metaLine(
                item(done: true, completed: at(hour: 12, minute: 20)), now: now)?.text
                == "Done 20 min ago")
    }

    /// Done wins over a due date: a finished item is not overdue, however late it was.
    @Test func aCompletedItemIsNeverUrgent() {
        let meta = FollowUpFormatting.metaLine(
            item(
                done: true, due: at(hour: 0, minute: 0, daysFromNow: -3),
                completed: at(hour: 11, minute: 0)),
            now: now)
        #expect(meta?.isUrgent == false)
        #expect(meta?.text.hasPrefix("Done") == true)
    }

    @Test func aSnoozedItemSaysWhenItComesBack() {
        let meta = FollowUpFormatting.metaLine(
            item(due: at(hour: 0, minute: 0, daysFromNow: -2),
                snoozed: at(hour: 9, minute: 0, daysFromNow: 1)),
            now: now)
        #expect(meta?.text == "Put off until tomorrow")
        // Deliberately not urgent: the person has already said "not now".
        #expect(meta?.isUrgent == false)
    }

    @Test func anArchivedItemSaysWhenItWasFiledAway() {
        let meta = FollowUpFormatting.metaLine(
            item(archived: at(hour: 9, minute: 0, daysFromNow: -6)), now: now)
        #expect(meta?.text.hasPrefix("Filed away") == true)
    }

    // MARK: Falling back, and staying quiet

    @Test func withNoDateItNamesTheRecordingInstead() {
        #expect(
            FollowUpFormatting.metaLine(item(conversationTitle: "Coffee with Dana"), now: now)?
                .text == "Coffee with Dana")
    }

    /// Nil, not a generic line. A second line that reads the same on every row costs a line of
    /// screen and returns nothing.
    @Test func withNothingToSayThereIsNoSecondLine() {
        #expect(FollowUpFormatting.metaLine(item(), now: now) == nil)
    }
}

extension FollowUpFormattingTests {
    fileprivate func secondsAgo(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }
}

/// The mock world is what every preview and the demo build render, so a wrong sample is a
/// wrong review: the layouts get signed off against data that cannot occur.
@Suite("mock follow-up sample")
@MainActor
struct MockFollowUpSampleTests {
    @Test func theSampleCoversEveryStateTheListCanShow() async throws {
        let source = MockFollowUps(world: MockWorld.shared)
        let open = try await source.items(scope: .open)
        let completed = try await source.items(scope: .completed)
        let archived = try await source.items(scope: .archived)

        #expect(open.contains { $0.dueDate.map { $0 < Date() } == true }, "an overdue one")
        #expect(open.contains { $0.dueAtMs == nil }, "an undated one")
        #expect(open.contains { $0.origin == .user }, "one the person wrote")
        #expect(open.contains { $0.priority == .high }, "one that matters more")
        #expect(!completed.isEmpty)
        #expect(!archived.isEmpty)
    }

    /// The sample's completion time has to be far enough back to render as a real elapsed
    /// time; a fixture completed "now" makes the label untestable by eye.
    @Test func theCompletedSampleReadsAsAnElapsedTime() async throws {
        let source = MockFollowUps(world: MockWorld.shared)
        let completed = try await source.items(scope: .completed)
        let item = try #require(completed.first { $0.id == "fu-charge" })
        let stamp = try #require(item.completedAtMs)
        let age = Date().timeIntervalSince1970 - Double(stamp) / 1000
        #expect(age > 120, "completed at \(Date(timeIntervalSince1970: Double(stamp) / 1000))")
    }
}
