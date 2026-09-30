import AppDB
import SwiftUI

/// One day on the week page (plan 5.4): the date column, the day's headline, a two-line
/// summary, up to three topic pills, up to two follow-ups with "N more", and a chevron. The
/// whole row opens the day. No coverage strip and no loss note: loss is shown on the day.
struct WeekDayRow: View {
    let row: HistoryWeekRow
    var onOpen: () -> Void = {}
    /// A topic pill's results (plan 5.7). Nil: the pills do nothing.
    var onOpenTag: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // A tap gesture, not a Button: the topic pills inside the row are a menu of their own,
        // and a control inside a Button's label never receives its taps.
        if isOpenable {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onOpen)
                .accessibilityHint(Copy.History.A11y.openDayHint)
        } else {
            content
        }
    }

    private var isOpenable: Bool { row.state != .nothingRecorded }
    private var isToday: Bool { if case .today = row.state { return true } else { return false } }

    private var content: some View {
        HStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                dateColumn
                details
            }
            if isOpenable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            if let summary = summaryText {
                Text(summary)
                    .font(AppFont.scaled(13, relativeTo: .footnote, dynamicTypeSize))
                    .foregroundStyle(Tokens.tertiary)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if !row.tags.isEmpty {
                TagPillRow(topics: Array(row.tags.prefix(3)), onSelect: onOpenTag)
                .padding(.top, 8)
            }
            if !row.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(row.followUps.prefix(2)) { FollowUpLine($0, size: .row) }
                    if row.moreFollowUps > 0 {
                        Text(Copy.History.more(row.moreFollowUps))
                            .font(AppFont.timelineMeta)
                            .foregroundStyle(Tokens.meta)
                            .padding(.leading, 21)
                            .padding(.top, 1)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateColumn: some View {
        let parts = HistoryFormat.weekdayAndNumber(row.dateKey)
        return VStack(spacing: 0) {
            Text(parts.weekday)
                .font(AppFont.micro)
                .foregroundStyle(Tokens.meta)
            Text(parts.number)
                .font(AppFont.dayNumeral)
                .foregroundStyle(isToday ? Tokens.tint : Tokens.label)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: 34)
    }

    @ViewBuilder
    private var headline: some View {
        switch row.state {
        case .nothingRecorded:
            Text(Copy.History.nothingRecorded)
                .font(AppFont.pendingTitle).foregroundStyle(Tokens.meta)
        case .notTranscribedYet:
            Text(Copy.History.notTranscribedYet)
                .font(AppFont.pendingTitle).foregroundStyle(Tokens.meta)
        case .today:
            Text(Copy.History.today)
                .font(AppFont.rowTitle).foregroundStyle(Tokens.tint)
        case .recorded:
            if let headline = row.headline {
                Text(headline)
                    .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                    .lineLimit(1)
            } else {
                Text(Copy.History.noSummaryYet)
                    .font(AppFont.pendingTitle).foregroundStyle(Tokens.meta)
            }
        }
    }

    private var summaryText: String? {
        switch row.state {
        case .nothingRecorded: return nil
        case .notTranscribedYet(let waitingMs):
            return Copy.History.waitingToTranscribe(HistoryFormat.duration(ms: waitingMs))
        case .today, .recorded: return row.summary
        }
    }
}
