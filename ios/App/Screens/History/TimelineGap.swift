import AppDB
import SwiftUI

// Time on the day that is not a card (plan 5.3 "Gap kinds").
//
// | Kind              | On the axis                          | Label                         |
// |-------------------|--------------------------------------|-------------------------------|
// | quiet             | bare line                            | faint, ≥ 30 min; range > 90   |
// | paused            | tint diagonal stripes, 5 pt          | tint; range · who paused      |
// | audio missing     | solid amber, 5 pt                    | amber; range · recorded cause |
// | not recording     | the axis breaks into dashes          | gray; range                   |
// | no conversation   | soft gray bar WITH a descriptor,     | "Background audio" + chevron; |
// |                   | bare line without one                | without: like quiet + chevron |
// | deleted           | the axis breaks into dashes          | gray; range                   |
//
// (Not transcribed yet / could not be transcribed are `PendingChapterCard`s.)
//
// The label rests in the middle of the gap and is pinned at both edges while scrolling
// (`GapLabelPin`), so a tall gap never scrolls its words off screen while it is on screen.

struct TimelineGap: View {
    let gap: HistoryGap
    /// A gap at the end of today that is still going ("Paused since 2:30 PM").
    var openEnded = false
    var onOpen: () -> Void = {}

    var body: some View {
        let text = HistoryLabels.gapText(gap, openEnded: openEnded)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
            if let title = text.title {
                label(title: title, detail: text.detail)
                    .modifier(GapLabelPin())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(GapLabelPin.space))
        .background(alignment: .leading) { axisTreatment }
        .contentShape(Rectangle())
        .onTapGesture { if isTappable { onOpen() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryLabels.gapAccessibilityLabel(gap, openEnded: openEnded))
        .accessibilityAddTraits(isTappable ? .isButton : [])
        .accessibilityHint(isTappable ? Copy.History.A11y.openHint : "")
    }

    /// Only a stretch of sound with no conversation opens: there is audio behind it.
    private var isTappable: Bool { gap.kind == .noConversation && gap.isOpenable }

    private func label(title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(titleColor)
                if let detail {
                    Text(detail)
                        .foregroundStyle(Tokens.meta)
                }
            }
            .font(AppFont.timelineMeta)
            .fixedSize(horizontal: false, vertical: true)
            if gap.kind == .noConversation && gap.isOpenable {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Tokens.Timeline.labelInset)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    private var titleColor: Color {
        switch gap.kind {
        case .quiet: return Tokens.faint
        case .paused: return Tokens.tint
        case .audioMissing: return Tokens.missingText
        case .noConversation: return gap.descriptor == nil ? Tokens.meta : Tokens.tertiary
        case .notRecording, .deleted, .notTranscribedYet, .transcriptionFailed: return Tokens.meta
        }
    }

    // MARK: On the axis

    /// The bar's leading x, relative to the content column, so it is centred on the axis.
    private static var barX: CGFloat {
        let axisCentre = Tokens.Timeline.axisX + Tokens.Timeline.axisWidth / 2
        return axisCentre - Tokens.Timeline.gutter - Tokens.Timeline.barWidth / 2
    }

    @ViewBuilder
    private var axisTreatment: some View {
        switch gap.kind {
        case .paused:
            bar {
                ZStack {
                    Tokens.pausedStripeGround
                    DiagonalStripes(spacing: 4)
                        .stroke(Tokens.tint, lineWidth: 1.5)
                }
            }
        case .audioMissing:
            bar { Tokens.missing }
        case .noConversation where gap.descriptor != nil:
            bar { Tokens.backgroundAudioBar }
        case .notRecording, .deleted:
            BrokenAxis()
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .offset(x: Tokens.Timeline.axisX - Tokens.Timeline.gutter - (4 - Tokens.Timeline.axisWidth) / 2)
        case .quiet, .noConversation, .notTranscribedYet, .transcriptionFailed:
            EmptyView()
        }
    }

    private func bar<Fill: View>(@ViewBuilder _ fill: () -> Fill) -> some View {
        fill()
            .frame(width: Tokens.Timeline.barWidth)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Timeline.barWidth / 2))
            .padding(.vertical, 2)
            .offset(x: Self.barX)
            .accessibilityHidden(true)
    }
}

/// Where the axis breaks into dashes: nothing was recording, or the audio was deleted. Covers
/// the solid axis with the ground colour, then draws it dashed.
struct BrokenAxis: View {
    var body: some View {
        ZStack {
            Tokens.ground
            DashedAxis()
        }
        .accessibilityHidden(true)
    }
}

/// A 1.5 pt dashed vertical line, centred in its frame — the axis where time is not drawn to
/// scale (the day's two ends) or where nothing was recording.
struct DashedAxis: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .stroke(
                Tokens.timelineAxis,
                style: StrokeStyle(lineWidth: Tokens.Timeline.axisWidth, dash: [4, 4]))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pinned label

/// Keeps a gap's label on screen while any usable part of its gap is (plan 5.3 "Label
/// position"). `.scrollView(axis: .vertical)` names the day page's own scroll view, skipping the
/// horizontal pager, and its bounds already exclude the bars (spike), so nothing is inset here.
/// Pure position, not animation: it tracks under Reduce Motion too.
struct GapLabelPin: ViewModifier {
    nonisolated static let space = "history.timeline.gap"

    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            let gap = proxy.bounds(of: .named(Self.space)) ?? .zero
            let visible = proxy.bounds(of: .scrollView(axis: .vertical)) ?? gap
            return effect.offset(y: TimelineGeometry.pinOffset(
                labelHeight: proxy.size.height, gap: gap, visible: visible))
        }
    }
}

// MARK: - Zone change

/// A change of time zone inside the day: a thin divider across the content column, "Times from
/// here in Jakarta time". Hour labels below it use the new zone.
struct ZoneChangeDivider: View {
    let change: HistoryZoneChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
            Text(Copy.History.zoneChange(Copy.History.place(ofZone: change.zoneID)))
                .font(AppFont.timelineMeta)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Tokens.Timeline.labelInset)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
