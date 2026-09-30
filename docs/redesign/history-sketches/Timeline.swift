import SwiftUI

// Corrected after the 2026-09-30 simulator spike. Changes vs. the sketch are marked `SPIKE:`.

enum TimelineRole: Equatable, Sendable {
    case axis
    case item(TimelineSpan, floor: CGFloat)
    case mark(Int64)
}

struct TimelineRoleKey: LayoutValueKey {
    static let defaultValue: TimelineRole = .axis
}

extension View {
    func timelineRole(_ role: TimelineRole) -> some View { layoutValue(key: TimelineRoleKey.self, value: role) }
}

struct DayTimelineLayout: Layout {
    var spacing: CGFloat = 6
    var gutterWidth: CGFloat = 58
    var axisX: CGFloat = 50

    struct Cache { var width: CGFloat = -1; var heights: [CGFloat] = [] }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    // Called on every update of the parent body (any @State write on the page), and each
    // re-measure after it cost 13-15 ms in the spike (vs ~100 ms cold). So: do not write page
    // state that nothing needs (the sketch's `insets` state was one such write).
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func itemHeights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.width == width { return cache.heights }
        let heights: [CGFloat] = subviews.map { sub in
            guard case .item(let span, let floor) = sub[TimelineRoleKey.self] else { return -1 }
            let ideal = sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return max(ideal, TimelineGeometry.minHeight(for: span, floor: floor))
        }
        cache = Cache(width: width, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 360
        // SPIKE: a non-lazy HStack pager proposed width 0 and then 58 before the real width; each
        // degenerate pass measured all 25 cards (~120 ms at width 0). Don't measure children for
        // a width the content column cannot have.
        guard width > gutterWidth + 44 else { return CGSize(width: width, height: 0) }
        let heights = itemHeights(width: width, subviews: subviews, cache: &cache).filter { $0 >= 0 }
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard bounds.width > gutterWidth + 44 else { return }
        let heights = itemHeights(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        var spans: [TimelineSpan] = []
        var frames: [ClosedRange<CGFloat>] = []
        for (index, sub) in subviews.enumerated() {
            guard case .item(let span, _) = sub[TimelineRoleKey.self] else { continue }
            let h = heights[index]
            sub.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            spans.append(span); frames.append(y...(y + h))
            y += h + spacing
        }
        for sub in subviews {
            switch sub[TimelineRoleKey.self] {
            case .axis:
                sub.place(at: CGPoint(x: bounds.minX + axisX, y: bounds.minY), anchor: .top,
                          proposal: ProposedViewSize(width: 1.5, height: bounds.height))
            case .mark(let ms):
                if let my = TimelineGeometry.y(for: ms, spans: spans, frames: frames) {
                    // SPIKE: propose the gutter width instead of `.unspecified`. At AX5 text the
                    // unconstrained "6 AM" was wider than the gutter and ran off the leading edge
                    // (shots/q10-day-AX5-text-size-scrolled.png). HourMark scales down to fit.
                    sub.place(at: CGPoint(x: bounds.minX + axisX + 5, y: my), anchor: .trailing,
                              proposal: ProposedViewSize(width: axisX + 5, height: nil))
                }
            case .item: break
            }
        }
    }
}

/// Unchanged from the sketch; behaved as designed (the card grows past the band when even the
/// last candidate overflows, e.g. a 50-min chapter with 3 follow-ups: 158 pt vs 150 pt band).
struct ProposeHeight: Layout {
    var height: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
    }
}

// MARK: - Pinned gap label

struct GapLabelPin: ViewModifier {
    nonisolated static let space = "timeline.gap"
    /// SPIKE: no `insets` parameter. `bounds(of: .scrollView(axis: .vertical))` already excludes
    /// the nav bar + safeAreaBar (151 pt) and the tab bar (83 pt). The sketch's subtraction made
    /// the visible band 406 pt instead of 640 pt and pinned the label 151 pt below the bar.
    /// Dropping it also removes the page's `onScrollGeometryChange(contentInsets)` → @State write.
    var margin: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = self.margin
        return content.visualEffect { effect, proxy in
            let gap = proxy.bounds(of: .named(Self.space)) ?? .zero
            let visible = proxy.bounds(of: .scrollView(axis: .vertical)) ?? gap
            return effect.offset(y: TimelineGeometry.pinOffset(
                labelHeight: proxy.size.height, gap: gap, visible: visible, margin: margin))
        }
    }
}

struct GapRow: View {
    var title: String?
    var detail: String?
    var span: TimelineSpan

    var body: some View {
        // SPIKE: floor depends on whether the gap is labelled (sketch always used 44).
        let floor = title == nil ? TimelineScale.quietGapFloor : TimelineScale.labelledGapFloor
        Color.clear
            .frame(maxWidth: .infinity, minHeight: TimelineGeometry.minHeight(for: span, floor: floor))
            .overlay(alignment: .leading) {
                if let title {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.caption)
                        if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                    // SPIKE: the gap row spans the gutter too; without this the label sat on the
                    // hour labels. 58 gutter + 8 = aligned with the card content column.
                    .padding(.leading, 66)
                    .modifier(GapLabelPin())
                }
            }
            .coordinateSpace(.named(GapLabelPin.space))
            .accessibilityElement(children: .combine)
    }
}

struct HourMark: View {
    var ms: Int64
    var body: some View {
        HStack(spacing: 3) {
            Text(Date(timeIntervalSince1970: Double(ms) / 1000), format: .dateTime.hour())
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.5)          // SPIKE: fits the gutter at AX sizes
            Rectangle().fill(.secondary).frame(width: 7, height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Pills: SPIKE: `.fixedSize()` — at AX5 "Oliver" broke inside its pill ("Oli/ver").
struct Pill: View {
    var text: String
    var person: Bool
    var body: some View {
        HStack(spacing: 3) {
            if person { Image(systemName: "person") }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .fixedSize()
    }
}

/// Chapter card. The ViewThatFits approach WORKS visually but costs ~90-120 ms per 25-card page
/// on the first layout (simulator, Debug and Release alike) vs 14-21 ms with one candidate.
/// Keep this shape only until the computed-line-count fallback (plan 7.12) is in.
struct ChapterCardSketch: View {
    var title: String
    var timeLine: String
    var summary: String?
    var followUps: [String]
    var span: TimelineSpan
    @ScaledMetric(relativeTo: .subheadline) private var typeScale: CGFloat = 1

    var body: some View {
        ProposeHeight(height: TimelineGeometry.softMaxHeight(for: span, dynamicTypeScale: typeScale)) {
            ViewThatFits(in: .vertical) {
                ForEach([7, 6, 5, 4, 3, 2, 1], id: \.self) { lines in
                    content(summaryLines: lines, collapseFollowUps: false)
                }
                content(summaryLines: 1, collapseFollowUps: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func content(summaryLines: Int, collapseFollowUps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(timeLine).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let summary, span.minutes >= CGFloat(TimelineScale.noSummaryUnderMinutes) {
                Text(summary).font(.subheadline).lineLimit(summaryLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(collapseFollowUps ? Array(followUps.prefix(1)) : followUps, id: \.self) {
                Text($0).lineLimit(1)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 11, trailing: 13))
    }
}
