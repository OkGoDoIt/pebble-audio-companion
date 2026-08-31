import AppDB
import Foundation
import StatusUI
import Testing

/// The Today source's kit→display mapping, which had no tests at all — which is how
/// `snippet: nil` survived in the one place the Q6 rolling live preview is produced.
@Suite("today mapping") @MainActor
struct TodayMappingTests {

    private func row(
        id: String = "c1", title: String? = nil, isLive: Bool = false,
        startMs: Int64 = 1_756_000_000_000, durationMs: Int64 = 24 * 60_000
    ) -> ConversationListRow {
        ConversationListRow(
            id: id, title: title, startMs: startMs, endMs: startMs + durationMs, isLive: isLive)
    }

    private func liveSnapshot(_ texts: [String]) -> LiveSnapshot {
        LiveSnapshot(
            startedLine: "started 12:04 PM",
            isLive: true,
            items: texts.enumerated().map { offset, text in
                .turn(
                    TranscriptTurn(
                        id: "t\(offset)", speakerLabel: "S1", name: "Roger", role: .you,
                        text: text))
            })
    }

    // MARK: - The rolling live line

    /// The defect: this mapper passed `snippet: nil` unconditionally while `PreviewTodayData`
    /// supplied the line, so the live preview rendered in every artboard and in no build.
    @Test func theLiveRowCarriesTheRollingLine() {
        let display = LiveTodayDataSource.conversationRow(
            row(title: "App redesign session", isLive: true),
            liveSnippet: LiveTodayDataSource.liveSnippet(
                liveSnapshot(["Earlier words.", "So the settings pages each push from one root."]))
        )

        let snippet = display.snippet
        #expect(snippet != nil, "the live row must show what is being said")
        #expect(snippet?.contains("settings pages each push from one root") == true)
        // Newest words, not the first thing said an hour ago.
        #expect(snippet?.contains("Earlier words") == false)
    }

    /// A finished row is not live and has no rolling anything — passing a stale line onto it
    /// would be worse than none.
    @Test func aFinishedRowNeverCarriesALiveLine() {
        let display = LiveTodayDataSource.conversationRow(
            row(title: "Coffee with Dana"), liveSnippet: "“…something…”")
        #expect(display.snippet == nil)
    }

    /// Nothing recognised yet is nothing to quote: an empty pair of quotation marks is
    /// decoration, and this screen does not decorate.
    @Test func noRecognisedWordsMeansNoSnippet() {
        #expect(LiveTodayDataSource.liveSnippet(liveSnapshot([])) == nil)
        #expect(LiveTodayDataSource.liveSnippet(liveSnapshot(["   "])) == nil)
        #expect(
            LiveTodayDataSource.liveSnippet(
                LiveSnapshot(startedLine: "", isLive: false, items: [])) == nil)
    }

    // MARK: - Row meta and title

    @Test func aLiveRowSaysSoFar() {
        let live = LiveTodayDataSource.conversationRow(row(isLive: true))
        let finished = LiveTodayDataSource.conversationRow(row())
        #expect(live.meta.hasSuffix(" so far"))
        #expect(!finished.meta.hasSuffix(" so far"))
    }

    /// An untitled row says which kind of untitled it is rather than rendering blank.
    @Test func anUntitledRowFallsBackByLiveness() {
        #expect(LiveTodayDataSource.conversationRow(row(isLive: true)).title == "Recording now")
        #expect(LiveTodayDataSource.conversationRow(row()).title == "Conversation")
        #expect(LiveTodayDataSource.conversationRow(row(title: "Named")).title == "Named")
    }

    // MARK: - Follow-ups

    /// Open first, then the most recently completed — the card is a to-do list, not a log.
    @Test func followUpsPutOpenItemsFirst() {
        func item(_ id: String, _ text: String, done: Bool, at ms: Int64) -> FollowUp {
            FollowUp(
                id: id, text: text, done: done, sourceConversationId: nil, sourceSegmentId: nil,
                createdAtMs: ms)
        }
        let displays = LiveTodayDataSource.followUpDisplays([
            item("done-new", "a", done: true, at: 300),
            item("open-old", "b", done: false, at: 100),
            item("open-new", "c", done: false, at: 200),
        ])
        #expect(displays.map { $0.id } == ["open-new", "open-old", "done-new"])
        #expect(displays.map { $0.text } == ["c", "b", "a"])
    }

    // MARK: - The empty state during startup recovery

    /// A migrated first launch spends tens of seconds importing, during which Today is
    /// truthfully empty — and told a user with hundreds of recordings "Ready when you are."
    /// `StartupSequencer.onStep` reported every step of that all along, into a default no-op.
    @Test func anEmptyTodayDuringRecoveryDoesNotClaimThereIsNothing() {
        let model = TodayViewModel(dataSource: FixedTodaySource(recovering: true))
        #expect(model.isEmpty)
        #expect(model.isRecovering)
        #expect(!model.isFirstRun)
        #expect(model.emptyLine == Copy.Empty.todayRecovering)
    }

    @Test func anEmptyTodayAfterRecoveryIsTheFirstRun() {
        let model = TodayViewModel(dataSource: FixedTodaySource(recovering: false))
        #expect(model.isFirstRun)
        #expect(!model.isRecovering)
        #expect(model.emptyLine == Copy.Empty.todayFirstRun)
    }

    @Test func aTodayWithContentHasNoEmptyLineEitherWay() {
        let model = TodayViewModel(
            dataSource: FixedTodaySource(
                recovering: true,
                conversations: [
                    ConversationRowDisplay(
                        id: "c1", title: "Coffee with Dana", meta: "9:12 AM · 24 min",
                        snippet: nil, isLive: false)
                ]))
        #expect(!model.isEmpty)
        #expect(model.emptyLine == nil)
    }
}

/// A `TodayDataSource` that reports one fixed snapshot — enough to drive the view model's
/// derivations without a runtime behind it.
@MainActor
private final class FixedTodaySource: TodayDataSource {
    private let value: TodaySnapshot

    init(recovering: Bool, conversations: [ConversationRowDisplay] = []) {
        value = TodaySnapshot(
            status: StatusModel(
                family: .notRecording, headline: StatusCopy.notRecording,
                detail: StatusCopy.notRecordingLine, dot: .neutral, action: .start),
            liveMinute: [], coverage: nil, recap: nil, followUps: [],
            conversations: conversations, recovering: recovering)
    }

    func todaySnapshot() -> TodaySnapshot { value }
    func todayUpdates() -> AsyncStream<TodaySnapshot> {
        AsyncStream { $0.yield(value) }
    }
    func requestPause() {}
    func perform(_ action: StatusAction) {}
    func setFollowUpDone(id: String, done: Bool) {}
}
