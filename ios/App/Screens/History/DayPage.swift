import AppDB
import SwiftUI

/// One day (plan 5.3): its two-line title drawn in the page, the in-brief card, the leading edge
/// line, the timeline and the trailing edge line, in the page's own vertical scroll view. Every
/// state of plan 5.8 is drawn here.
///
/// Only the page in view subscribes to its day (`.task(id:)` ends the stream when it stops
/// being current); a neighbour takes one value and lets go — the pager's `prefetch` has built
/// it — so a swipe lands on a drawn page without a neighbour ever being observed. The page
/// writes no state the timeline does not need: every write re-runs the timeline's measurement.
struct DayPage: View, Equatable {
    let context: HistoryPageContext
    let services: HistoryPageServices

    @State private var page: HistoryDayPage?
    /// How many of the day's items are drawn. A page appearing for the first time draws its
    /// first screenful at once and the rest over the next frames (`DayReveal`).
    @State private var revealed = Int.max
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dateKey: String { context.page.key }
    private var todayKey: String { context.todayKey }
    private var source: any HistoryDataSource { services.source }
    private var actions: HistoryActions { services.actions }

    nonisolated static func == (a: DayPage, b: DayPage) -> Bool {
        a.context == b.context && a.services === b.services
    }

    var body: some View {
        HistoryPageFrame(
            context: context, services: services, title: title.title, subtitle: title.subtitle
        ) {
            if let page {
                content(page)
                    .onAppear { HistoryPerformance.firstContent(context.page, isCurrent: context.isCurrent) }
            } else {
                loadingFrame
            }
        }
        .task(id: HistoryStreamKey(context)) {
            guard context.isNear else { return }
            if context.isCurrent {
                for await next in source.day(dateKey) where next != page {
                    show(next)
                }
            } else if page == nil {
                // A neighbour: one value, no observation.
                for await next in source.day(dateKey) {
                    show(next)
                    break
                }
            }
        }
        .task(id: revealed) {
            // One more batch a frame at a time until the whole day is drawn.
            guard let page, revealed < page.entries.count else { return }
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            revealed = DayReveal.next(after: revealed, count: page.entries.count)
        }
    }

    /// The first time a page gets its day, only the first screenful is drawn; a later update of
    /// a page already on screen is drawn whole.
    private func show(_ next: HistoryDayPage) {
        if page == nil {
            revealed = DayReveal.firstScreenful(next.entries)
        }
        page = next
    }

    private var title: (title: String, subtitle: String) {
        let zone = page.flatMap { TimeZone(identifier: $0.day.zoneID) } ?? .current
        return HistoryFormat.dayTitle(dateKey, todayKey: todayKey, zone: zone)
    }

    // MARK: States

    @ViewBuilder
    private func content(_ page: HistoryDayPage) -> some View {
        let unplaced = page.moments.filter { mark in
            !page.entries.contains { mark.wallMs >= $0.startMs && mark.wallMs < $0.endMs }
        }
        let first = page.entries.first?.startMs ?? Int64.max
        let before = unplaced.filter { $0.wallMs < first }
        if !before.isEmpty {
            Card { MarkedMomentLinks(moments: before, timeZone: TimeZone(identifier: page.day.zoneID) ?? .current) }
                .padding(.bottom, Tokens.blockGap)
        }
        if !page.day.hasRecordings {
            Text(Copy.History.nothingRecorded)
                .font(AppFont.historyBody(dynamicTypeSize))
                .foregroundStyle(Tokens.meta)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        } else {
            brief(page)
                .padding(.bottom, Tokens.blockGap)
            if let edge = page.day.leadingEdge {
                TimelineEdgeLine(edge: edge, leading: true, zoneID: zoneID(of: page.day.items.first))
            }
            let complete = revealed >= page.entries.count
            DayTimeline(
                day: complete ? page.day : DayReveal.prefix(page.day, until: page.entries, revealed),
                entries: complete ? page.entries : Array(page.entries.prefix(revealed)),
                moments: page.moments,
                liveLine: page.liveLine, isComplete: complete,
                onOpenChapter: actions.openChapter, onOpenFollowUp: actions.openFollowUp,
                onOpenGap: actions.openGap, onOpenLive: actions.openLive, onOpenTag: actions.openTag)
            if complete, let edge = page.day.trailingEdge {
                TimelineEdgeLine(edge: edge, leading: false, zoneID: zoneID(of: page.day.items.last))
            }
        }
        let after = unplaced.filter { $0.wallMs >= first }
        if !after.isEmpty, revealed >= page.entries.count {
            Card { MarkedMomentLinks(moments: after, timeZone: TimeZone(identifier: page.day.zoneID) ?? .current) }
                .padding(.top, Tokens.blockGap)
        }
    }

