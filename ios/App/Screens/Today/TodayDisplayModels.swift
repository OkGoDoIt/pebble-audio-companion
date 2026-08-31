import Foundation
import StatusUI

// Display models for the Today screen (Main artboard, extraction §2.4) plus the data-source
// seam the runtime wires later. The view layer renders ONLY these models; mapping from
// kit types (SegmentStore/AppDB/LiveAudio) into them is the data source's job.

// MARK: - Coverage

/// One strip span plus the Q11 explain-popover line for it (nil = no popover, e.g. `off`).
struct CoverageSpanDisplay: Equatable, Identifiable {
    var id: Double { span.range.lowerBound }
    let span: CoverageSpan
    let popoverText: String?
}

/// The DAY COVERAGE card (extraction §2.4 C).
struct CoverageDisplay: Equatable {
    /// e.g. "4 hr 12 min recorded".
    let headline: String
    /// e.g. "1 min missing" — nil hides the amber trailing text.
    let missingText: String?
    let spans: [CoverageSpanDisplay]

    var stripSpans: [CoverageSpan] { spans.map(\.span) }
}

// MARK: - Recap

/// One cited bullet on the recap detail (Saved-Notes pattern, extraction §2.16).
struct RecapBullet: Equatable, Identifiable {
    let id: Int
    let text: String
    /// Citation numbers rendered as inline chips after the statement ([1], [2][3]).
    let citations: [Int]
}

/// The pushed recap detail (Q2/plan conventions: "Recap card taps through to a cited recap
/// detail (Saved Notes pattern)").
struct RecapDetailDisplay: Equatable {
    /// Digest id, `day-<dateKey>` — doubles as the `.note` route id for the push.
    let id: String
    let title: String
    /// e.g. "Generated 12:40 PM · GPT-5.6 Luna · from today".
    let generatedLine: String
    let bullets: [RecapBullet]
    /// e.g. "2 moments · Coffee with Dana, App redesign session".
    let momentsFooter: String
}

/// The RECAP card (extraction §2.4 D).
struct RecapDisplay: Equatable {
    /// e.g. "updated 12:40 PM".
    let updatedText: String
    /// The 2–3 sentence digest body.
    let digest: String
    let detail: RecapDetailDisplay
}

// MARK: - Follow-ups / conversations

struct FollowUpDisplay: Equatable, Identifiable {
    let id: String
    let text: String
    var done: Bool
}

struct ConversationRowDisplay: Equatable, Identifiable {
    let id: String
    let title: String
    /// e.g. "12:04 PM · 48 min so far" (live) / "9:12 AM · 24 min" (finished).
    let meta: String
    /// Q6 calm live preview: 1-line italic rolling snippet. Live rows only.
    let snippet: String?
    let isLive: Bool
}

// MARK: - Snapshot

/// Everything the Today screen renders, in one observable value.
struct TodaySnapshot: Equatable {
    var status: StatusModel
    /// The 40-bar live minute (four-state taxonomy). Rendered only while the recording
    /// family is showing (plan 6.2: never shows paused; frozen/hidden otherwise).
    var liveMinute: [WaveformBar]
    var coverage: CoverageDisplay?
    var recap: RecapDisplay?
    var followUps: [FollowUpDisplay]
    var conversations: [ConversationRowDisplay]
}

// MARK: - Data source seam

/// The Today tab's read + action surface. `PreviewTodayData` supplies the artboard replica;
/// the runtime swaps in a DB/receiver-backed implementation via `AppDataSources.current`.
@MainActor
protocol TodayDataSource: AnyObject {
    func todaySnapshot() -> TodaySnapshot
    /// Yields the current snapshot immediately, then every change.
    func todayUpdates() -> AsyncStream<TodaySnapshot>

    /// Q13: the status card's Pause link — pauses capture on the watch (intent → paused).
    func requestPause()
    /// A status-card action button was tapped (Resume / Start Recording / Open Settings / …).
    func perform(_ action: StatusAction)
    func setFollowUpDone(id: String, done: Bool)
}

/// Holder the runtime replaces at startup; defaults to the mockup-replica preview data so
/// the app renders the approved artboards until real sources exist.
@MainActor
struct AppDataSources {
    var today: any TodayDataSource
    var live: any LiveDataSource

    static var current: AppDataSources = {
        let preview = PreviewTodayData()
        return AppDataSources(today: preview, live: preview)
    }()
}
