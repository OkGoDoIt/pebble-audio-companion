import CoreGraphics
import Foundation
import SwiftUI
import Testing

// The day timeline's maths (plan 5.3 "The time scale", 7.12). The scale rule took five mockup
// rounds; these pin it so a layout change cannot quietly move an hour.

@Suite("History timeline geometry")
struct HistoryTimelineGeometryTests {
    private let newYork = "America/New_York"

    private func ms(_ iso: String) -> Int64 {
        let f = ISO8601DateFormatter()
        return Int64(f.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func minutes(_ m: Double) -> Int64 { Int64(m * 60_000) }

    // MARK: Heights

    @Test func anHourIsNeverShorterThanSeventyPoints() {
        let hour = TimelineSpan(startMs: 0, endMs: minutes(60))
        #expect(TimelineGeometry.minHeight(for: hour) == 70)
        let tenHours = TimelineSpan(startMs: 0, endMs: minutes(600))
        #expect(TimelineGeometry.minHeight(for: tenHours) == 700)
    }

    @Test func gapFloorsAreEightBareAndFortyFourLabelled() {
        let short = TimelineSpan(startMs: 0, endMs: minutes(3))
        #expect(TimelineGeometry.minHeight(for: short, floor: TimelineGeometry.gapFloor(isLabelled: false)) == 8)
        #expect(TimelineGeometry.minHeight(for: short, floor: TimelineGeometry.gapFloor(isLabelled: true)) == 44)
        // A long gap is its duration, not its floor: gaps are never collapsed.
        let long = TimelineSpan(startMs: 0, endMs: minutes(210))
        #expect(TimelineGeometry.minHeight(for: long, floor: 44) == 245)
    }

    @Test func theSoftMaximumIsThreePointsAMinute() {
        let chapter = TimelineSpan(startMs: 0, endMs: minutes(56))
        #expect(TimelineGeometry.softMaxHeight(for: chapter) == 168)
    }

    @Test @MainActor func theFloorGrowsWithTheTextSizeButStopsAtOneAndAHalf() {
        #expect(abs(TimelineMetrics.typeScale(for: .large) - 1) < 0.001)
        #expect(TimelineMetrics(dynamicTypeSize: .large) == .standard)
        let xxl = TimelineMetrics(dynamicTypeSize: .xxLarge)
        #expect(xxl.typeScale > 1 && xxl.typeScale < 1.5)
        #expect(xxl.pointsPerMinute > TimelineScale.pointsPerMinute)

        let ax5 = TimelineMetrics(dynamicTypeSize: .accessibility5)
        #expect(ax5.typeScale > 1.5)
        #expect(abs(ax5.pointsPerMinute - TimelineScale.pointsPerMinute * 1.5) < 0.0001)
        // The summary's room follows the text uncapped.
        #expect(ax5.softMaxPointsPerMinute > 3 * 1.5)

        // Smaller than default never shrinks the floor.
        #expect(TimelineMetrics(dynamicTypeSize: .xSmall).pointsPerMinute == TimelineScale.pointsPerMinute)
    }

    // MARK: Placing an instant

    @Test func anInstantIsInterpolatedAlongItsItem() {
        let spans = [
            TimelineSpan(startMs: 0, endMs: minutes(60)),
            TimelineSpan(startMs: minutes(60), endMs: minutes(90)),
        ]
        let frames: [ClosedRange<CGFloat>] = [0...200, 206...250]
        #expect(TimelineGeometry.y(for: minutes(30), spans: spans, frames: frames) == 100)
        // A boundary belongs to the later item's top, not the earlier one's bottom.
        #expect(TimelineGeometry.y(for: minutes(60), spans: spans, frames: frames) == 206)
        #expect(TimelineGeometry.y(for: minutes(75), spans: spans, frames: frames) == 228)
        // The very end of the timeline is the last item's bottom.
        #expect(TimelineGeometry.y(for: minutes(90), spans: spans, frames: frames) == 250)
        #expect(TimelineGeometry.y(for: minutes(91), spans: spans, frames: frames) == nil)
        #expect(TimelineGeometry.y(for: -1, spans: spans, frames: frames) == nil)
    }

    @Test func aZeroLengthItemPlacesItsInstantAtItsTop() {
        let spans = [
            TimelineSpan(startMs: 0, endMs: minutes(60)),
            TimelineSpan(startMs: minutes(60), endMs: minutes(60)),
            TimelineSpan(startMs: minutes(60), endMs: minutes(120)),
        ]
        let frames: [ClosedRange<CGFloat>] = [0...70, 76...96, 102...172]
        // The later non-empty item wins the boundary: hours after a zone change sit below it.
        #expect(TimelineGeometry.y(for: minutes(60), spans: spans, frames: frames) == 102)
    }

    // MARK: Hour labels

    @Test func anOrdinaryDayLabelsEveryHourBetweenItsEnds() {
        // Tuesday September 22: 8:12 AM to 9:44 PM in New York.
        let range = TimelineSpan(startMs: ms("2026-09-22T12:12:00Z"), endMs: ms("2026-09-23T01:44:00Z"))
        let marks = TimelineGeometry.hourMarks(
            in: range, zones: [(range.startMs, newYork)], now: nil, clearanceMinutes: 15)
        let labels = marks.map {
            HistoryFormat.hourLabel($0.ms, zone: TimeZone(identifier: $0.zoneID)!, locale: Locale(identifier: "en_US"))
        }
        #expect(labels.first == "9\u{00A0}AM")
        #expect(labels.last == "9\u{00A0}PM")
        #expect(marks.count == 13)
    }

    @Test func anHourTooCloseToAnEndOrToNowIsDropped() {
        let range = TimelineSpan(startMs: ms("2026-09-26T12:55:00Z"), endMs: ms("2026-09-26T15:41:00Z"))
        let now = ms("2026-09-26T15:05:00Z")
        let marks = TimelineGeometry.hourMarks(
            in: range, zones: [(range.startMs, newYork)], now: now, clearanceMinutes: 15)
        // 9 AM is 5 min after the start; 11 AM is 5 min before now: both dropped.
        #expect(marks.map(\.ms) == [ms("2026-09-26T14:00:00Z")])
    }

    @Test func theClearanceIsOneLabelOnTheFloorScale() {
        let clearance = TimelineGeometry.clearanceMinutes(labelHeight: 15, metrics: .standard)
        #expect(abs(clearance - 17 / (70.0 / 60.0)) < 0.001)
    }

    @Test func theHourThatHappensTwiceIsLabelledTwice() {
        // 2026-11-01, New York falls back at 2 AM EDT: 12:30 AM EDT to 3:30 AM EST.
        let range = TimelineSpan(startMs: ms("2026-11-01T04:30:00Z"), endMs: ms("2026-11-01T08:30:00Z"))
        let marks = TimelineGeometry.hourMarks(
            in: range, zones: [(range.startMs, newYork)], now: nil, clearanceMinutes: 15)
        #expect(marks.map(\.ms) == [
            ms("2026-11-01T05:00:00Z"), ms("2026-11-01T06:00:00Z"),
            ms("2026-11-01T07:00:00Z"), ms("2026-11-01T08:00:00Z"),
        ])
        let labels = marks.map { HistoryFormat.hourLabel($0.ms, zone: TimeZone(identifier: newYork)!, locale: Locale(identifier: "en_US")) }
        #expect(labels == ["1\u{00A0}AM", "1\u{00A0}AM", "2\u{00A0}AM", "3\u{00A0}AM"])
    }