    private func brief(_ page: HistoryDayPage) -> some View {
        let isToday = page.day.isToday
        var footer: [String] = []
        if page.followUpTotal > 0 {
            footer.append(Copy.History.followUpCount(total: page.followUpTotal, open: page.followUpOpen))
        }
        if isToday, let brief = page.brief, brief.updatedAtMs > 0 {
            let zone = TimeZone(identifier: page.day.zoneID) ?? .current
            footer.append(Copy.History.updated(HistoryFormat.time(brief.updatedAtMs, zone: zone)))
        }
        return BriefCard(
            title: isToday ? Copy.History.todaySoFar : Copy.History.dayInBrief,
            text: page.brief?.text,
            placeholder: page.isWaitingToTranscribe
                ? Copy.History.waitingToTranscribe : Copy.History.noSummaryYet,
            footer: footer.isEmpty ? nil : footer.joined(separator: " · "),
            note: page.topics == .preparing ? Copy.History.topicsPreparing : nil,
            onFooterTap: page.followUpTotal > 0 ? { actions.openFollowUps(dateKey) } : nil)
    }

    /// First load: the frame, never a spinner (plan 5.8).
    private var loadingFrame: some View {
        RoundedRectangle(cornerRadius: Tokens.cardRadius)
            .fill(Tokens.surface)
            .frame(height: 96)
            .accessibilityHidden(true)
    }

    private func zoneID(of item: HistoryItem?) -> String {
        switch item {
        case .chapter(let block)?: return block.zoneID
        case .gap(let gap)?: return gap.zoneID
        case .live(let live)?: return live.zoneID
        case .zoneChange(let change)?: return change.zoneID
        case nil: return page?.day.zoneID ?? TimeZone.current.identifier
        }
    }
}

/// Where History's taps go. The shell wires these to routes; until then they do nothing.
struct HistoryActions {
    var openChapter: (HistoryChapterBlock) -> Void = { _ in }
    var openFollowUp: (HistoryFollowUpLine) -> Void = { _ in }
    var openGap: (HistoryGap) -> Void = { _ in }
    var openLive: () -> Void = {}
    /// The brief's footer: the Follow-ups tab, filtered to the period starting at this day.
    var openFollowUps: (String) -> Void = { _ in }
    /// A topic's results (plan 5.7).
    var openTag: (String) -> Void = { _ in }
}

/// Paging onto a day that has never been built costs its whole layout in the frame the page
/// comes into view — about 60 ms for a 25-card day in the simulator, three dropped frames in a
/// swipe. So a new page draws what the first screen can show, and the rest a batch per frame
/// (plan 7.12). The day always opens at its top, so nothing visibly changes.
enum DayReveal {
    /// Enough items to fill what a swipe shows under the title and the brief card, counted on
    /// the floor scale (cards are taller than their floor, so this over-fills), and never
    /// fewer than three.
    static let screenfulPoints: CGFloat = 500
    static let batch = 4

    static func firstScreenful(_ items: [HistoryDayEntry]) -> Int {
        var height: CGFloat = 0
        var count = 0
        for item in items {
            count += 1
            height += max(TimelineSpan(startMs: item.startMs, endMs: item.endMs).minutes
                * TimelineScale.pointsPerMinute, 44)
            if height >= screenfulPoints && count >= 3 { break }
        }
        return count
    }

    static func next(after revealed: Int, count: Int) -> Int {
        min(count, revealed + batch)
    }

    /// The day cut where the first `count` entries end, so its items (which set the hour
    /// marks) cover exactly the entries drawn.
    static func prefix(_ day: HistoryDay, until entries: [HistoryDayEntry], _ count: Int) -> HistoryDay {
        var partial = day
        guard count > 0, count <= entries.count else {
            partial.items = []
            return partial
        }
        let end = entries[count - 1].endMs
        partial.items = day.items.filter { $0.startMs < end || ($0.startMs == end && $0.endMs == end) }
        return partial
    }
}
