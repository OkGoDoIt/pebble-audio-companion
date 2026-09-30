import AppDB
import OSLog
import QuartzCore
import SwiftUI

// The day timeline (plan 5.3 "Layout", 7.12 "The day timeline").
//
// One `Layout` places everything: the items stacked in the content column 6 pt apart, each at
// least `minutes × pointsPerMinute` tall; the axis down the gutter; and each hour label (and
// today's "now") at the y interpolated along the item that holds its instant. The whole gutter
// comes out of one layout pass — no preference keys, no second pass, no scroll-offset state.

enum TimelineRole: Equatable, Sendable {
    case axis
    /// An item, and the least it may be besides its duration on the scale. `isCard` items are
    /// drawn surfaces (chapters, the Live card, pending cards); two of them in a row are kept
    /// `spacing` apart, because consecutive chapters touch in time and would read as one. A gap
    /// is empty space already, so nothing is added beside one: a 5-minute quiet between two
    /// cards is its 8 pt floor, as drawn in the mockups.
    case item(TimelineSpan, floor: CGFloat, isCard: Bool)
    /// An instant on the axis: an hour label or the "now" marker.
    case mark(Int64)
}

struct TimelineRoleKey: LayoutValueKey {
    static let defaultValue: TimelineRole = .axis
}

extension View {
    func timelineRole(_ role: TimelineRole) -> some View {
        layoutValue(key: TimelineRoleKey.self, value: role)
    }
}

struct DayTimelineLayout: Layout {
    var pointsPerMinute: CGFloat = TimelineScale.pointsPerMinute
    var spacing: CGFloat = Tokens.Timeline.itemSpacing
    var gutter: CGFloat = Tokens.Timeline.gutter
    var axisX: CGFloat = Tokens.Timeline.axisX
    /// DEBUG `-historyScaleLog`: the zone to read hours in when logging the rendered scale.
    var scaleLogZoneID: String?

    struct Cache {
        var width: CGFloat = -1
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    // Called on every update of the parent's body. Re-measuring costs ~15 ms on a full day
    // (spike), so the page must not write state nothing needs.
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func itemHeights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.width == width, cache.heights.count == subviews.count { return cache.heights }
        let interval = HistoryPerformance.signposter.beginInterval("day timeline measure")
        let started = ContinuousClock.now
        defer {
            HistoryPerformance.signposter.endInterval("day timeline measure", interval)
            HistoryPerformance.reportMeasure(ContinuousClock.now - started, items: subviews.count)
        }
        let column = ProposedViewSize(width: width - gutter, height: nil)
        let heights: [CGFloat] = subviews.map { sub in
            guard case .item(let span, let floor, _) = sub[TimelineRoleKey.self] else { return -1 }
            let ideal = sub.sizeThatFits(column).height
            let scaled = span.minutes > 0 ? (span.minutes * pointsPerMinute).rounded() : 0
            return max(ideal, scaled, floor)
        }
        cache = Cache(width: width, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 360
        // Spike: a pager can propose widths of 0 and then 58 before the real one; measuring 25
        // cards at a width the column can never have cost ~120 ms. Don't.
        guard width > gutter + 44 else { return CGSize(width: width, height: 0) }
        let heights = itemHeights(width: width, subviews: subviews, cache: &cache).filter { $0 >= 0 }
        let total = heights.reduce(0, +) + spacingBefore(subviews).reduce(0, +)
        return CGSize(width: width, height: total)
    }