    @Test func theHourThatNeverHappensIsNotLabelled() {
        // 2026-03-08, New York springs forward at 2 AM EST: 1:30 AM EST to 4:30 AM EDT.
        let range = TimelineSpan(startMs: ms("2026-03-08T06:30:00Z"), endMs: ms("2026-03-08T08:30:00Z"))
        let marks = TimelineGeometry.hourMarks(
            in: range, zones: [(range.startMs, newYork)], now: nil, clearanceMinutes: 15)
        let labels = marks.map { HistoryFormat.hourLabel($0.ms, zone: TimeZone(identifier: newYork)!, locale: Locale(identifier: "en_US")) }
        #expect(labels == ["3\u{00A0}AM", "4\u{00A0}AM"])
    }

    @Test func hoursAfterAZoneChangeAreReadInTheNewZone() {
        let range = TimelineSpan(startMs: ms("2026-09-17T10:00:00Z"), endMs: ms("2026-09-17T14:00:00Z"))
        let change = ms("2026-09-17T12:30:00Z")
        let marks = TimelineGeometry.hourMarks(
            in: range, zones: [(range.startMs, "UTC"), (change, "Asia/Kolkata")], now: nil,
            clearanceMinutes: 15)
        #expect(marks == [
            TimelineMark(ms: ms("2026-09-17T11:00:00Z"), zoneID: "UTC"),
            TimelineMark(ms: ms("2026-09-17T12:00:00Z"), zoneID: "UTC"),
            TimelineMark(ms: change, zoneID: "Asia/Kolkata"),              // 6 PM IST
            TimelineMark(ms: ms("2026-09-17T13:30:00Z"), zoneID: "Asia/Kolkata"),
        ])
    }

    // MARK: Pinned gap labels

    @Test func aGapLabelRestsInTheMiddleOfItsGap() {
        let gap = CGRect(x: 0, y: 0, width: 300, height: 600)
        let visible = CGRect(x: 0, y: -1_000, width: 300, height: 3_000)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: visible) == 285)
    }

    @Test func aGapScrollingOutAtTheTopKeepsItsLabelAtTheTopOfTheScreen() {
        let gap = CGRect(x: 0, y: 0, width: 300, height: 600)
        // The top 400 pt of the gap are above the scroll view's visible region.
        let visible = CGRect(x: 0, y: 400, width: 300, height: 640)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: visible) == 400)
        // ...and slides out with the gap's bottom edge once there is no room left.
        let almostGone = CGRect(x: 0, y: 590, width: 300, height: 640)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: almostGone) == 570)
    }

    @Test func aGapComingInFromBelowShowsItsLabelAtTheBottomOfTheScreen() {
        let gap = CGRect(x: 0, y: 0, width: 300, height: 600)
        // Only the gap's top 100 pt are on screen.
        let visible = CGRect(x: 0, y: -540, width: 300, height: 640)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: visible) == 70)
        // Less than a label's height on screen: the label stays in its gap, at the top.
        let barely = CGRect(x: 0, y: -630, width: 300, height: 640)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: barely) == 0)
    }

    @Test func thePinWorksInTheLabelsOwnSpaceWhereverTheLabelRests() {
        // The same gap in the local space of a label that rests centred (overlay alignment):
        // the answer is the same resting place, expressed as an offset of zero.
        let gap = CGRect(x: 0, y: -285, width: 300, height: 600)
        let visible = CGRect(x: 0, y: -1_285, width: 300, height: 3_000)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: visible) == 0)
    }

    @Test func aMarginKeepsAPinnedLabelOffTheBarEdge() {
        let gap = CGRect(x: 0, y: 0, width: 300, height: 600)
        let visible = CGRect(x: 0, y: 400, width: 300, height: 640)
        #expect(TimelineGeometry.pinOffset(labelHeight: 30, gap: gap, visible: visible, margin: 8) == 408)
    }
}
