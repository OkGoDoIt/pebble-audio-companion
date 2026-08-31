import SwiftUI
import StatusUI

/// Today tab view model: observes one `TodaySnapshot` stream and forwards user actions.
@Observable
@MainActor
final class TodayViewModel {
    private let dataSource: any TodayDataSource

    private(set) var snapshot: TodaySnapshot
    /// "See all N" disclosure on the follow-ups card.
    var showAllFollowUps = false

    init(dataSource: (any TodayDataSource)? = nil) {
        let source = dataSource ?? AppDataSources.current.today
        self.dataSource = source
        self.snapshot = source.todaySnapshot()
    }

    func observe() async {
        for await value in dataSource.todayUpdates() {
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

    var visibleFollowUps: [FollowUpDisplay] {
        showAllFollowUps ? snapshot.followUps : Array(snapshot.followUps.prefix(2))
    }

    var followUpsAllDone: Bool {
        !snapshot.followUps.isEmpty && snapshot.followUps.allSatisfy(\.done)
    }

    // MARK: Actions

    func pauseTapped() { dataSource.requestPause() }

    func perform(_ action: StatusAction) { dataSource.perform(action) }

    func toggleFollowUp(_ item: FollowUpDisplay) {
        dataSource.setFollowUpDone(id: item.id, done: !item.done)
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
