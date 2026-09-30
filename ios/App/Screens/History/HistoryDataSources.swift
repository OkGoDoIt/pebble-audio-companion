import AppDB
import Foundation

// The History tab's data seam (plan 7.10 "The data source"). The screen talks only to this
// protocol; `HistoryDataSources.current` holds the implementation.
//
// Battery rules built into the shape (CLAUDE.md, plan 7.13): only the visible page subscribes
// (`day`/`week`/`month` streams, cancelled by the caller when the page goes away), neighbours
// are built once by `prefetch`, and `setVisible(false)` cancels every observation — a screen's
// data source does nothing while its screen is off screen.

/// Whether the day's cards come from chapters yet (plan 5.8).
enum HistoryTopicsState: Equatable, Sendable {
    /// Chapters cover the day.
    case ready
    /// Drawn from conversations while chapters are being made: "Topics are being prepared".
    case preparing
    /// AI is off: the conversation cards are permanent and nothing says otherwise.
    case off
}

/// Everything one day page draws.
struct HistoryDayPage: Equatable, Sendable {
    var day: HistoryDay
    /// The day's brief ("The day in brief" / "Today so far"). Nil: "No summary yet".
    var brief: HistoryBrief?
    var followUpTotal: Int
    var followUpOpen: Int
    var topics: HistoryTopicsState
    /// Today while recording: the last line of the live transcript, from the live snapshot
    /// (never a second walk of the transcript). Nil otherwise.
    var liveLine: String?

    init(
        day: HistoryDay, brief: HistoryBrief?, followUpTotal: Int, followUpOpen: Int,
        topics: HistoryTopicsState, liveLine: String? = nil
    ) {
        self.day = day
        self.brief = brief
        self.followUpTotal = followUpTotal
        self.followUpOpen = followUpOpen
        self.topics = topics
        self.liveLine = liveLine
    }

    /// Recorded, but nothing of it transcribed yet: the brief card says "Waiting to transcribe".
    var isWaitingToTranscribe: Bool {
        guard day.hasRecordings else { return false }
        var sawPending = false
        for item in day.items {
            switch item {
            case .chapter, .live: return false
            case .gap(let gap) where gap.kind == .notTranscribedYet: sawPending = true
            case .gap, .zoneChange: continue
            }
        }
        return sawPending
    }
}

@MainActor
protocol HistoryDataSource: AnyObject {
    /// The first and last day, and which days hold recordings.
    func bounds() async -> HistoryBounds
    /// The visible day, published again only when it changes.
    func day(_ dateKey: String) -> AsyncStream<HistoryDayPage>
    /// The visible week (`firstDateKey` … `lastDateKey`, whole).
    func week(firstDateKey: String, lastDateKey: String) -> AsyncStream<HistoryPeriod<HistoryWeekRow>>
    /// The visible month.
    func month(containing dateKey: String) -> AsyncStream<HistoryPeriod<HistoryMonthRow>>
    /// Build these days once into the cache, without observing them (the pager's neighbours).
    func prefetch(days: [String])
    /// False cancels every observation; true resubscribes and fetches once.
    func setVisible(_ visible: Bool)
}

// MARK: - The holder

@MainActor
struct HistoryDataSources {
    var history: any HistoryDataSource

    /// The demo world until `LiveHistory` lands (plan step 9). History is reachable only
    /// through the DEBUG `-history` launch argument until then.
    static var current = HistoryDataSources(
        history: MockHistory(isEmptyArchive: HistoryLaunch.isEmptyArchive))
}
