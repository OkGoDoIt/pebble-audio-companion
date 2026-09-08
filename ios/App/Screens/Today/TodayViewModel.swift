import Receiver
import SwiftUI
import StatusUI

/// Today tab view model: observes one `TodaySnapshot` stream and forwards user actions.
@Observable
@MainActor
final class TodayViewModel {
    private let dataSource: any TodayDataSource
    /// Deleting, putting off and undoing a delete go through the follow-ups source, not through
    /// `TodayDataSource`: that is the one place those writes are already got right (a delete
    /// also has to leave Spotlight, and an undo has to put the row back with its provenance
    /// rather than as a fresh hand-written item). Today observes the same table, so the card
    /// refreshes from the write either way.
    private let followUpsSource: any FollowUpsDataSource

    private(set) var snapshot: TodaySnapshot
    /// Ticks the person has just made, applied over whatever the last snapshot carried, so the
    /// checkmark fills on the tap rather than after a database write and a full recomputation
    /// of the whole screen. Cleared as soon as the store agrees.
    private var optimisticDone: [String: Bool] = [:]
    /// Rows a swipe has just removed — deleted or put off. Held until the store agrees, so the
    /// row leaves under the finger instead of sitting there until the next snapshot lands.
    private var hidden: Set<String> = []
    /// Refreshed with every snapshot, so "Due today" stops being true at midnight.
    private(set) var now = Date()

    init(
        dataSource: (any TodayDataSource)? = nil,
        followUps: (any FollowUpsDataSource)? = nil
    ) {
        let source = dataSource ?? AppDataSources.current.today
        self.dataSource = source
        self.followUpsSource = followUps ?? AskLibraryDataSources.current.followUps
        self.snapshot = source.todaySnapshot()
    }

    func observe() async {
        for await value in dataSource.todayUpdates() {
            for item in value.followUps where optimisticDone[item.id] == item.done {
                optimisticDone[item.id] = nil
            }
            // An item that has left the open list entirely has landed — stop guessing about it.
            let present = Set(value.followUps.map(\.id))
            optimisticDone = optimisticDone.filter { present.contains($0.key) }
            hidden = hidden.filter { present.contains($0) }
            now = Date()
            snapshot = value
        }
    }

    // MARK: Derived

    var status: StatusModel { snapshot.status }

    /// Plan 6.2: the live minute renders only while the recording family is showing.
    var showsLiveMinute: Bool { status.family == .recording }

    /// Today has nothing on it yet. Says nothing about WHY — see the two properties below.
    var isEmpty: Bool {
        snapshot.conversations.isEmpty && snapshot.recap == nil && snapshot.coverage == nil
    }

    /// First-run empty state (6.7): nothing recorded yet — the status card carries the action.
    /// Only once recovery has finished: while it is running, an empty Today means "not read
    /// yet", and telling a migrated user they have nothing is the one thing it must not do.
    var isFirstRun: Bool { isEmpty && !snapshot.recovering }

    /// Startup recovery / the one-time import is still running behind an empty Today.
    var isRecovering: Bool { isEmpty && snapshot.recovering }

    /// The one calm line under an empty Today, or nil when there is content to show.
    var emptyLine: String? {
        guard isEmpty else { return nil }
        return snapshot.recovering ? Copy.Empty.todayRecovering : Copy.Empty.todayFirstRun
    }

    /// The three the card shows, with any tick the person has just made already applied.
    /// A ticked one stays on screen — struck through — until the next snapshot removes it, so
    /// the row does not vanish out from under the finger that tapped it.
    var visibleFollowUps: [FollowUpItem] {
        snapshot.followUps.compactMap { item in
            guard !hidden.contains(item.id) else { return nil }
            guard let optimistic = optimisticDone[item.id] else { return item }
            var copy = item
            copy.done = optimistic
            return copy
        }
    }

    /// What "See all N" counts: everything open, including what the card had no room for —
    /// less anything a swipe has just taken off it, so the count cannot outlive the row.
    var openFollowUpCount: Int { max(0, snapshot.openFollowUpCount - hidden.count) }

    var tomorrow: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    var nextWeek: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: Actions

    /// Today's half of the shared capture control.
    ///
    /// The transport is `TodayDataSource` rather than `CaptureControlling` on purpose: both are
    /// the same `LiveTodayDataSource` object in a real build, reaching the same
    /// `CompanionRuntime` calls, but going through the data source is what keeps
    /// `PreviewTodayData` animating the approved artboards — a Today preview whose switch did
    /// nothing would be a worse artboard than the text link it replaced.
    ///
    /// The mapping is the whole of Today's capture vocabulary, and it is deliberately the same
    /// three intents Settings sends:
    ///   `.active` → Start (arms the one on-watch enable prompt and dials the link, so a resume
    ///               from a dropped link actually reconnects)
    ///   `.off`    → Stop  (the switch's off position — the receiver stops)
    ///   `.paused` → the opt-in timed pause, and nothing else
    func captureController(settings: AppSettings) -> CaptureController {
        CaptureController(settings: settings) { [weak self] intent in
            guard let self else { return }
            switch intent {
            case .active: self.dataSource.perform(.start)
            case .off: self.dataSource.perform(.stop)
            case .paused: self.dataSource.requestPause()
            }
        }
    }

    func perform(_ action: StatusAction) { dataSource.perform(action) }

    func toggleFollowUp(_ item: FollowUpItem) {
        let next = !(optimisticDone[item.id] ?? item.done)
        optimisticDone[item.id] = next
        dataSource.setFollowUpDone(id: item.id, done: next)
    }

    /// Deletes for real, immediately — the undo path re-adds it. Same trade the Follow-ups list
    /// makes: a row held back for five seconds looks deleted while still feeding the widget's
    /// count, which is a worse lie than a re-created row.
    func deleteFollowUp(_ item: FollowUpItem) {
        hidden.insert(item.id)
        Task { try? await followUpsSource.delete(id: item.id) }
    }

    /// Puts the row back as it was — same id, same quote, same recording.
    func undoDeleteFollowUp(_ item: FollowUpItem) {
        hidden.remove(item.id)
        Task { try? await followUpsSource.restore(item) }
    }

    /// A deferred follow-up is not on today's list by definition, so the row leaves the card.
    /// `nil` undoes it.
    func snoozeFollowUp(_ item: FollowUpItem, until date: Date?) {
        if date == nil { hidden.remove(item.id) } else { hidden.insert(item.id) }
        Task {
            try? await followUpsSource.snooze(
                id: item.id, untilMs: date.map { Int64($0.timeIntervalSince1970 * 1000) })
        }
    }
}

// MARK: - Token mapping for kit status types

extension StatusUI.StatusDot {
    /// Status-dot semantic → design token (extraction §2.18 + §1.1 dot roles).
    var tokenColor: Color {
        switch self {
        case .active: return Tokens.good
        case .attention: return Tokens.attention
        case .problem: return Tokens.destructive
        case .consent: return Tokens.tint
        case .neutral, .info: return Tokens.neutralDot
        }
    }
}

extension StatusAction {
    /// Card-button rendering: filled resolves, bordered helps (artboard rule).
    var cardStyle: StatusCard.Action.Style { isFilled ? .filled : .bordered }
}
