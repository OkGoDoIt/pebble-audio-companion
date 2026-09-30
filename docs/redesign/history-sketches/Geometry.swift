import CoreGraphics
import Foundation

/// Pure, testable day-timeline geometry. No SwiftUI. Times are epoch ms so DST days work.
enum TimelineScale {
    /// 70 pt per hour floor.
    static let minPointsPerMinute: CGFloat = 70.0 / 60.0
    /// Soft ceiling for a chapter (≈180 pt/hour).
    static let softMaxPointsPerMinute: CGFloat = 3
    static let quietGapFloor: CGFloat = 8
    static let labelledGapFloor: CGFloat = 44
    static let noSummaryUnderMinutes = 25
}

struct TimelineSpan: Equatable, Sendable {
    var startMs: Int64
    var endMs: Int64
    var minutes: CGFloat { CGFloat(max(0, endMs - startMs)) / 60_000 }
    func contains(_ ms: Int64) -> Bool { ms >= startMs && ms < endMs }
}

enum TimelineGeometry {
    static func minHeight(for span: TimelineSpan, floor: CGFloat = 0) -> CGFloat {
        max(floor, (span.minutes * TimelineScale.minPointsPerMinute).rounded())
    }

    static func softMaxHeight(for span: TimelineSpan, dynamicTypeScale: CGFloat = 1) -> CGFloat {
        span.minutes * TimelineScale.softMaxPointsPerMinute * max(1, dynamicTypeScale)
    }

    /// Y for a wall-clock instant, interpolated along whichever placed item contains it.
    /// `frames` are the items' placed y-ranges in timeline coordinates, same order as `spans`.
    static func y(for ms: Int64, spans: [TimelineSpan], frames: [ClosedRange<CGFloat>]) -> CGFloat? {
        for (span, frame) in zip(spans, frames) where span.contains(ms) || ms == span.endMs {
            let length = CGFloat(span.endMs - span.startMs)
            guard length > 0 else { return frame.lowerBound }
            let t = CGFloat(ms - span.startMs) / length
            return frame.lowerBound + (frame.upperBound - frame.lowerBound) * t
        }
        return nil
    }

    /// Which wall-clock hours get a label. Because every item is at least minutes × 1.1667 pt
    /// tall and spacing only adds, two instants Δ minutes apart are always ≥ Δ × 1.1667 pt apart,
    /// so collisions are decidable in minutes, before layout.
    static func hourMarks(
        in range: TimelineSpan, now: Int64?, calendar: Calendar, clearanceMinutes: Int
    ) -> [Int64] {
        let clearanceMs = Int64(clearanceMinutes) * 60_000
        let start = Date(timeIntervalSince1970: Double(range.startMs) / 1000)
        guard var hour = calendar.nextDate(
            after: start.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime)
        else { return [] }
        var marks: [Int64] = []
        while true {
            let ms = Int64(hour.timeIntervalSince1970 * 1000)
            if ms > range.endMs { break }
            let clearOfEdges = ms - range.startMs >= clearanceMs && range.endMs - ms >= clearanceMs
            let clearOfNow = now.map { abs($0 - ms) >= clearanceMs } ?? true
            if clearOfEdges && clearOfNow { marks.append(ms) }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return marks
    }

    /// Pinned gap label: all rects in the label's LOCAL space (from `GeometryProxy.bounds(of:)`).
    /// The label rests centred in the gap (local minY == 0). Returns the y offset to apply.
    static func pinOffset(labelHeight h: CGFloat, gap: CGRect, visible: CGRect) -> CGFloat {
        // Visible clamp first, gap clamp last: the gap always wins, so a label whose gap is
        // nearly gone slides out with the gap's edge instead of jumping back to the centre.
        let inView = min(max(0, visible.minY), visible.maxY - h)
        return min(max(inView, gap.minY), gap.maxY - h)
    }
}
