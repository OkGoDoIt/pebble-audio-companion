import SwiftUI

// MARK: - Layout roles

enum TimelineRole: Equatable, Sendable {
    case axis
    case item(TimelineSpan, floor: CGFloat)
    case mark(Int64)            // hour tick+label or the "now" marker, centred on its instant
}

struct TimelineRoleKey: LayoutValueKey {
    static let defaultValue: TimelineRole = .axis
}

extension View {
    func timelineRole(_ role: TimelineRole) -> some View { layoutValue(key: TimelineRoleKey.self, value: role) }
}

/// One pass: items stacked with min heights, then axis + marks placed from the item frames.
struct DayTimelineLayout: Layout {
    var spacing: CGFloat = 6
    var gutterWidth: CGFloat = 58
    var axisX: CGFloat = 50

    struct Cache { var width: CGFloat = -1; var heights: [CGFloat] = [] }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
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
        let heights = itemHeights(width: width, subviews: subviews, cache: &cache).filter { $0 >= 0 }
        let total = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
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
                // Marks are trailing-aligned to the axis; their instant is their vertical centre.
                if let my = TimelineGeometry.y(for: ms, spans: spans, frames: frames) {
                    sub.place(at: CGPoint(x: bounds.minX + axisX + 5, y: my), anchor: .trailing,
                              proposal: .unspecified)
                }
            case .item: break
            }
        }
    }
}

// MARK: - Elastic chapter card: proposes the soft max to its child, reports the child unclamped

/// `.frame(maxHeight:)` would clamp the reported size and overlap the next item when even the
/// last candidate overflows (Dynamic Type); this reports the true size so the cap yields.
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
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func content(summaryLines: Int, collapseFollowUps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
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

// MARK: - Pinned gap label

struct GapLabelPin: ViewModifier {
    nonisolated static let space = "timeline.gap"
    /// Top/bottom insets of the vertical scroll view (nav bar + safeAreaBar, floating tab bar),
    /// read once per change via onScrollGeometryChange — not per frame.
    var insets: EdgeInsets

    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            let local = proxy.size.height
            let gap = proxy.bounds(of: .named(Self.space)) ?? .zero
            let viewport = proxy.bounds(of: .scrollView(axis: .vertical)) ?? gap
            let visible = CGRect(x: viewport.minX, y: viewport.minY + insets.top,
                                 width: viewport.width,
                                 height: max(0, viewport.height - insets.top - insets.bottom))
            return effect.offset(y: TimelineGeometry.pinOffset(labelHeight: local, gap: gap, visible: visible))
        }
    }
}

struct GapRowSketch: View {
    var label: String
    var span: TimelineSpan
    var insets: EdgeInsets
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: TimelineGeometry.minHeight(for: span, floor: 44))
            .overlay(alignment: .leading) {
                Text(label).font(.caption).modifier(GapLabelPin(insets: insets))
            }
            .coordinateSpace(.named(GapLabelPin.space))
            .accessibilityElement(children: .combine)
    }
}

struct DayTimelineSketch: View {
    var items: [(TimelineSpan, Bool)]
    var marks: [Int64]
    var insets: EdgeInsets
    var body: some View {
        DayTimelineLayout {
            Rectangle().fill(.gray.opacity(0.3)).timelineRole(.axis).accessibilityHidden(true)
            ForEach(items.indices, id: \.self) { i in
                let (span, isGap) = items[i]
                Group {
                    if isGap {
                        GapRowSketch(label: "Quiet · 1 hr 5 min", span: span, insets: insets)
                    } else {
                        ChapterCardSketch(title: "T", timeLine: "9:05 – 10:15 AM", summary: "S",
                                          followUps: [], span: span)
                            .padding(.leading, 58)
                    }
                }
                .timelineRole(.item(span, floor: isGap ? 8 : 0))
            }
            ForEach(marks, id: \.self) { ms in
                Text(Date(timeIntervalSince1970: Double(ms) / 1000), format: .dateTime.hour())
                    .font(.caption).timelineRole(.mark(ms)).accessibilityHidden(true)
            }
        }
    }
}