    /// The space before each item, in item order: `spacing` between two cards, else none.
    private func spacingBefore(_ subviews: Subviews) -> [CGFloat] {
        var result: [CGFloat] = []
        var previousIsCard: Bool?
        for sub in subviews {
            guard case .item(_, _, let isCard) = sub[TimelineRoleKey.self] else { continue }
            result.append(previousIsCard == true && isCard ? spacing : 0)
            previousIsCard = isCard
        }
        return result
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        guard bounds.width > gutter + 44 else { return }
        let heights = itemHeights(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        var spans: [TimelineSpan] = []
        var frames: [ClosedRange<CGFloat>] = []
        var spacings = spacingBefore(subviews).makeIterator()
        for (index, sub) in subviews.enumerated() {
            guard case .item(let span, _, _) = sub[TimelineRoleKey.self] else { continue }
            y += spacings.next() ?? 0
            let h = heights[index]
            sub.place(
                at: CGPoint(x: bounds.minX + gutter, y: y),
                proposal: ProposedViewSize(width: bounds.width - gutter, height: h))
            spans.append(span)
            frames.append(y...(y + h))
            y += h
        }
        #if DEBUG
        if let scaleLogZoneID {
            let parts = scaleLogZoneID.split(separator: "|").map(String.init)
            HistoryPerformance.logScale(spans: spans, frames: frames, zoneID: parts[1], day: parts[0])
        }
        #endif
        let markWidth = Tokens.Timeline.tickX + Tokens.Timeline.tickWidth
        for sub in subviews {
            switch sub[TimelineRoleKey.self] {
            case .axis:
                sub.place(
                    at: CGPoint(x: bounds.minX + axisX, y: bounds.minY),
                    proposal: ProposedViewSize(width: Tokens.Timeline.axisWidth, height: bounds.height))
            case .mark(let ms):
                if let markY = TimelineGeometry.y(for: ms, spans: spans, frames: frames) {
                    // The gutter's width is proposed, not `.unspecified`: at AX5 an unconstrained
                    // "10 AM" ran off the leading edge in the spike. `HourMark` scales down.
                    sub.place(
                        at: CGPoint(x: bounds.minX, y: markY), anchor: .leading,
                        proposal: ProposedViewSize(width: markWidth, height: nil))
                } else {
                    sub.place(at: .zero, proposal: .zero)
                }
            case .item:
                break
            }
        }
    }
}

// MARK: - Performance

/// The day's measurement is the cost the spike budgeted (13–21 ms for a 25-card day; plan
/// 7.12). It is an Instruments interval ("History" › "day timeline measure"), and in DEBUG a
/// console line, so a regression shows up without a profiler.
enum HistoryPerformance {
    static let signposter = OSSignposter(subsystem: "dev.audiocompanion.app", category: "History")

    /// When the History tab was selected (or the screen first appeared), for "tab to first
    /// content" (plan 7.13: under 150 ms).
    @MainActor static var shownAt: ContinuousClock.Instant?

    @MainActor static func markShown() {
        shownAt = ContinuousClock.now
        signposter.emitEvent("history shown")
    }

    /// The visible page's content has appeared: logs the time since `markShown`, once.
    @MainActor static func firstContent(_ page: HistoryPageID, isCurrent: Bool) {
        guard isCurrent, let shownAt else { return }
        self.shownAt = nil
        signposter.emitEvent("history first content")
        #if DEBUG
        let elapsed = ContinuousClock.now - shownAt
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print(String(format: "[history] first content (%@) %.1f ms after the tab was shown", page.id, ms))
        #endif
    }

    #if DEBUG
    /// DEBUG `-historyHitchLog`: logs every display frame that took more than 1.5 frames, to
    /// check paging to an unbuilt neighbour (plan 7.13: a swipe never drops a frame).
    @MainActor static func startHitchLogIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-historyHitchLog"), hitchMonitor == nil
        else { return }
        let monitor = HitchMonitor()
        monitor.start()
        hitchMonitor = monitor
    }

    @MainActor private static var hitchMonitor: HitchMonitor?

