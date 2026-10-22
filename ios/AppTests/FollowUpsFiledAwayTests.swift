import AppDB
import Foundation
import Testing

// The filed-away summary at the foot of the open follow-up list.
//
// The whole point of the section is a number the person can trust: the age rule takes items off
// the working list on its own, so "3" under it is the app's only account of what it did. Every
// test here is about that number staying true — through a scope change, through a delete, and
// through a source that hands the rows back in the wrong order.

@Suite("filed-away summary")
@MainActor
struct FollowUpsFiledAwayTests {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func ms(_ daysAgo: Int) -> Int64 {
        Int64(now.addingTimeInterval(Double(-daysAgo) * 86_400).timeIntervalSince1970 * 1000)
    }

    private func item(
        _ id: String,
        done: Bool = false,
        archivedDaysAgo: Int? = nil
    ) -> FollowUpItem {
        FollowUpItem(
            id: id, text: "Follow up \(id)", done: done, priority: .normal, origin: .ai,
            createdAtMs: ms(30), archivedAtMs: archivedDaysAgo.map(ms))
    }

    private func makeModel(_ rows: [FollowUpItem]) -> FollowUpsViewModel {
        FollowUpsViewModel(source: FakeFollowUpsSource(rows: rows))
    }

    // MARK: The count

    @Test func openListCountsWhatTheAgeRuleTookAway() async {
        let model = makeModel([
            item("live-1"), item("live-2"),
            item("gone-1", archivedDaysAgo: 1), item("gone-2", archivedDaysAgo: 2),
        ])

        await model.reload()

        #expect(model.filedAwayCount == 2)
        #expect(model.sections.flatMap(\.items).count == 2, "filed-away rows stay out of the list")
    }

    /// The other two scopes ARE the filed-away (or completed) list, so a summary of one under
    /// itself would be the same rows twice.
    @Test func theSummaryIsOnlyForTheOpenList() async {
        let model = makeModel([item("live-1"), item("gone-1", archivedDaysAgo: 1)])

        model.scope = .archived
        await model.reload()

        #expect(model.filedAwayCount == 0)
        #expect(model.sections.flatMap(\.items).count == 1, "the list itself shows them")
    }

    @Test func noSummaryWhenNothingHasBeenFiledAway() async {
        let model = makeModel([item("live-1")])

        await model.reload()

        #expect(model.filedAwayCount == 0)
        #expect(model.filedAwayPreview.isEmpty)
        #expect(model.hasMoreFiledAway == false)
    }

    // MARK: The preview

    /// Newest first. The preview shows only the first few, so "the first few" has to mean the
    /// ones that went most recently — this fake hands them back oldest-first on purpose.
    @Test func thePreviewShowsTheMostRecentlyFiledFirst() async {
        let model = makeModel([
            item("oldest", archivedDaysAgo: 9),
            item("middle", archivedDaysAgo: 5),
            item("newest", archivedDaysAgo: 1),
        ])

        await model.reload()

        #expect(model.filedAwayPreview.map(\.id) == ["newest", "middle", "oldest"])
    }

    @Test func thePreviewIsCappedAndTheCountIsNot() async {
        let limit = FollowUpsViewModel.filedAwayPreviewLimit
        let model = makeModel((0..<(limit + 3)).map { item("gone-\($0)", archivedDaysAgo: $0 + 1) })

        await model.reload()

        #expect(model.filedAwayCount == limit + 3, "the count is the whole slice, not the preview")
        #expect(model.filedAwayPreview.count == limit)
        #expect(model.hasMoreFiledAway)
    }

    @Test func aSliceThatFitsNeedsNoSeeAllRow() async {
        let limit = FollowUpsViewModel.filedAwayPreviewLimit
        let model = makeModel((0..<limit).map { item("gone-\($0)", archivedDaysAgo: $0 + 1) })

        await model.reload()

        #expect(model.hasMoreFiledAway == false)
    }

    // MARK: The count while something is being changed
    //
    // A row deleted out of the summary is gone from the database a round trip later. Until then
    // the header must not sit above two rows saying "3" — the one number on this screen nobody
    // can check by counting is the one that has to be right.

    @Test func deletingFromTheSummaryDropsTheCountAtOnce() async throws {
        let model = makeModel([
            item("live-1"),
            item("gone-1", archivedDaysAgo: 1), item("gone-2", archivedDaysAgo: 2),
        ])
        await model.reload()
        let doomed = try #require(model.filedAwayPreview.first)

        model.delete(doomed)

        #expect(model.filedAwayCount == 1)
        #expect(model.filedAwayPreview.map(\.id) == ["gone-2"])
    }

    @Test func undoingThatDeletePutsItBackInTheCount() async throws {
        let model = makeModel([
            item("gone-1", archivedDaysAgo: 1), item("gone-2", archivedDaysAgo: 2),
        ])
        await model.reload()
        let doomed = try #require(model.filedAwayPreview.first)

        model.delete(doomed)
        model.undoDelete(doomed)

        #expect(model.filedAwayCount == 2)
    }

