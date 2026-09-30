import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// The maths the day timeline hangs on (plan 5.3 "The time scale", 7.12 "The day timeline").
// Pure: no views, no state. Everything the layout decides about heights, hour labels and the
// pinned gap labels is decided here, so it can be tested without a screen.

/// The scale rules. Values are the plan's, at the default text size.
enum TimelineScale {
    /// The floor: an hour is never shorter than 70 pt (70 / 60 = 1.1667 pt a minute).
    static let pointsPerMinute: CGFloat = 70.0 / 60.0
    /// A chapter aims to stay under this (180 pt an hour).
    static let softMaxPointsPerMinute: CGFloat = 3
    /// A gap with no label.
    static let quietGapFloor: CGFloat = 8
    /// A gap that carries a label (paused, missing, no conversation, a labelled quiet).
    static let labelledGapFloor: CGFloat = 44
    /// Chapters shorter than this show no summary at all.
    static let noSummaryUnderMinutes: Double = 25
    /// The floor grows with the text size, but never past this factor (plan 5.9).
    static let maxFloorTypeScale: CGFloat = 1.5
    /// Two labels on the axis are never closer than this, centre to centre.
    static let hourLabelSpacing: CGFloat = 17
}

/// The scale at one text size. The floor is `pointsPerMinute × the body font's scale factor`,
/// capped at 1.5×, so hours stay comparable when the cards' fixed text grows (plan 5.9). The
/// soft maximum follows the text uncapped: it is the room a card's summary is given, and at a
/// large size that room has to grow with the words in it.
struct TimelineMetrics: Equatable, Sendable {
    /// The body text style's scale factor at the current Dynamic Type size (1 at `.large`).
    var typeScale: CGFloat

    static let standard = TimelineMetrics(typeScale: 1)

    init(typeScale: CGFloat) {
        self.typeScale = max(1, typeScale)
    }

    @MainActor
    init(dynamicTypeSize: DynamicTypeSize) {
        self.init(typeScale: Self.typeScale(for: dynamicTypeSize))
    }

    var pointsPerMinute: CGFloat {
        TimelineScale.pointsPerMinute * min(typeScale, TimelineScale.maxFloorTypeScale)
    }

    var softMaxPointsPerMinute: CGFloat {
        TimelineScale.softMaxPointsPerMinute * typeScale
    }

    /// The body style's scale factor for a Dynamic Type size, from UIKit's own font metrics.
    @MainActor
    static func typeScale(for size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traits) / 100
    }
}

/// A stretch of wall-clock time on the timeline, in epoch milliseconds.
struct TimelineSpan: Equatable, Sendable {
    var startMs: Int64
    var endMs: Int64

    var minutes: CGFloat { CGFloat(max(0, endMs - startMs)) / 60_000 }
    func contains(_ ms: Int64) -> Bool { ms >= startMs && ms < endMs }
}

/// An hour label (or the "now" marker) on the axis, with the zone it is read in.
struct TimelineMark: Equatable, Sendable {
    var ms: Int64
    var zoneID: String
}

enum TimelineGeometry {

    // MARK: Heights

    /// The least an item may be: its duration on the floor scale, and at least `floor`.
    static func minHeight(
        for span: TimelineSpan, floor: CGFloat = 0, metrics: TimelineMetrics = .standard
    ) -> CGFloat {
        max(floor, (span.minutes * metrics.pointsPerMinute).rounded())
    }

    /// The height a chapter card aims to stay under.
    static func softMaxHeight(for span: TimelineSpan, metrics: TimelineMetrics = .standard)
        -> CGFloat
    {
        span.minutes * metrics.softMaxPointsPerMinute
    }

    /// The floor a gap is drawn at: 8 pt bare, 44 pt when it carries a label.
    static func gapFloor(isLabelled: Bool) -> CGFloat {
        isLabelled ? TimelineScale.labelledGapFloor : TimelineScale.quietGapFloor
    }

    // MARK: Placing an instant

    /// The y of an instant, interpolated linearly along the item that contains it. An instant
    /// on the boundary between two items belongs to the later one (its top), except the very
    /// end of the timeline, which is the last item's bottom. Nil outside the timeline.
    static func y(for ms: Int64, spans: [TimelineSpan], frames: [ClosedRange<CGFloat>]) -> CGFloat? {
        for (span, frame) in zip(spans, frames) where span.contains(ms) {
            return interpolate(ms, span: span, frame: frame)
        }
        // Zero-length items (a zone change) and the timeline's final instant.
        for (span, frame) in zip(spans, frames) where span.startMs == ms {
            return frame.lowerBound
        }
        if let last = spans.last, let frame = frames.last, last.endMs == ms {
            return frame.upperBound
        }
        return nil
    }

