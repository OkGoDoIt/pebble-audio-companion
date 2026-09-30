import AppDB
import SwiftUI

/// Recorded time with no transcript to show (plan 5.3 "Gap kinds", 5.8): a dashed-outline card
/// on the bare axis, gray title "Not transcribed yet" or "Could not be transcribed", and the time
/// range with the length or the recorded reason. It opens the recording.
struct PendingChapterCard: View {
    let gap: HistoryGap
    var onOpen: () -> Void = {}

    var body: some View {
        let text = HistoryLabels.gapText(gap)
        VStack(alignment: .leading, spacing: ChapterCardMetrics.titleToTime) {
            Text(text.title ?? "")
                .font(AppFont.pendingTitle)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = text.detail {
                Text(detail)
                    .font(AppFont.timelineMeta)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(
            top: ChapterCardMetrics.paddingTop, leading: ChapterCardMetrics.paddingHorizontal,
            bottom: ChapterCardMetrics.paddingBottom, trailing: ChapterCardMetrics.paddingHorizontal))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius)
                .strokeBorder(Tokens.pendingOutline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .onTapGesture { if gap.isOpenable { onOpen() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryLabels.gapAccessibilityLabel(gap))
        .accessibilityAddTraits(gap.isOpenable ? .isButton : [])
        .accessibilityHint(gap.isOpenable ? Copy.History.A11y.openRecordingHint : "")
    }
}
