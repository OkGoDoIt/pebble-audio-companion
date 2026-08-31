import AppDB
import Foundation
import Intelligence
import Testing

/// The scope pill above the search results. It used to change, re-run the search visibly, and
/// return byte-identical results, because BOTH `LiveWorld.search` and `MockWorld.search` took
/// `scope` and ignored it — so a scoped-search test would have passed against a broken app and
/// nobody wrote one. Both honour it now; these are the tests that can fail.
@Suite("search scope") @MainActor
struct SearchScopeTests {

    private var zone: String { TimeZone.current.identifier }
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func dateKey(daysAgo: Int) -> String {
        LogicalDay.dateKey(forMs: nowMs - Int64(daysAgo) * 86_400_000, timeZoneID: zone)
    }

    // MARK: - The window the scope actually resolves to

    /// The app's scope vocabulary mapped onto the kit's logical-day ranges. This is the half of
    /// "honouring the scope" that lives in the App layer, and everything below rides on it.
    @Test func todayResolvesToTodayAndExcludesYesterday() throws {
        let window = try #require(
            askScopeDateKeyRange(AskScope.today.kitScope, nowMs: nowMs, timeZoneID: zone))
        #expect(window.contains(dateKey(daysAgo: 0)))
        #expect(!window.contains(dateKey(daysAgo: 1)))
    }

    @Test func yesterdayExcludesToday() throws {
        let window = try #require(
            askScopeDateKeyRange(AskScope.yesterday.kitScope, nowMs: nowMs, timeZoneID: zone))
        #expect(window.contains(dateKey(daysAgo: 1)))
        #expect(!window.contains(dateKey(daysAgo: 0)))
    }

    /// "Last 2 days" is today and yesterday — and not the day before.
    @Test func lastTwoDaysSpansExactlyTwoLogicalDays() throws {
        let window = try #require(
            askScopeDateKeyRange(AskScope.lastDays(2).kitScope, nowMs: nowMs, timeZoneID: zone))
        #expect(window.contains(dateKey(daysAgo: 0)))
        #expect(window.contains(dateKey(daysAgo: 1)))
        #expect(!window.contains(dateKey(daysAgo: 2)))
    }

    @Test func lastSevenDaysReachesBackSixAndNoFurther() throws {
        let window = try #require(
            askScopeDateKeyRange(AskScope.last7Days.kitScope, nowMs: nowMs, timeZoneID: zone))
        #expect(window.contains(dateKey(daysAgo: 6)))
        #expect(!window.contains(dateKey(daysAgo: 7)))
    }

    /// No window at all: "Everything" must not quietly become "the last N days".
    @Test func everythingHasNoWindow() {
        #expect(
            askScopeDateKeyRange(AskScope.everything.kitScope, nowMs: nowMs, timeZoneID: zone)
                == nil)
    }

    /// A conversation-scoped question is narrowed by conversation, not by date, so its date
    /// window has to be open — otherwise asking about last month's meeting finds nothing.
    @Test func conversationScopeIsNotDateNarrowed() {
        let scope = AskScope.conversation(id: "coffee-dana", title: "Coffee with Dana")
        #expect(askScopeDateKeyRange(scope.kitScope, nowMs: nowMs, timeZoneID: zone) == nil)
    }

    // MARK: - Search narrows to it

    /// The whole point: narrowing the pill narrows the results.
    @Test func searchNarrowsToTheScopedDay() async throws {
        let world = MockWorld.shared

        let everything = try await world.search(query: "work", scope: .everything)
        let today = try await world.search(query: "work", scope: .today)

        #expect(!everything.conversations.isEmpty, "the fixture has matches to narrow")
        #expect(
            today.conversations.count < everything.conversations.count,
            "narrowing to Today must drop yesterday's matches")
        for hit in today.conversations {
            #expect(everything.conversations.contains { $0.id == hit.id })
        }
    }

    /// A scope with nothing in it returns nothing, rather than falling back to everything.
    @Test func anEmptyWindowReturnsNoConversations() async throws {
        let long = Date().addingTimeInterval(-400 * 86_400)
        let results = try await MockWorld.shared.search(
            query: "work", scope: .dateRange(start: long, end: long))
        #expect(results.conversations.isEmpty)
    }

    /// An empty query is not a search — it must not return the whole library.
    @Test func anEmptyQueryReturnsNothing() async throws {
        let results = try await MockWorld.shared.search(query: "   ", scope: .everything)
        #expect(results.isEmpty)
    }

    // MARK: - The pill survives a deep link

    /// `companion://ask?scope=…` and the pill are the same value; a round trip that loses the
    /// scope silently widens the question.
    @Test(arguments: [
        AskScope.today, .yesterday, .last7Days, .everything, .lastDays(2), .lastDays(30),
    ])
    func scopeRoundTripsThroughItsRouteKey(_ scope: AskScope) {
        let parsed = AskScope.parse(scope.routeKey, conversationTitle: { _ in nil })
        #expect(parsed == scope)
    }

    @Test func aConversationScopeRoundTripsWithItsTitle() {
        let scope = AskScope.conversation(id: "coffee-dana", title: "Coffee with Dana")
        let parsed = AskScope.parse(
            scope.routeKey, conversationTitle: { $0 == "coffee-dana" ? "Coffee with Dana" : nil })
        #expect(parsed == scope)
    }

    /// An unrecognised key falls back to the artboard default rather than to "everything":
    /// widening a question the user did not widen is the failure mode that matters.
    @Test func anUnknownKeyFallsBackToTheDefaultPill() {
        #expect(AskScope.parse("nonsense", conversationTitle: { _ in nil }) == .lastDays(2))
        #expect(AskScope.parse(nil, conversationTitle: { _ in nil }) == .lastDays(2))
    }
}