    @MainActor private final class HitchMonitor: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { last = link.timestamp }
            guard last > 0 else { return }
            let expected = link.targetTimestamp - link.timestamp
            let delta = link.timestamp - last
            if expected > 0, delta > expected * 1.5 {
                print(String(format: "[history] %.3f slow frame %.1f ms (expected %.1f)", CACurrentMediaTime(), delta * 1000, expected * 1000))
            }
        }
    }
    #endif

    /// DEBUG: a timestamped line in the hitch log, to place a slow frame against what happened.
    static func mark(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-historyHitchLog") {
            print(String(format: "[history] %.3f %@", CACurrentMediaTime(), event))
        }
        #endif
    }

    #if DEBUG
    nonisolated(unsafe) private static var loggedScales: Set<String> = []

    /// DEBUG `-historyScaleLog`: the rendered height of every clock hour of the day, once per
    /// day and width, with min / median / max and the timeline's total height.
    static func logScale(spans: [TimelineSpan], frames: [ClosedRange<CGFloat>], zoneID: String, day: String) {
        guard ProcessInfo.processInfo.arguments.contains("-historyScaleLog"),
            let first = spans.first, let last = spans.last, let top = frames.first, let bottom = frames.last
        else { return }
        let key = "\(first.startMs)-\(spans.count)-\(Int(bottom.upperBound))"
        guard loggedScales.insert(key).inserted else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID) ?? .current
        let start = Date(timeIntervalSince1970: Double(first.startMs) / 1000)
        guard var hour = calendar.dateInterval(of: .hour, for: start)?.start else { return }
        var heights: [(String, CGFloat)] = []
        while true {
            let next = calendar.date(byAdding: .hour, value: 1, to: hour)!
            let a = max(Int64(hour.timeIntervalSince1970 * 1000), first.startMs)
            let b = min(Int64(next.timeIntervalSince1970 * 1000), last.endMs)
            if a >= last.endMs { break }
            if let ya = TimelineGeometry.y(for: a, spans: spans, frames: frames),
                let yb = TimelineGeometry.y(for: b, spans: spans, frames: frames),
                b - a == 3_600_000
            {
                let label = HistoryFormat.hourLabel(Int64(hour.timeIntervalSince1970 * 1000), zone: calendar.timeZone)
                heights.append((label, yb - ya))
            }
            hour = next
        }
        let sorted = heights.map(\.1).sorted()
        let total = bottom.upperBound - top.lowerBound
        print("[history-scale] \(day) hour heights (pt): " + heights.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " "))
        if !sorted.isEmpty {
            print(String(format: "[history-scale] \(day) full hours %d  min %.0f  median %.0f  max %.0f  timeline %.0f pt = %.1f screens of 640 pt",
                         sorted.count, sorted.first!, sorted[sorted.count / 2], sorted.last!, total, total / 640))
        }
    }
    #endif

    static func reportMeasure(_ elapsed: Duration, items: Int) {
        #if DEBUG
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print(String(format: "[history] %.3f day timeline measured %d views in %.1f ms", CACurrentMediaTime(), items, ms))
        #endif
    }
}

// MARK: - Axis marks

/// An hour on the axis: "9 AM", right-aligned in the gutter, and a short tick across the axis.
/// Hidden from VoiceOver: every item says its own times.
struct HourMark: View {
    let text: String
    var isNow = false

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(isNow ? AppFont.nowMarker : AppFont.hourLabel)
                .foregroundStyle(isNow ? Tokens.nowMarker : Tokens.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // Hour labels stop growing at the second accessibility size so the gutter
                // keeps its width (plan 5.9).
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(width: Tokens.Timeline.hourLabelTrailing, alignment: .trailing)
            Spacer(minLength: 0)
                .frame(width: Tokens.Timeline.tickX - Tokens.Timeline.hourLabelTrailing)
            Rectangle()
                .fill(isNow ? Tokens.good : Tokens.timelineTick)
                .frame(width: Tokens.Timeline.tickWidth, height: isNow ? 2 : 1.5)
        }
        .accessibilityHidden(true)
    }
}

/// The solid axis through the timeline.
struct TimelineAxis: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.timelineAxis)
            .frame(width: Tokens.Timeline.axisWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// One line at each end of the day, on a dashed axis: "Quiet until 8:12 AM", "Quiet after
/// 9:44 PM". The only place the day's time is compressed.
struct TimelineEdgeLine: View {
    let edge: HistoryEdge
    let leading: Bool
    /// The zone of the item next to the edge: `HistoryEdge` carries only the instant.
    let zoneID: String

    var body: some View {
        let zone = TimeZone(identifier: zoneID) ?? .current
        let text = Copy.History.edge(
            edge.kind, leading: leading, time: HistoryFormat.time(edge.atMs, zone: zone))
        Text(text)
            .font(AppFont.timelineMeta)
            // "Quiet" is the one word allowed the lighter gray (plan 5.9); a stretch nobody was
            // listening to carries information and gets the readable one.
            .foregroundStyle(edge.kind == .quiet ? Tokens.faint : Tokens.meta)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Tokens.Timeline.gutter + Tokens.Timeline.labelInset)
            .padding(.top, leading ? 5 : 10)
            .padding(.bottom, leading ? 10 : 5)
            .background(alignment: .leading) {
                DashedAxis()
                    .frame(width: 4)
                    .offset(x: Tokens.Timeline.axisX - (4 - Tokens.Timeline.axisWidth) / 2)
            }
    }
}

// MARK: - The day

