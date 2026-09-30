import AppDB
import SwiftUI

/// The end of today's timeline while recording (plan 5.3 "Today"): a white card with a 1.5 pt
/// green outline, "Recording now" and the green Live badge, "11:20 AM · 21 min so far", and the
/// last line of the live transcript in italics. It opens the Live screen.
///
/// The words come from the live snapshot the caller already has, never from a second walk of
/// the transcript (plan 7.10).
struct LiveChapterCard: View {
    let live: HistoryLiveBlock
    /// The last line heard, without quotes. Nil while nothing has been transcribed yet.
    var lastLine: String?
    var onOpen: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Copy.History.recordingNow)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 0)
                LiveBadge()
            }
            Text(HistoryLabels.liveTimeLine(live))
                .font(AppFont.timelineMeta)
                .foregroundStyle(Tokens.tertiary)
                .padding(.top, ChapterCardMetrics.titleToTime)
            if let lastLine, !lastLine.isEmpty {
                Text(Copy.History.liveQuote(lastLine))
                    .font(AppFont.historyBody(dynamicTypeSize))
                    .italic()
                    .foregroundStyle(Tokens.tertiary)
                    .lineSpacing(ChapterCard.summaryLineSpacing)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ChapterCardMetrics.timeToSummary)
            }
        }
        .padding(EdgeInsets(
            top: ChapterCardMetrics.paddingTop, leading: ChapterCardMetrics.paddingHorizontal,
            bottom: ChapterCardMetrics.paddingBottom, trailing: ChapterCardMetrics.paddingHorizontal))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius)
                .strokeBorder(Tokens.good, lineWidth: 1.5))
        .background(alignment: .leading) { TimelineTalkLine(color: Tokens.timelineLive) }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
    }

    private var accessibilityText: String {
        [Copy.History.recordingNow, Copy.Status.live, HistoryLabels.liveTimeLine(live), lastLine]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
