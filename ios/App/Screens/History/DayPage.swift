import AppDB
import SwiftUI

/// One day (plan 5.3): its two-line title drawn in the page (so it slides away with the day when
/// a pager is added), the in-brief card, the leading edge line, the timeline and the trailing
/// edge line, in one vertical scroll view. Every state of plan 5.8 is drawn here.
///
/// The page owns only its own vertical scroll position. It subscribes to its day while it is on
/// screen (`.task(id:)` cancels the stream when it goes) and writes no state the timeline does
/// not need: every write re-runs the timeline's measurement.
struct DayPage: View {
    let dateKey: String
    let todayKey: String
    var source: any HistoryDataSource
    var actions = HistoryActions()

    @State private var page: HistoryDayPage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HistoryPageTitle(title: title.title, subtitle: title.subtitle)
                if let page {
                    content(page)
                } else {
                    loadingFrame
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.bottom, Tokens.blockGap)
        }
        .background(Tokens.ground)
        .task(id: dateKey) {
            for await next in source.day(dateKey) where next != page {
                page = next
            }
        }
    }

    private var title: (title: String, subtitle: String) {
        let zone = page.flatMap { TimeZone(identifier: $0.day.zoneID) } ?? .current
        return HistoryFormat.dayTitle(dateKey, todayKey: todayKey, zone: zone)
    }

    // MARK: States

    @ViewBuilder
    private func content(_ page: HistoryDayPage) -> some View {
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
            DayTimeline(
                day: page.day, liveLine: page.liveLine,
                onOpenChapter: actions.openChapter, onOpenFollowUp: actions.openFollowUp,
                onOpenGap: actions.openGap, onOpenLive: actions.openLive)
            if let edge = page.day.trailingEdge {
                TimelineEdgeLine(edge: edge, leading: false, zoneID: zoneID(of: page.day.items.last))
            }
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

/// A History page's title, drawn in the page under the level control (plan 5.1, 7.12): large
/// and left-aligned, one line ("Sep 20 – 26") or two ("Tuesday" / "September 22").
struct HistoryPageTitle: View {
    let title: String
    var subtitle: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.historyTitle(dynamicTypeSize))
                .foregroundStyle(Tokens.label)
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.meta)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
}
