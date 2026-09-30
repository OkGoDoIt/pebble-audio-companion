import AppDB
import Foundation
import Testing

// The History screen's page lists and moves (plan 5.1, 7.12). The pager is only as right as
// these: which pages exist, which one is in view, and how a level change keeps its date.

@Suite("History model")
@MainActor
struct HistoryModelTests {
    /// September 2026 as the demo world has it: first recording on the 1st, today the 26th.
    private func model(level: HistoryLevel = .day, focus: String? = nil, sundayFirst: Bool = true)
        -> HistoryModel
    {
        HistoryModel(
            bounds: HistoryBounds(firstDateKey: "2026-09-01", todayDateKey: "2026-09-26", recordedDays: []),
            level: level, focus: focus, firstWeekday: sundayFirst ? 1 : 2)
    }

    // MARK: Page lists

    @Test func dayPagesRunFromTheFirstRecordedDayToToday() {
        let pages = model().pages(for: .day)
        #expect(pages.count == 26)
        #expect(pages.first?.key == "2026-09-01")
        #expect(pages.last?.key == "2026-09-26")
    }

    @Test func weekPagesFollowTheLocalesFirstWeekday() {
        let sunday = model().pages(for: .week).map(\.key)
        #expect(sunday == ["2026-08-30", "2026-09-06", "2026-09-13", "2026-09-20"])
        let monday = model(sundayFirst: false).pages(for: .week).map(\.key)
        #expect(monday == ["2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21"])
    }

    @Test func monthPagesSpanTheRange() {
        let m = HistoryModel(
            bounds: HistoryBounds(firstDateKey: "2026-07-30", todayDateKey: "2026-09-26", recordedDays: []))
        #expect(m.pages(for: .month).map(\.key) == ["2026-07-01", "2026-08-01", "2026-09-01"])
    }

    @Test func aFreshScreenOpensOnTodayAndAnAskedForDayOpensThere() {
        #expect(model().visiblePage == HistoryPageID(level: .day, key: "2026-09-26"))
        #expect(model().isShowingToday)
        let tuesday = model(focus: "2026-09-22")
        #expect(tuesday.visiblePage?.key == "2026-09-22")
        #expect(!tuesday.isShowingToday)
        // Outside the range is clamped to it: there is no page beyond either end.
        #expect(model(focus: "2027-01-01").visiblePage?.key == "2026-09-26")
        #expect(model(focus: "2020-01-01").visiblePage?.key == "2026-09-01")
    }

    @Test func onlyThePagesBesideTheVisibleOneAreNear() {
        let m = model(focus: "2026-09-22")
        #expect(m.isNear(HistoryPageID(level: .day, key: "2026-09-21")))
        #expect(m.isNear(HistoryPageID(level: .day, key: "2026-09-23")))
        #expect(!m.isNear(HistoryPageID(level: .day, key: "2026-09-24")))
        #expect(m.neighbours.map(\.key) == ["2026-09-21", "2026-09-23"])
        #expect(model().neighbours.map(\.key) == ["2026-09-25"])
    }

    // MARK: Level changes keep the date in focus

    @Test func dayToWeekToMonthKeepsTheDate() {
        let m = model(focus: "2026-09-22")
        #expect(m.changeLevel(to: .week) == .rebuild)
        #expect(m.visiblePage == HistoryPageID(level: .week, key: "2026-09-20"))
        m.changeLevel(to: .month)
        #expect(m.visiblePage == HistoryPageID(level: .month, key: "2026-09-01"))
        // ...and back down lands on the same day, not on the week's or month's first.
        m.changeLevel(to: .week)
        #expect(m.visiblePage?.key == "2026-09-20")
        m.changeLevel(to: .day)
        #expect(m.visiblePage?.key == "2026-09-22")
    }

    @Test func pagingAWeekMovesTheFocusIntoIt() {
        let m = model(level: .week, focus: "2026-09-22")
        m.visiblePage = HistoryPageID(level: .week, key: "2026-09-13")
        #expect(m.focusDateKey == "2026-09-13")
        m.changeLevel(to: .day)
        #expect(m.visiblePage?.key == "2026-09-13")
    }

    @Test func pagingOntoTheCurrentPeriodFocusesToday() {
        let m = model(level: .week, focus: "2026-09-10")
        m.visiblePage = HistoryPageID(level: .week, key: "2026-09-20")
        m.changeLevel(to: .day)
        #expect(m.visiblePage?.key == "2026-09-26")
    }

    // MARK: Drill-down and Today

    @Test func drillDownFromAWeekRowOpensThatDay() {
        let m = model(level: .week, focus: "2026-09-22")
        #expect(m.show(.day, containing: "2026-09-24") == .rebuild)
        #expect(m.level == .day)
        #expect(m.visiblePage?.key == "2026-09-24")
    }

    @Test func drillDownFromAMonthRowOpensThatWeek() {
        let m = model(level: .month, focus: "2026-09-22")
        m.show(.week, containing: "2026-09-13")
        #expect(m.visiblePage == HistoryPageID(level: .week, key: "2026-09-13"))
    }

    @Test func todayFromTheAdjacentPageScrollsAndFromFarRebuilds() {
        let adjacent = model(focus: "2026-09-25")
        let token = adjacent.jumpToken
        #expect(adjacent.showToday() == .scroll)
        #expect(adjacent.isShowingToday)
        #expect(adjacent.jumpToken == token)

        let far = model(focus: "2026-09-02")
        #expect(far.showToday() == .rebuild)
        #expect(far.isShowingToday)
        #expect(far.jumpToken == token + 1)

        #expect(model().showToday() == .none)
    }

    @Test func pageOffsetStopsAtTheEnds() {
        let m = model()
        #expect(m.page(offset: 1) == nil)
        #expect(m.page(offset: -1)?.key == "2026-09-25")
        let first = model(focus: "2026-09-01")
        #expect(first.page(offset: -1) == nil)
    }

    // MARK: Bounds growth

    @Test func aNewDayIsAppendedAtTheRollover() {
        let m = model(focus: "2026-09-22")
        m.update(bounds: HistoryBounds(firstDateKey: "2026-09-01", todayDateKey: "2026-09-27", recordedDays: ["2026-09-27"]))
        #expect(m.pages(for: .day).last?.key == "2026-09-27")
        #expect(m.pages(for: .week).last?.key == "2026-09-27")
        #expect(m.recordedDays.contains("2026-09-27"))
        // The page in view does not move.
        #expect(m.visiblePage?.key == "2026-09-22")
    }

    @Test func theRangeNeverShrinksInASession() {
        let m = model()
        // Retention removed the first days: the list keeps them until the next launch.
        m.update(bounds: HistoryBounds(firstDateKey: "2026-09-05", todayDateKey: "2026-09-26", recordedDays: []))
        #expect(m.pages(for: .day).first?.key == "2026-09-01")
        #expect(m.pages(for: .day).count == 26)
    }
}
