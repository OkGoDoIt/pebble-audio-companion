import AppDB
import SwiftUI

// The Week and Month pages (plan 5.4, 5.5): the in-brief card, then one white card holding a
// row per day (week) or per week (month), oldest first. A row opens the level below it — a day
// row switches to Day on that date, a week row to Week on that week — as a level change, not a
// push, so the level control always tells the truth about where you are.

/// One week: seven day rows at most — days after today are not listed.
struct WeekPage: View, Equatable {
    let context: HistoryPageContext
    let services: HistoryPageServices
    let lastDateKey: String

    @State private var period: HistoryPeriod<HistoryWeekRow>?

    nonisolated static func == (a: WeekPage, b: WeekPage) -> Bool {
        a.context == b.context && a.services === b.services && a.lastDateKey == b.lastDateKey
    }

    var body: some View {
        HistoryPageFrame(
            context: context, services: services,
            title: HistoryFormat.weekTitle(
                firstDateKey: context.page.key, lastDateKey: lastDateKey, todayKey: context.todayKey)
        ) {
            if let period {
                content(period)
                    .onAppear { HistoryPerformance.firstContent(context.page, isCurrent: context.isCurrent) }
            } else {
                PeriodLoadingFrame()
            }
        }
        .task(id: HistoryStreamKey(context)) {
            guard context.isNear else { return }
            let stream = services.source.week(firstDateKey: context.page.key, lastDateKey: lastDateKey)
            if context.isCurrent {
                for await next in stream where next != period { period = next }
            } else if period == nil {
                for await next in stream {
                    period = next
                    break
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ period: HistoryPeriod<HistoryWeekRow>) -> some View {
        PeriodBrief(
            title: Copy.History.weekInBrief, brief: period.brief,
            followUpTotal: period.followUpTotal, followUpOpen: period.followUpOpen,
            onFooterTap: { services.actions.openFollowUps(context.page.key) })
        .padding(.bottom, Tokens.blockGap)
        let rows = period.rows.filter { $0.dateKey <= context.todayKey }
        if !rows.isEmpty {
            ListCard {
                ForEach(rows) { row in
                    WeekDayRow(row: row) { services.drillDown(.day, row.dateKey) }
                }
            }
        }
    }
}

/// One month: a row per week that overlaps it — a week straddling two months is in both —
/// and none that starts after today.
struct MonthPage: View, Equatable {
    let context: HistoryPageContext
    let services: HistoryPageServices

    @State private var period: HistoryPeriod<HistoryMonthRow>?

    nonisolated static func == (a: MonthPage, b: MonthPage) -> Bool {
        a.context == b.context && a.services === b.services
    }

    var body: some View {
        HistoryPageFrame(
            context: context, services: services,
            title: HistoryFormat.monthTitle(context.page.key, todayKey: context.todayKey)
        ) {
            if let period {
                content(period)
                    .onAppear { HistoryPerformance.firstContent(context.page, isCurrent: context.isCurrent) }
            } else {
                PeriodLoadingFrame()
            }
        }
        .task(id: HistoryStreamKey(context)) {
            guard context.isNear else { return }
            let stream = services.source.month(containing: context.page.key)
            if context.isCurrent {
                for await next in stream where next != period { period = next }
            } else if period == nil {
                for await next in stream {
                    period = next
                    break
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ period: HistoryPeriod<HistoryMonthRow>) -> some View {
        PeriodBrief(
            title: Copy.History.monthInBrief, brief: period.brief,
            followUpTotal: period.followUpTotal, followUpOpen: period.followUpOpen,
            tagCounts: period.tagCounts,
            onFooterTap: { services.actions.openFollowUps(context.page.key) })
        .padding(.bottom, Tokens.blockGap)
        let rows = period.rows.filter { $0.firstDateKey <= context.todayKey }
        if !rows.isEmpty {
            ListCard {
                ForEach(rows) { row in
                    MonthWeekRow(row: row, todayKey: context.todayKey) {
                        services.drillDown(.week, row.firstDateKey)
                    }
                }
            }
        }
    }
}

/// The brief card of a week or a month (plan 5.2).
private struct PeriodBrief: View {
    let title: String
    let brief: HistoryBrief?
    let followUpTotal: Int
    let followUpOpen: Int
    var tagCounts: [HistoryTagCount] = []
    var onFooterTap: () -> Void

    var body: some View {
        BriefCard(
            title: title, text: brief?.text,
            footer: followUpTotal > 0
                ? Copy.History.followUpCount(total: followUpTotal, open: followUpOpen) : nil,
            tagCounts: tagCounts,
            onFooterTap: followUpTotal > 0 ? onFooterTap : nil)
    }
}

/// First load: the frame — an empty brief card and an empty list card — never a spinner.
private struct PeriodLoadingFrame: View {
    var body: some View {
        VStack(spacing: Tokens.blockGap) {
            RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(Tokens.surface).frame(height: 110)
            RoundedRectangle(cornerRadius: Tokens.cardRadius).fill(Tokens.surface).frame(height: 420)
        }
        .accessibilityHidden(true)
    }
}