/// A day's items on the axis, with its hour labels and, on today, the "now" marker. The edge
/// lines are drawn by the page, above and below.
struct DayTimeline: View {
    let day: HistoryDay
    /// The live transcript's last line, for today's Live card.
    var liveLine: String?
    var nowMs: Int64?
    /// False while only the first screenful of `day.items` is drawn (`DayReveal`): the end of
    /// the day — the now marker, an open-ended last gap — is not drawn until it is there.
    var isComplete = true
    var onOpenChapter: (HistoryChapterBlock) -> Void = { _ in }
    var onOpenFollowUp: (HistoryFollowUpLine) -> Void = { _ in }
    var onOpenGap: (HistoryGap) -> Void = { _ in }
    var onOpenLive: () -> Void = {}
    var onOpenTag: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let metrics = HistoryMetrics.at(dynamicTypeSize).timeline
        let marks = hourMarks(metrics: metrics)
        DayTimelineLayout(pointsPerMinute: metrics.pointsPerMinute, scaleLogZoneID: scaleLogZoneID) {
            TimelineAxis().timelineRole(.axis)
            ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                itemView(item, isLast: index == day.items.count - 1)
                    .timelineRole(.item(
                        TimelineSpan(startMs: item.startMs, endMs: item.endMs),
                        floor: floor(of: item), isCard: isCard(item)))
            }
            ForEach(marks, id: \.ms) { mark in
                HourMark(text: HistoryFormat.hourLabel(
                    mark.ms, zone: TimeZone(identifier: mark.zoneID) ?? .current))
                    .timelineRole(.mark(mark.ms))
            }
            if let now = nowMarkMs {
                HourMark(
                    text: HistoryFormat.clock(now, zone: TimeZone(identifier: lastZoneID) ?? .current),
                    isNow: true)
                    .timelineRole(.mark(now))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Today's "now": the end of the live card, or of an open-ended last gap.
    private var nowMarkMs: Int64? {
        guard isComplete, day.isToday, let last = day.items.last else { return nil }
        if case .live = last { return last.endMs }
        return nowMs.map { min($0, last.endMs) }
    }

    private var lastZoneID: String {
        for item in day.items.reversed() {
            switch item {
            case .zoneChange(let change): return change.zoneID
            case .chapter(let block): return block.zoneID
            case .gap(let gap): return gap.zoneID
            case .live(let live): return live.zoneID
            }
        }
        return TimeZone.current.identifier
    }

    private func hourMarks(metrics: TimelineMetrics) -> [TimelineMark] {
        guard let first = day.items.first, let last = day.items.last else { return [] }
        var zones: [(atMs: Int64, zoneID: String)] = [(first.startMs, firstZoneID)]
        for item in day.items {
            if case .zoneChange(let change) = item { zones.append((change.atMs, change.zoneID)) }
        }
        let clearance = TimelineGeometry.clearanceMinutes(
            labelHeight: TimelineScale.hourLabelSpacing, metrics: metrics)
        return TimelineGeometry.hourMarks(
            in: TimelineSpan(startMs: first.startMs, endMs: last.endMs), zones: zones,
            now: nowMarkMs, clearanceMinutes: clearance)
    }

    private var firstZoneID: String {
        for item in day.items {
            switch item {
            case .chapter(let block): return block.zoneID
            case .gap(let gap): return gap.zoneID
            case .live(let live): return live.zoneID
            case .zoneChange: continue
            }
        }
        return day.zoneID
    }

    private var scaleLogZoneID: String? {
        #if DEBUG
        return isComplete ? "\(day.dateKey)|\(day.zoneID)" : nil
        #else
        return nil
        #endif
    }

    private func isCard(_ item: HistoryItem) -> Bool {
        switch item {
        case .chapter, .live: return true
        case .gap(let gap): return HistoryLabels.isPendingCard(gap)
        case .zoneChange: return false
        }
    }

    private func floor(of item: HistoryItem) -> CGFloat {
        switch item {
        case .gap(let gap):
            if HistoryLabels.isPendingCard(gap) { return 0 }
            return TimelineGeometry.gapFloor(isLabelled: HistoryLabels.isLabelled(gap))
        case .chapter, .live, .zoneChange:
            return 0
        }
    }

    @ViewBuilder
    private func itemView(_ item: HistoryItem, isLast: Bool) -> some View {
        switch item {
        case .chapter(let block):
            ChapterCard(
                block: block, onOpen: { onOpenChapter(block) }, onOpenFollowUp: onOpenFollowUp,
                onOpenTag: onOpenTag)
        case .gap(let gap):
            if HistoryLabels.isPendingCard(gap) {
                PendingChapterCard(gap: gap) { onOpenGap(gap) }
            } else {
                TimelineGap(gap: gap, openEnded: day.isToday && isLast && isComplete) { onOpenGap(gap) }
            }
        case .zoneChange(let change):
            ZoneChangeDivider(change: change)
        case .live(let live):
            LiveChapterCard(live: live, lastLine: liveLine, onOpen: onOpenLive)
        }
    }
}