    /// Restoring is the other way out of the section, and it is a database write like any
    /// other: once it lands the row belongs to the open list and the count is one lower.
    @Test func aRestoredRowLeavesTheSummaryForTheList() async throws {
        let source = FakeFollowUpsSource(rows: [
            item("live-1"), item("gone-1", archivedDaysAgo: 1),
        ])
        let model = FollowUpsViewModel(source: source)
        await model.reload()
        #expect(model.filedAwayCount == 1)

        try await source.setArchived(id: "gone-1", archived: false)
        await model.reload()

        #expect(model.filedAwayCount == 0)
        #expect(model.sections.flatMap(\.items).count == 2)
    }

    // MARK: The line under a filed-away row

    @Test func aFiledAwayRowSaysWhenItWentAndNothingElse() {
        #expect(
            FollowUpFormatting.filedAwayDay(item("gone-1", archivedDaysAgo: 1), now: now)
                == "yesterday")
    }

    /// Nil rather than a guess, so nothing can label a live row as filed away.
    @Test func aLiveRowHasNoFiledAwayDay() {
        #expect(FollowUpFormatting.filedAwayDay(item("live-1"), now: now) == nil)
    }

    // MARK: Copy

    @Test func theCountReadsAsWordsForVoiceOver() {
        #expect(Copy.FollowUps.filedAwayA11y(1) == "Filed away, 1 item")
        #expect(Copy.FollowUps.filedAwayA11y(4) == "Filed away, 4 items")
        #expect(Copy.FollowUps.openFiledAway(1) == "See 1 filed away")
        #expect(Copy.FollowUps.openFiledAway(4) == "See 4 filed away")
    }

    /// The empty state used to end by offering to write your own follow-up. There is nowhere to
    /// do that any more, and an empty state that names a control the screen does not have is the
    /// kind of small lie that costs trust everywhere else.
    @Test func theEmptyStateNoLongerOffersToAddOne() {
        #expect(!Copy.FollowUps.emptyOpenBodySuggested.lowercased().contains("add"))
        #expect(!Copy.FollowUps.emptyOpenBodySuggestedNoAi.lowercased().contains("add"))
    }
}

// MARK: - Fake source

/// In-memory `FollowUpsDataSource`. Deliberately NOT `MockFollowUps`: that one reads and writes
/// the shared `MockWorld` singleton the previews and other suites also mutate, and every
/// assertion here is a count.
@MainActor
final class FakeFollowUpsSource: FollowUpsDataSource {
    var rows: [FollowUpItem]
    var automaticProposalsEnabled = true
    var proposalsAreOnDevice = false

    init(rows: [FollowUpItem]) { self.rows = rows }

    func items(scope: FollowUpListScope) async throws -> [FollowUpItem] {
        rows.filter { row in
            switch scope {
            case .open: return !row.done && !row.isArchived && row.stage == .reminder
            case .completed: return row.done && !row.isArchived && row.stage == .reminder
            case .archived: return row.isArchived
            }
        }
    }

    func item(id: String) async throws -> FollowUpItem? { rows.first { $0.id == id } }

    /// Finishes immediately: these tests drive `reload()` themselves, and a stream that never
    /// ends would hang `start(scope:)` forever.
    func followUpUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }

    @discardableResult
    func add(text: String, dueAtMs: Int64?) async throws -> String {
        let id = "added-\(rows.count)"
        rows.append(
            FollowUpItem(
                id: id, text: text, done: false, dueAtMs: dueAtMs, priority: .normal,
                origin: .user, createdAtMs: 0))
        return id
    }

    func setDone(id: String, done: Bool) async throws {
        mutate(id) {
            $0.done = done
            $0.archivedAtMs = nil
        }
    }

    func setText(id: String, text: String) async throws { mutate(id) { $0.text = text } }

    func setDue(id: String, dueAtMs: Int64?) async throws { mutate(id) { $0.dueAtMs = dueAtMs } }

    func setPriority(id: String, priority: FollowUpPriority) async throws {
        mutate(id) { $0.priority = priority }
    }

    func snooze(id: String, untilMs: Int64?) async throws {
        mutate(id) { $0.snoozedUntilMs = untilMs }
    }

    func setArchived(id: String, archived: Bool) async throws {
        mutate(id) { $0.archivedAtMs = archived ? 1 : nil }
    }

    func delete(id: String) async throws { rows.removeAll { $0.id == id } }

    func restore(_ item: FollowUpItem) async throws {
        rows.removeAll { $0.id == item.id }
        rows.append(item)
    }

    func source(of id: String) async -> CitationTarget? { nil }

    /// The clock `setStage` stamps decisions with.
    var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    func reviewQueue() async throws -> [FollowUpItem] {
        rows.filter { $0.stage == .suggested && !$0.isArchived && !$0.done }
            .sorted { $0.said < $1.said }
    }

    func decided(fromMs: Int64, toMs: Int64) async throws -> [FollowUpItem] {
        rows.filter { row in
            guard let decided = row.decidedAtMs, row.stage != .suggested, row.origin == .ai
            else { return false }
            return decided >= fromMs && decided < toMs
        }
        .sorted { $0.said < $1.said }
    }

    func items(conversationId: String) async throws -> [FollowUpItem] {
        rows.filter { $0.sourceConversationId == conversationId }
    }

    func setStage(id: String, stage: FollowUpStage) async throws {
        let stamp = nowMs
        mutate(id) {
            $0.stage = stage
            $0.decidedAtMs = stage == .suggested ? nil : stamp
        }
    }

    private func mutate(_ id: String, _ change: (inout FollowUpItem) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }
}
