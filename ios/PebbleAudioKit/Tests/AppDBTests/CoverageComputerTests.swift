import Foundation
import SegmentStore
import Testing

@testable import AppDB

@Suite struct CoverageComputerTests {
    // A fixed logical day in UTC for the span math; 5 AM boundary tests use America/New_York.
    let zone = "UTC"
    let dateKey = "2026-03-10"
    var dayStart: Int64 { LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.startMs }

    func spans(
        _ segments: [SegmentCoverageInput], pauses: [PauseInterval] = [], nowMs: Int64? = nil
    ) -> DayCoverage {
        CoverageComputer.compute(
            dateKey: dateKey, timeZoneID: zone, segments: segments, pauses: pauses, nowMs: nowMs)
    }

    @Test func recordedMissingQuietPausedOffSpanMath() {
        // Segment 1 h into the day: minute 1 recorded, minute 2 lost, minute 3 recorded,
        // minute 4 a frame hole (quiet). A 30-min pause at +2 h. Rendered to now = +3 h.
        let segStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: segStart, durationSamples: minutesSamples(4),
            gaps: [lossGap(atSample: minutesSamples(1), minutes: 1)])
        let input = SegmentCoverageInput(
            meta: meta,
            frameSampleRanges: [
                0..<minutesSamples(1), minutesSamples(2)..<minutesSamples(3),
            ])
        let pause = PauseInterval(
            startMs: dayStart + minutesMs(120), endMs: dayStart + minutesMs(150), source: "intent")
        let day = spans([input], pauses: [pause], nowMs: dayStart + minutesMs(180))

