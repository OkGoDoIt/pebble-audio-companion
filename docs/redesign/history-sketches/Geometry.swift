import CoreGraphics
import Foundation

// Corrected after the 2026-09-30 simulator spike (iOS 27.0, iPhone 18 Pro).
// Only change vs. the sketch: `pinOffset` documents that `visible` is the scroll view's own
// bounds (already excluding the bars) and takes an optional edge margin. The maths was verified
// in all four states (see shots/q2-pin-*.png and logs/pin0-*.log).

enum TimelineScale {
    static let minPointsPerMinute: CGFloat = 70.0 / 60.0
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

    static func y(for ms: Int64, spans: [TimelineSpan], frames: [ClosedRange<CGFloat>]) -> CGFloat? {
        for (span, frame) in zip(spans, frames) where span.contains(ms) || ms == span.endMs {
            let length = CGFloat(span.endMs - span.startMs)
            guard length > 0 else { return frame.lowerBound }
            let t = CGFloat(ms - span.startMs) / length
            return frame.lowerBound + (frame.upperBound - frame.lowerBound) * t
        }
        return nil
    }

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

    /// Pinned gap label. All rects are in the label's LOCAL space (`GeometryProxy.bounds(of:)`).
    /// `visible` is `bounds(of: .scrollView(axis: .vertical))` AS IS: the spike measured it as the
    /// 640-pt region between the bars (874-pt screen, 151-pt top chrome, 83-pt tab bar), so the
    /// bar insets must NOT be subtracted again (the sketch did; it pinned 151 pt too low).
    /// `margin` keeps a pinned label off the bar edge (0 = flush, which is what was verified).
    static func pinOffset(labelHeight h: CGFloat, gap: CGRect, visible: CGRect, margin: CGFloat = 0) -> CGFloat {
        let inView = min(max(0, visible.minY + margin), visible.maxY - margin - h)
        return min(max(inView, gap.minY), gap.maxY - h)
    }
}
