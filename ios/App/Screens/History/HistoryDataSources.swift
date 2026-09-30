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
    var day: HistoryDay {
        didSet { entries = Self.entries(for: day) }
    }
    /// The day's brief ("The day in brief" / "Today so far"). Nil: "No summary yet".
    var brief: HistoryBrief?
    var followUpTotal: Int
    var followUpOpen: Int
    var topics: HistoryTopicsState
    /// Today while recording: the last line of the live transcript, from the live snapshot
    /// (never a second walk of the transcript). Nil otherwise.
    var liveLine: String?
    /// What the timeline draws: the day's items with every run of gaps as one stretch
    /// (`HistoryStretches.combine`). Computed here, once, when the page is made — never in a view
    /// body. DEBUG `-historyNoStretches` draws every gap on its own, as before.
    var entries: [HistoryDayEntry]

    init(
        day: HistoryDay, brief: HistoryBrief?, followUpTotal: Int, followUpOpen: Int,
        topics: HistoryTopicsState, liveLine: String? = nil
    ) {
        self.entries = Self.entries(for: day)
        self.day = day
        self.brief = brief
        self.followUpTotal = followUpTotal
        self.followUpOpen = followUpOpen
        self.topics = topics
        self.liveLine = liveLine
    }

    static func entries(for day: HistoryDay) -> [HistoryDayEntry] {
        stretchesDisabled ? day.items.map { .item($0) } : HistoryStretches.combine(day)
    }

    static var stretchesDisabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-historyNoStretches")
        #else
        return false
        #endif
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

/// One conversation carrying a topic, for the topic's results screen (plan 5.7). Results come
/// newest first; the screen groups them by day.
struct HistoryTagResult: Equatable, Sendable, Identifiable {
    var dateKey: String
    var startMs: Int64
    var endMs: Int64
    var zoneID: String
    var title: String
    var summary: String?
    /// The conversation it is, which a tap opens.
    var conversationId: String?
    var id: String { "\(dateKey)-\(startMs)" }

    init(
        dateKey: String, startMs: Int64, endMs: Int64, zoneID: String = TimeZone.current.identifier,
        title: String, summary: String? = nil, conversationId: String? = nil
    ) {
        self.dateKey = dateKey
        self.startMs = startMs
        self.endMs = endMs
        self.zoneID = zoneID
        self.title = title
        self.summary = summary
        self.conversationId = conversationId
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
    /// The chapters carrying a topic, newest first (plan 5.7).
    func tagResults(tag: String) async -> [HistoryTagResult]
}

extension HistoryDataSource {
    /// Additive: a source that does not know topics yet answers with none, and the results
    /// screen says so. The live source overrides this.
    func tagResults(tag: String) async -> [HistoryTagResult] { [] }
}

// MARK: - The holder

@MainActor
struct HistoryDataSources {
    var history: any HistoryDataSource

    /// The demo world until `LiveHistory` lands (plan step 9). History is reachable only
    /// through the DEBUG `-history` launch argument until then.
    static var current = HistoryDataSources(
        history: MockHistory(
            isEmptyArchive: HistoryLaunch.isEmptyArchive, withoutBriefs: HistoryLaunch.isWithoutBriefs))
}
