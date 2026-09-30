import AppDB
import Foundation
import Observation

// The History screen's state (plan 7.12 "State"): the level, the page in view, and the page
// lists the pagers scroll through. The screen owns the level and the page; a page owns only its
// own vertical scroll position.
//
// Page lists come from `HistoryCalendar` over the recorded range, first recorded day … today.
// The range only ever grows during a session: a new day is appended at the 5 AM rollover, and
// nothing is removed at the front (retention may delete the oldest day while the screen is
// open; that page then shows its removed state — removing it would make the pager jump).

enum HistoryLevel: String, CaseIterable, Hashable, Sendable {
    case day, week, month

    var title: String {
        switch self {
        case .day: return Copy.History.day
        case .week: return Copy.History.week
        case .month: return Copy.History.month
        }
    }
}

/// One page: a level and the first day of its period ("2026-09-20" for the week of the 20th,
/// "2026-09-01" for September).
struct HistoryPageID: Hashable, Sendable, Comparable, Identifiable {
    var level: HistoryLevel
    var key: String
    var id: String { "\(level.rawValue)-\(key)" }

    static func < (a: Self, b: Self) -> Bool { a.key < b.key }
}

@MainActor
@Observable
final class HistoryModel {
    private(set) var level: HistoryLevel
    /// Bound to the pager's `.scrollPosition(id:)`. Set before the pager's first layout: that is
    /// what positions it (spike — `defaultScrollAnchor` never won).
    var visiblePage: HistoryPageID? {
        didSet { if let visiblePage { focusDateKey = focus(keeping: focusDateKey, in: visiblePage) } }
    }
    /// Bumped to rebuild the pager at a far target (cross-faded) instead of scrolling past
    /// hundreds of pages.
    private(set) var jumpToken = 0
    /// Bumped to scroll the visible page to its top.
    private(set) var scrollToTopToken = 0

    /// The date the screen is "about": a level change keeps it (Day Tue 22 → the week holding
    /// the 22nd → September).
    private(set) var focusDateKey: String
    private(set) var firstDateKey: String
    private(set) var todayDateKey: String
    private(set) var recordedDays: Set<String>
    let firstWeekday: Int

    /// Pages currently scrolled away from their top, as they report it. Not observed: the tab
    /// re-tap reads it, nothing draws it.
    @ObservationIgnored var scrolledPages: Set<HistoryPageID> = []

    @ObservationIgnored private var pageCache: [HistoryLevel: [HistoryPageID]] = [:]

    init(
        bounds: HistoryBounds, level: HistoryLevel = .day, focus: String? = nil,
        firstWeekday: Int = Calendar.current.firstWeekday
    ) {
        let today = bounds.todayDateKey
        let first = min(bounds.firstDateKey ?? today, today)
        self.firstDateKey = first
        self.todayDateKey = today
        self.recordedDays = bounds.recordedDays
        self.firstWeekday = firstWeekday
        self.level = level
        let wanted = focus.map { min(max($0, first), today) } ?? today
        self.focusDateKey = wanted
        self.visiblePage = nil
        self.visiblePage = page(for: level, containing: wanted)
    }

    // MARK: Pages

    /// Every page of a level, oldest first: first recorded period … today's.
    func pages(for level: HistoryLevel) -> [HistoryPageID] {
        if let cached = pageCache[level] { return cached }
        let pages: [HistoryPageID]
        switch level {
        case .day:
            pages = HistoryCalendar.days(in: firstDateKey...todayDateKey)
                .map { HistoryPageID(level: .day, key: $0) }
        case .week:
            var result: [HistoryPageID] = []
            var week = HistoryCalendar.week(containing: firstDateKey, firstWeekday: firstWeekday)
            while week.lowerBound <= todayDateKey {
                result.append(HistoryPageID(level: .week, key: week.lowerBound))
                let next = HistoryCalendar.key(week.upperBound, addingDays: 1)
                week = next...HistoryCalendar.key(next, addingDays: 6)
            }
            pages = result
        case .month:
            var result: [HistoryPageID] = []
            var month = HistoryCalendar.month(containing: firstDateKey)
            while month.lowerBound <= todayDateKey {
                result.append(HistoryPageID(level: .month, key: month.lowerBound))
                month = HistoryCalendar.month(containing: HistoryCalendar.key(month.upperBound, addingDays: 1))
            }
            pages = result
        }
        pageCache[level] = pages
        return pages
    }

    /// The page of a level that holds a day.
    func page(for level: HistoryLevel, containing dateKey: String) -> HistoryPageID {
        switch level {
        case .day:
            return HistoryPageID(level: .day, key: dateKey)
        case .week:
            return HistoryPageID(
                level: .week,
                key: HistoryCalendar.week(containing: dateKey, firstWeekday: firstWeekday).lowerBound)
        case .month:
            return HistoryPageID(level: .month, key: HistoryCalendar.month(containing: dateKey).lowerBound)
        }
    }

