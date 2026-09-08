import SwiftUI

/// The growing timeline at the top of a live conversation: how much has actually been captured
/// so far, where it broke, and the two clock anchors it runs between.
///
/// It is the same `CoverageStrip` Today draws the day with, over the conversation's own span —
/// see `LiveTimeline` for why a coverage strip and not the finished screen's scrubber. Loss is
/// drawn amber AND named in words, because a gap that only exists as three pixels of colour is
/// not an explicit gap.
struct LiveTimelineCard: View {
    let timeline: LiveTimelineDisplay

    /// Q11's explain-on-tap: one line, auto-dismissing. Same behaviour as Today's day strip —
    /// on a live recording the question "what just happened there?" is asked about the amber
    /// tick more than anywhere else in the app.
    @State private var poppedSpan: CoverageSpanDisplay?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // Side by side while both fit; stacked once Dynamic Type would hyphenate the
                // headline into fragments (the same trade Today's coverage card makes).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headline
                        Spacer()
                        missingNote
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        headline
                        missingNote
                    }
                }
                CoverageStrip(
                    spans: timeline.stripSpans,
                    // The strip's own axis is the 5 AM → 5 AM day; this domain is one
                    // conversation, so its anchors are drawn below instead.
                    showAxis: false,
                    accessibilityName: Copy.A11y.liveTimelineLabel,
                    accessibilityHint: Copy.A11y.liveTimelineHint
                ) { tapped in
                    guard let hit = timeline.spans.first(where: { $0.span == tapped }),
                        hit.popoverText != nil
                    else { return }
                    poppedSpan = hit
                }
                .popover(item: $poppedSpan) { span in
                    Text(span.popoverText ?? "")
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .presentationCompactAdaptation(.popover)
                        .task {
                            try? await Task.sleep(for: .seconds(2.5))
                            poppedSpan = nil
                        }
                }
                axis
            }
        }
    }

    private var headline: some View {
        Text(timeline.headline)
            .font(AppFont.cardHead)
            .foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var missingNote: some View {
        if let missingText = timeline.missingText {
            Text(missingText)
                .font(AppFont.speaker)
                .foregroundStyle(Tokens.missing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Start on the left, "now" on the right — which is what says the strip grows rightwards
    /// rather than being a finished bar you can scrub.
    private var axis: some View {
        HStack {
            Text(timeline.startLabel)
            Spacer(minLength: 8)
            Text(Copy.Live.timelineNow)
        }
        .font(AppFont.micro)
        .foregroundStyle(Tokens.faint)
        .accessibilityHidden(true)
    }
}

#Preview("Live timeline") {
    VStack(spacing: Tokens.blockGap) {
        LiveTimelineCard(timeline: .demo)
        LiveTimelineCard(
            timeline: LiveTimelineDisplay(
                headline: Copy.Today.recorded("4 min"),
                missingText: nil,
                startLabel: "8:41 AM",
                spans: [
                    CoverageSpanDisplay(
                        span: CoverageSpan(kind: .recorded, range: 0...1), popoverText: nil)
                ]))
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
