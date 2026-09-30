import AppDB
import Foundation
import Testing

// A tap on a chapter card or an openable gap opens the conversation at that moment (plan 7.9).
// Against the mock conversation world, which is built around the real today.

@Suite("History moment taps")
@MainActor
struct HistoryMomentTapTests {
    /// A History source that is not the demo world: no fallback.
    final class Plain: HistoryDataSource {
        func bounds() async -> HistoryBounds { HistoryBounds(firstDateKey: nil, todayDateKey: "2026-09-26", recordedDays: []) }
        func day(_ dateKey: String) -> AsyncStream<HistoryDayPage> { AsyncStream { $0.finish() } }
        func week(firstDateKey: String, lastDateKey: String) -> AsyncStream<HistoryPeriod<HistoryWeekRow>> { AsyncStream { $0.finish() } }
        func month(containing dateKey: String) -> AsyncStream<HistoryPeriod<HistoryMonthRow>> { AsyncStream { $0.finish() } }
        func prefetch(days: [String]) {}
        func setVisible(_ visible: Bool) {}
    }

    private func today(_ hour: Int, _ minute: Int) -> Int64 {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    @Test func aMomentInsideAConversationOpensItThere() async {
        AskLibraryDataSources.current = .mocks()
        let router = AppRouter()
        router.selectedTab = .library
        // "Coffee with Dana" runs 9:12 – 9:36 today in the mock world.
        await HistoryScreen.openMoment(today(9, 20), source: Plain(), router: router)
        guard case .conversation(let id, _, let focus)? = router.libraryPath.last else {
            Issue.record("expected a conversation push, got \(router.libraryPath)")
            return
        }
        #expect(id == "coffee-dana")
        #expect(focus?.style == .moment)
        #expect(focus?.startMs == today(9, 20))
    }

    /// A card names its conversation, and the tap opens that one even from a moment just
    /// outside it (quiet the day folded into the card).
    @Test func aCardsTapOpensItsOwnConversation() async {
        AskLibraryDataSources.current = .mocks()
        let router = AppRouter()
        router.selectedTab = .library
        await HistoryScreen.openMoment(
            today(9, 11), inConversation: "coffee-dana", source: Plain(), router: router)
        guard case .conversation(let id, _, let focus)? = router.libraryPath.last else {
            Issue.record("expected a conversation push, got \(router.libraryPath)")
            return
        }
        #expect(id == "coffee-dana")
        #expect(focus?.style == .moment)
    }

    @Test func aMomentWithNothingNearItDoesNothing() async {
        AskLibraryDataSources.current = .mocks()
        let router = AppRouter()
        router.selectedTab = .library
        let longAgo: Int64 = 1_000_000_000_000
        await HistoryScreen.openMoment(longAgo, source: Plain(), router: router)
        #expect(router.libraryPath.isEmpty)
    }

    @Test func theDemoWorldStillGoesSomewhere() async {
        AskLibraryDataSources.current = .mocks()
        let router = AppRouter()
        router.selectedTab = .library
        await HistoryScreen.openMoment(1_000_000_000_000, source: MockHistory(), router: router)
        #expect(router.libraryPath.count == 1)
    }
}