    /// The days a page covers, first and last.
    func range(of page: HistoryPageID) -> ClosedRange<String> {
        switch page.level {
        case .day: return page.key...page.key
        case .week: return HistoryCalendar.week(containing: page.key, firstWeekday: firstWeekday)
        case .month: return HistoryCalendar.month(containing: page.key)
        }
    }

    var todayPage: HistoryPageID { page(for: level, containing: todayDateKey) }

    var isShowingToday: Bool { visiblePage == todayPage }

    /// Pages further than one from the visible page draw only their title, which stops the
    /// lazy stack fully building pages 0 and 1 at launch (spike).
    func isNear(_ page: HistoryPageID) -> Bool {
        guard let visiblePage, page.level == visiblePage.level else { return false }
        let pages = pages(for: page.level)
        guard let a = pages.firstIndex(of: visiblePage), let b = pages.firstIndex(of: page)
        else { return false }
        return abs(a - b) <= 1
    }

    /// The pages either side of the visible one (for `prefetch`).
    var neighbours: [HistoryPageID] {
        guard let visiblePage else { return [] }
        let pages = pages(for: visiblePage.level)
        guard let index = pages.firstIndex(of: visiblePage) else { return [] }
        return [index - 1, index + 1].filter { pages.indices.contains($0) }.map { pages[$0] }
    }

    /// The page `offset` away from the visible one, if there is one (no page beyond either end).
    func page(offset: Int) -> HistoryPageID? {
        guard let visiblePage else { return nil }
        let pages = pages(for: visiblePage.level)
        guard let index = pages.firstIndex(of: visiblePage), pages.indices.contains(index + offset)
        else { return nil }
        return pages[index + offset]
    }

    // MARK: Moving

    enum Move: Equatable {
        /// Already there.
        case none
        /// A neighbour: scroll to it, animated.
        case scroll
        /// Further, or another level: the pager is rebuilt at the target.
        case rebuild
    }

    /// Shows the period of `level` that holds `dateKey`. Returns how the pager should get
    /// there; the caller wraps `.scroll` in an animation and cross-fades a `.rebuild`.
    @discardableResult
    func show(_ level: HistoryLevel, containing dateKey: String) -> Move {
        let clamped = min(max(dateKey, firstDateKey), todayDateKey)
        let target = page(for: level, containing: clamped)
        let levelChanged = level != self.level
        let move: Move
        if levelChanged {
            move = .rebuild
        } else if target == visiblePage {
            move = .none
        } else if let visiblePage, isAdjacent(visiblePage, target) {
            move = .scroll
        } else {
            move = .rebuild
        }
        self.level = level
        focusDateKey = clamped
        visiblePage = target
        if move == .rebuild && !levelChanged { jumpToken += 1 }
        return move
    }

    /// The level control: keeps the date in focus.
    @discardableResult
    func changeLevel(to level: HistoryLevel) -> Move {
        guard level != self.level else { return .none }
        return show(level, containing: focusDateKey)
    }

    /// The Today button, and the second re-tap of the tab.
    @discardableResult
    func showToday() -> Move { show(level, containing: todayDateKey) }

    /// The first re-tap of the tab while the page is scrolled.
    func scrollToTop() { scrollToTopToken += 1 }

    private func isAdjacent(_ a: HistoryPageID, _ b: HistoryPageID) -> Bool {
        guard a.level == b.level else { return false }
        let pages = pages(for: a.level)
        guard let i = pages.firstIndex(of: a), let j = pages.firstIndex(of: b) else { return false }
        return abs(i - j) == 1
    }

    /// Which day a newly visible page is "about": the old focus when the page holds it (so
    /// paging week to week does not lose the day inside it), else the page's first day — or
    /// today, when the page holds today.
    private func focus(keeping old: String, in page: HistoryPageID) -> String {
        let range = self.range(of: page)
        if range.contains(old) { return old }
        if range.contains(todayDateKey) { return todayDateKey }
        return max(range.lowerBound, firstDateKey)
    }

    // MARK: Bounds

    /// New bounds from the data source. The range only grows: a later first day is ignored,
    /// an earlier one or a new today extends the lists. The visible page does not move.
    func update(bounds: HistoryBounds) {
        let first = min(bounds.firstDateKey ?? firstDateKey, firstDateKey)
        let today = max(bounds.todayDateKey, todayDateKey)
        recordedDays.formUnion(bounds.recordedDays)
        guard first != firstDateKey || today != todayDateKey else { return }
        firstDateKey = first
        todayDateKey = today
        pageCache = [:]
    }
}