        let expected: [CoverageSpan] = [
            .init(kind: .off, startMs: dayStart, endMs: segStart),
            .init(kind: .recorded, startMs: segStart, endMs: segStart + minutesMs(1)),
            .init(kind: .missing, startMs: segStart + minutesMs(1), endMs: segStart + minutesMs(2)),
            .init(kind: .recorded, startMs: segStart + minutesMs(2), endMs: segStart + minutesMs(3)),
            .init(kind: .quiet, startMs: segStart + minutesMs(3), endMs: segStart + minutesMs(4)),
            .init(kind: .off, startMs: segStart + minutesMs(4), endMs: dayStart + minutesMs(120)),
            .init(
                kind: .paused, startMs: dayStart + minutesMs(120),
                endMs: dayStart + minutesMs(150)),
            .init(kind: .off, startMs: dayStart + minutesMs(150), endMs: dayStart + minutesMs(180)),
        ]
        #expect(day.spans == expected)
        #expect(day.totalRecordedMs == minutesMs(2))
        #expect(day.totalMissingMs == minutesMs(1))
    }

    @Test func silenceIsNeverMissingAndSequenceSkipIsLoss() {
        // Minute 1 frames; minute 2 a watch-reported SilenceSuppressed gap (quiet, NEVER
        // missing); minute 3 a receiver-synthesized sequence_skip gap (loss).
        let segStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: segStart, durationSamples: minutesSamples(3),
            gaps: [
                silenceGap(atSample: minutesSamples(1), minutes: 1),
                sequenceSkipGap(atSample: minutesSamples(2), minutes: 1),
            ])
        let input = SegmentCoverageInput(
            meta: meta, frameSampleRanges: [0..<minutesSamples(1)])
        let day = spans([input], nowMs: dayStart + minutesMs(120))

        let inSegment = day.spans.filter { $0.startMs >= segStart && $0.endMs <= segStart + minutesMs(3) }
        #expect(
            inSegment.map(\.kind) == [.recorded, .quiet, .missing])
        #expect(day.totalMissingMs == minutesMs(1))
        #expect(day.totalRecordedMs == minutesMs(1))
    }

    @Test func quietHoleBetweenFrameExtentsWithoutAnyGapRecord() {
        // Frames at minutes 1 and 3, no gap records at all: the hole is quiet, not missing —
        // the watch advanced sample indexes across suppressed silence.
        let segStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: segStart, durationSamples: minutesSamples(3))
        let input = SegmentCoverageInput(
            meta: meta,
            frameSampleRanges: [0..<minutesSamples(1), minutesSamples(2)..<minutesSamples(3)])
        let day = spans([input], nowMs: dayStart + minutesMs(120))
        let quiet = day.spans.filter { $0.kind == .quiet }
        #expect(
            quiet == [
                CoverageSpan(
                    kind: .quiet, startMs: segStart + minutesMs(1),
                    endMs: segStart + minutesMs(2))
            ])
        #expect(day.totalMissingMs == 0)
    }

    @Test func fiveAmBoundaryInNewYork() throws {
        let ny = "America/New_York"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: ny)!

        func ms(_ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
            let date = cal.date(
                from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        // 4:59 AM local belongs to the previous logical day; 5:01 AM to the current one.
        #expect(LogicalDay.dateKey(forMs: ms(10, 4, 59), timeZoneID: ny) == "2026-03-09")
        #expect(LogicalDay.dateKey(forMs: ms(10, 5, 1), timeZoneID: ny) == "2026-03-10")

        // Bounds round-trip: the day runs 5 AM local → 5 AM local next day.
        let bounds = try #require(LogicalDay.bounds(ofDateKey: "2026-03-10", timeZoneID: ny))
        #expect(bounds.startMs == ms(10, 5, 0))
        #expect(bounds.endMs == ms(11, 5, 0))

        // A 4:30 AM local segment lands in the PREVIOUS day's coverage.
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: ms(10, 4, 30), durationSamples: minutesSamples(10),
            tz: ny)
        let input = SegmentCoverageInput(
            meta: meta, frameSampleRanges: [0..<minutesSamples(10)])
        let previousDay = CoverageComputer.compute(
            dateKey: "2026-03-09", timeZoneID: ny, segments: [input], pauses: [])
        let currentDay = CoverageComputer.compute(
            dateKey: "2026-03-10", timeZoneID: ny, segments: [input], pauses: [])
        #expect(previousDay.totalRecordedMs == minutesMs(10))
        #expect(currentDay.totalRecordedMs == 0)
    }

    @Test func pausedIsExcludedFromMissing() {
        // A loss gap whose wall window is covered by a pause interval renders paused — the
        // pause explains the no-audio time ("paused, not missing"). Frames still win over
        // the pause where they exist.
        let segStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: segStart, durationSamples: minutesSamples(3),
            gaps: [lossGap(atSample: 0, minutes: 2)])
        let input = SegmentCoverageInput(
            meta: meta, frameSampleRanges: [minutesSamples(2)..<minutesSamples(3)])
        let pause = PauseInterval(
            startMs: segStart, endMs: segStart + minutesMs(3), source: "statusCard")
        let day = spans([input], pauses: [pause], nowMs: dayStart + minutesMs(120))

        #expect(day.totalMissingMs == 0)
        let inSegment = day.spans.filter {
            $0.startMs >= segStart && $0.endMs <= segStart + minutesMs(3)
        }
        #expect(inSegment.map(\.kind) == [.paused, .recorded])
    }

    @Test func todaySoFarClampsToNowAndOpenPauseRunsToNow() {
        let now = dayStart + minutesMs(120)
        let openPause = PauseInterval(
            startMs: dayStart + minutesMs(60), endMs: nil, source: "intent")
        let day = CoverageComputer.todaySoFar(
            nowMs: now, timeZoneID: zone, segments: [], pauses: [openPause])
        #expect(day.dateKey == dateKey)
        #expect(
            day.spans == [
                CoverageSpan(kind: .off, startMs: dayStart, endMs: dayStart + minutesMs(60)),
                CoverageSpan(kind: .paused, startMs: dayStart + minutesMs(60), endMs: now),
            ])
    }

    @Test func inputFromFrameRecordsMergesContiguousFrames() {
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: dayStart, durationSamples: minutesSamples(1))
        let frames = (0..<10).map { i in
            FrameRecord(sequence: UInt32(i), sampleIndex: UInt64(i) * 320, payload: [0])
        }
        let skipping = FrameRecord(sequence: 20, sampleIndex: 20 * 320, payload: [0])
        let input = SegmentCoverageInput.from(meta: meta, frames: frames + [skipping])
        #expect(input.frameSampleRanges == [0..<3200, 6400..<6720])
    }
}