    private static func interpolate(_ ms: Int64, span: TimelineSpan, frame: ClosedRange<CGFloat>)
        -> CGFloat
    {
        let length = CGFloat(span.endMs - span.startMs)
        guard length > 0 else { return frame.lowerBound }
        let t = CGFloat(ms - span.startMs) / length
        return frame.lowerBound + (frame.upperBound - frame.lowerBound) * t
    }

    // MARK: Hour labels

    /// The hours to label along a timeline, each read in the zone in force at that moment.
    ///
    /// Hour labels cannot collide, and that is decided here rather than in layout: every item
    /// is at least `minutes × pointsPerMinute` tall and spacing only adds, so two instants Δ
    /// minutes apart are at least `Δ × pointsPerMinute` points apart. An hour is dropped when it
    /// falls closer than `clearanceMinutes` to the first item's start, the last item's end, or
    /// now (whose marker takes its place).
    ///
    /// `zones` are the zone changes in time order; the first entry's zone applies from the
    /// start. Hours come from `Calendar` in that zone, so a daylight-saving day labels the hour
    /// that happens twice twice and the hour that never happens not at all.
    static func hourMarks(
        in range: TimelineSpan, zones: [(atMs: Int64, zoneID: String)], now: Int64?,
        clearanceMinutes: Double
    ) -> [TimelineMark] {
        guard range.endMs > range.startMs else { return [] }
        let clearanceMs = Int64((clearanceMinutes * 60_000).rounded(.up))
        let stretches = zoneStretches(in: range, zones: zones)
        var marks: [TimelineMark] = []
        for stretch in stretches {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: stretch.zoneID) ?? .current
            let start = Date(timeIntervalSince1970: Double(stretch.startMs) / 1000)
            guard
                var hour = calendar.nextDate(
                    after: start.addingTimeInterval(-0.001),
                    matching: DateComponents(minute: 0, second: 0),
                    matchingPolicy: .nextTime, direction: .forward)
            else { continue }
            while true {
                let ms = Int64((hour.timeIntervalSince1970 * 1000).rounded())
                if ms >= stretch.endMs && !(stretch.isLast && ms == stretch.endMs) { break }
                let clearOfEdges =
                    ms - range.startMs >= clearanceMs && range.endMs - ms >= clearanceMs
                let clearOfNow = now.map { abs($0 - ms) >= clearanceMs } ?? true
                if clearOfEdges && clearOfNow {
                    marks.append(TimelineMark(ms: ms, zoneID: stretch.zoneID))
                }
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
                hour = next
            }
        }
        return marks
    }

    /// The minutes a label needs on the floor scale: half a label either side of an edge, a
    /// whole label next to another label.
    static func clearanceMinutes(labelHeight: CGFloat, metrics: TimelineMetrics) -> Double {
        Double(max(labelHeight, TimelineScale.hourLabelSpacing) / metrics.pointsPerMinute)
    }

    private struct ZoneStretch {
        var startMs: Int64
        var endMs: Int64
        var zoneID: String
        var isLast: Bool
    }

    private static func zoneStretches(
        in range: TimelineSpan, zones: [(atMs: Int64, zoneID: String)]
    ) -> [ZoneStretch] {
        let fallback = zones.first?.zoneID ?? TimeZone.current.identifier
        var boundaries: [(Int64, String)] = [(range.startMs, fallback)]
        for zone in zones where zone.atMs > range.startMs && zone.atMs < range.endMs {
            boundaries.append((zone.atMs, zone.zoneID))
        }
        // The zone in force at the start is the last change at or before it.
        if let first = zones.last(where: { $0.atMs <= range.startMs }) {
            boundaries[0].1 = first.zoneID
        }
        return boundaries.enumerated().map { index, boundary in
            let end = index + 1 < boundaries.count ? boundaries[index + 1].0 : range.endMs
            return ZoneStretch(
                startMs: boundary.0, endMs: end, zoneID: boundary.1,
                isLast: index == boundaries.count - 1)
        }
    }

    // MARK: Pinned gap labels

    /// Where a gap's label sits, as an offset from the top of the gap.
    ///
    /// All rects are in the label's local space (`GeometryProxy.bounds(of:)`): `gap` is the
    /// gap's own frame and `visible` is `bounds(of: .scrollView(axis: .vertical))` AS IS. The
    /// spike measured the latter as the region between the bars already, so no inset is
    /// subtracted here. The label rests at the middle of the gap, is kept inside the visible
    /// region, and — applied last — never leaves its gap, so a gap that is almost gone takes its
    /// label with it.
    static func pinOffset(labelHeight h: CGFloat, gap: CGRect, visible: CGRect, margin: CGFloat = 0)
        -> CGFloat
    {
        let centred = gap.minY + (gap.height - h) / 2
        let inView = min(max(centred, visible.minY + margin), visible.maxY - margin - h)
        return min(max(inView, gap.minY), gap.maxY - h)
    }
}
