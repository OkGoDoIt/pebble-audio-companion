import AppDB
import Foundation
import Observation

/// The app's day: 5 AM to 5 AM in the phone's zone, the same `LogicalDay` Today and History
/// date things by. "Added from today" and the summary both mean this day.
enum ReminderDay {
    static func bounds(containing now: Date) -> (startMs: Int64, endMs: Int64) {
        let zone = TimeZone.current.identifier
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let key = LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)
        return LogicalDay.bounds(ofDateKey: key, timeZoneID: zone)
            ?? (nowMs - 86_400_000, nowMs + 1)
    }
}

/// Which of the two review surfaces to show: the cards, or the day's summary straight away.
enum ReminderSheet: String, Identifiable {
    case review
    case summary

    var id: String { rawValue }
}

// MARK: - The entry rows' numbers

/// What the Reminders tab and Today put above the list: how many follow-ups wait for review
/// (and the first of them, as a preview), and how many reminders today added.
@MainActor
@Observable
final class ReminderDigestModel {
    private(set) var toReview = 0
    /// The oldest follow-up waiting, as the review row's second line.
    private(set) var firstToReview: String?
    private(set) var addedToday = 0
    private(set) var loaded = false

    private let injectedSource: (any FollowUpsDataSource)?
    private let now: () -> Date
    private var source: any FollowUpsDataSource {
        injectedSource ?? AskLibraryDataSources.current.followUps
    }

    init(source: (any FollowUpsDataSource)? = nil, now: @escaping () -> Date = Date.init) {
        self.injectedSource = source
        self.now = now
    }

    /// Nothing to say: no row at all.
    var isEmpty: Bool { toReview == 0 && addedToday == 0 }

    func observe() async {
        await reload()
        for await _ in source.followUpUpdates() {
            await reload()
        }
    }

    func reload() async {
        let queue = (try? await source.reviewQueue()) ?? []
        let day = ReminderDay.bounds(containing: now())
        let decided = (try? await source.decided(fromMs: day.startMs, toMs: day.endMs)) ?? []
        let added = decided.filter { $0.stage == .reminder }.count
        // Content-gated: a reload that changes nothing publishes nothing.
        if toReview != queue.count { toReview = queue.count }
        if firstToReview != queue.first?.text { firstToReview = queue.first?.text }
        if addedToday != added { addedToday = added }
        if !loaded { loaded = true }
    }
}

// MARK: - The review and its summary

/// One pass through the follow-ups waiting for review, then the day's summary
/// (`docs/reminders.md`). Swipe or tap: right is Remind me, left is Skip. The summary is the only
/// undo: every follow-up decided today, each flipped by a tap.
@MainActor
@Observable
final class ReminderReviewModel {
    enum Phase: Equatable {
        case loading
        case cards
        case summary
    }

    enum Decision {
        case remind
        case skip

        var stage: FollowUpStage { self == .remind ? .reminder : .skipped }
    }

    private(set) var phase: Phase = .loading
    /// The cards, oldest first, as they were when the review opened: a follow-up found while
    /// it is open waits for the next one rather than moving the count under the person.
    private(set) var queue: [FollowUpItem] = []
    private(set) var position = 0
    /// Everything decided today, in the order it was said.
    private(set) var summary: [FollowUpItem] = []

    private let injectedSource: (any FollowUpsDataSource)?
    private let now: () -> Date
    /// Called the first time the review makes a dated reminder: alerts need iOS's permission,
    /// and this is the first moment one is wanted.
    private let onDatedReminder: () -> Void
    private var askedForAlerts = false
    /// The last answer being written: answers are written in the order they were given.
    private var writes: Task<Void, Never>?

    private var source: any FollowUpsDataSource {
        injectedSource ?? AskLibraryDataSources.current.followUps
    }

    init(
        source: (any FollowUpsDataSource)? = nil, now: @escaping () -> Date = Date.init,
        onDatedReminder: @escaping () -> Void = {}
    ) {
        self.injectedSource = source
        self.now = now
        self.onDatedReminder = onDatedReminder
    }

    func start(_ sheet: ReminderSheet) async {
        if sheet == .review {
            queue = (try? await source.reviewQueue()) ?? []
            position = 0
            if !queue.isEmpty {
                phase = .cards
                return
            }
        }
        await showSummary()
    }

    // MARK: Cards

    var current: FollowUpItem? { queue.indices.contains(position) ? queue[position] : nil }

    /// The cards behind the current one, nearest first (at most two are drawn).
    var behind: [FollowUpItem] { Array(queue.dropFirst(position + 1).prefix(2)) }

    /// "1 of 3".
    var counter: String? {
        guard phase == .cards, current != nil else { return nil }
        return Copy.Reminders.counter(position + 1, of: queue.count)
    }

    /// The answer for the card on top. The next card comes up at once (so the caller can
    /// animate it); the write follows, after any earlier one, and after the last card the
    /// summary is read — once every answer is in it. Returns the write, for tests to await.
    @discardableResult
    func decide(_ decision: Decision) -> Task<Void, Never>? {
        guard let item = current else { return nil }
        position += 1
        let isLast = position >= queue.count
        let previous = writes
        let wantsAlerts = decision == .remind && item.dueAtMs != nil && !askedForAlerts
        if wantsAlerts { askedForAlerts = true }
        let task = Task {
            await previous?.value
            try? await source.setStage(id: item.id, stage: decision.stage)
            if wantsAlerts { onDatedReminder() }
            if isLast { await showSummary() }
        }
        writes = task
        return task
    }

    // MARK: Summary

    var addedCount: Int { summary.filter { $0.stage == .reminder }.count }

    /// A tap on a row's state: a reminder becomes skipped, a skipped one a reminder.
    func flip(_ item: FollowUpItem) async {
        guard let index = summary.firstIndex(where: { $0.id == item.id }) else { return }
        let next: FollowUpStage = summary[index].stage == .reminder ? .skipped : .reminder
        summary[index].stage = next
        try? await source.setStage(id: item.id, stage: next)
        if next == .reminder, item.dueAtMs != nil, !askedForAlerts {
            askedForAlerts = true
            onDatedReminder()
        }
    }

    private func showSummary() async {
        let day = ReminderDay.bounds(containing: now())
        summary = (try? await source.decided(fromMs: day.startMs, toMs: day.endMs)) ?? []
        phase = .summary
    }
}
