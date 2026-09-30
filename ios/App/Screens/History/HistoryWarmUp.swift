import AppDB
import SwiftUI

// A one-time warm-up of the History views, drawn once off screen while the screen is idle.
//
// Profiled 2026-09-30 (optimized build, simulator, `-historyHitchLog` + Time Profiler): the
// first two swipes after launch dropped frames (worst 40–52 ms) and later swipes onto days never
// seen before did not. The lazy pager builds a neighbour page only as the swipe begins, and the
// first build of each kind of view pays one-time costs — Swift protocol-conformance lookups for
// the view types (`swift_conformsToProtocolMaybeInstantiateSuperclasses` was the top leaf of the
// first swipe) and first text layout in each font variant: the same three-card day measured in
// 8–10 ms the first time and 1.3 ms every time after. None of that is per page, so it is paid
// here, once, while nothing moves.

struct HistoryWarmUp: View {
    var body: some View {
        let day = Self.day
        VStack(alignment: .leading, spacing: 0) {
            BriefCard(
                title: Copy.History.dayInBrief, text: "Warm-up.",
                footer: Copy.History.followUpCount(total: 2, open: 1), note: Copy.History.topicsPreparing,
                onFooterTap: {})
            TimelineEdgeLine(edge: HistoryEdge(atMs: day.items[0].startMs, kind: .quiet), leading: true, zoneID: day.zoneID)
            DayTimeline(day: day, liveLine: "warm-up", onOpenTag: { _ in })
            TimelineEdgeLine(edge: HistoryEdge(atMs: day.items.last!.endMs, kind: .notListening), leading: false, zoneID: day.zoneID)
            ListCard {
                WeekDayRow(row: HistoryWeekRow(
                    dateKey: "2026-09-22", state: .recorded, headline: "Warm-up", summary: "Warm-up.",
                    tags: ["a", "b"], followUps: [HistoryFollowUpLine(id: "w", text: "Warm-up", done: false)],
                    moreFollowUps: 1), onOpenTag: { _ in })
                WeekDayRow(row: HistoryWeekRow(dateKey: "2026-09-23", state: .nothingRecorded))
                MonthWeekRow(row: HistoryMonthRow(
                    firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", isCurrentWeek: true,
                    hasRecordings: true, headline: "Warm-up", summary: "Warm-up.", tags: ["a"],
                    followUpTotal: 2, followUpOpen: 1), todayKey: "2026-09-26", onOpenTag: { _ in })
            }
            TagCountRow(tags: [HistoryTagCount(name: "a", days: 2)], onSelect: { _ in })
        }
        .frame(width: 390)
    }

    /// A small day holding every kind of item.
    static let day: HistoryDay = {
        let zone = TimeZone.current.identifier
        let base: Int64 = 1_790_000_000_000
        var items: [HistoryItem] = []
        var t = base
        func next(_ minutes: Int64) -> (Int64, Int64) {
            defer { t += minutes * 60_000 }
            return (t, t + minutes * 60_000)
        }
        var (s, e) = next(40)
        items.append(.chapter(HistoryChapterBlock(
            id: "w1", startMs: s, endMs: e, zoneID: zone, source: .chapter, title: "Warm-up",
            summary: "Warm-up summary.", tags: ["a", "b"], people: ["P"], missingMs: 60_000,
            followUps: [
                HistoryFollowUpLine(id: "f1", text: "Warm-up", done: false),
                HistoryFollowUpLine(id: "f2", text: "Warm-up", done: true),
            ])))
        for kind in HistoryGap.Kind.allCases {
            (s, e) = next(45)
            items.append(.gap(HistoryGap(
                id: "g-\(kind)", kind: kind, startMs: s, endMs: e, zoneID: zone, pausedBy: .you,
                lossCauses: [.watchBufferFull], descriptor: kind == .noConversation ? "music" : nil,
                deletedBy: .user, isOpenable: true)))
        }
        (s, e) = next(30)
        items.append(.chapter(HistoryChapterBlock(
            id: "w2", startMs: s, endMs: e, zoneID: zone, source: .conversation, title: nil,
            summary: nil, snippet: "Warm-up words.", tags: ["a"])))
        items.append(.zoneChange(HistoryZoneChange(atMs: t, zoneID: zone)))
        (s, e) = next(20)
        items.append(.live(HistoryLiveBlock(startMs: s, endMs: e, zoneID: zone)))
        return HistoryDay(
            dateKey: "2026-09-22", zoneID: zone, isToday: true, hasRecordings: true,
            leadingEdge: nil, items: items, trailingEdge: nil)
    }()
}

extension View {
    /// Draws `HistoryWarmUp` once, invisibly and off to the side, a moment after `isReady`
    /// becomes true, then drops it.
    func historyWarmUp(isReady: Bool) -> some View {
        modifier(HistoryWarmUpHost(isReady: isReady))
    }
}

private struct HistoryWarmUpHost: ViewModifier {
    let isReady: Bool
    @State private var phase = Phase.waiting
    enum Phase { case waiting, drawing, done }

    func body(content: Content) -> some View {
        content
            .background(alignment: .topLeading) {
                if phase == .drawing {
                    HistoryWarmUp()
                        .fixedSize()
                        .opacity(0)
                        .offset(x: -2_000)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: isReady) {
                guard isReady, phase == .waiting else { return }
                // After the first page is on screen and idle.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let started = ContinuousClock.now
                phase = .drawing
                try? await Task.sleep(for: .milliseconds(100))
                phase = .done
                HistoryPerformance.mark("warm-up done \(ContinuousClock.now - started)")
            }
    }
}
