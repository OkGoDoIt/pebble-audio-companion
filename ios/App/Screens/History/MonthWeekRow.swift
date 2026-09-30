import AppDB
import SwiftUI

/// One week on the month page (plan 5.5): "Sep 20 – 26 · This week", the week's headline, a
/// two-line summary, up to three topic pills, one gray follow-up line, and a chevron. The row
/// opens that week.
struct MonthWeekRow: View {
    let row: HistoryMonthRow
    let todayKey: String
    var onOpen: () -> Void = {}
    /// A topic pill's results (plan 5.7). Nil: the pills do nothing.
    var onOpenTag: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // A tap gesture, not a Button: the topic pills inside the row are a menu of their own,
        // and a control inside a Button's label never receives its taps.
        if row.hasRecordings {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onOpen)
                .accessibilityHint(Copy.History.A11y.openWeekHint)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                rangeLine
                if let headline = row.headline {
                    Text(headline)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(1)
                        .padding(.top, 2)
                } else if row.hasRecordings {
                    // "No summary yet" only where there is no text at all. A week with a line and
                    // no headline shows the line; the placeholder above real text read as if the
                    // text below it were not a summary.
                    if row.summary == nil {
                        Text(Copy.History.noSummaryYet)
                            .font(AppFont.pendingTitle)
                            .foregroundStyle(Tokens.meta)
                            .padding(.top, 2)
                    }
                } else {
                    Text(Copy.History.nothingRecorded)
                        .font(AppFont.pendingTitle)
                        .foregroundStyle(Tokens.meta)
                        .padding(.top, 2)
                }
                if let summary = row.summary {
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
                if row.followUpTotal > 0 {
                    HStack(spacing: 6) {
                        // Checked only when every one is done; an open one reads as open.
                        Image(systemName: row.followUpOpen == 0 ? "checkmark.circle" : "circle")
                            .font(AppFont.scaled(14, relativeTo: .footnote, dynamicTypeSize))
                            .accessibilityHidden(true)
                        Text(Copy.History.followUpCount(total: row.followUpTotal, open: row.followUpOpen))
                            .font(AppFont.scaled(13, relativeTo: .footnote, dynamicTypeSize))
                    }
                    .foregroundStyle(Tokens.meta)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.hasRecordings {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rangeLine: some View {
        let range = HistoryFormat.weekTitle(
            firstDateKey: row.firstDateKey, lastDateKey: row.lastDateKey, todayKey: todayKey)
        return Group {
            if row.isCurrentWeek {
                Text("\(range) · \(Text(Copy.History.thisWeek).foregroundStyle(Tokens.tint))")
            } else {
                Text(range)
            }
        }
        .font(AppFont.timelineMeta)
        .foregroundStyle(Tokens.meta)
    }
}
