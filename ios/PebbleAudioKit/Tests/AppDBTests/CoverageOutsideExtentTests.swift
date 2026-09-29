import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// Loss records that lie outside the frames of the segment carrying them.
//
// The ordinary way to get one is a RESUME that had to open a NEW segment: the watch delivers its
// account of the outage — overflow, a transport reset, a power-save pause — before the first frame
// of the recording that follows. Coverage used to clip every loss record to its own segment's
// frames, so that time rendered as "off" (nothing was recording) instead of "missing". The
// 2026-09-29 backup holds 35 such records: 23.7 min of buffer overflow and 45 h of power save.
@Suite struct CoverageOutsideExtentTests {
    let zone = "UTC"
    let dateKey = "2026-03-10"
    var dayStart: Int64 { LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.startMs }

    private func day(_ segments: [SegmentMeta], nowMs: Int64) -> DayCoverage {
        CoverageComputer.compute(
            dateKey: dateKey, timeZoneID: zone, segments: segments.map { SegmentCoverageInput(meta: $0) },
            pauses: [], nowMs: nowMs)
    }

    @Test("an outage recorded before a recording's first frame is missing, not off")
    func lossBeforeTheFirstFrameIsMissing() {
        // The stream began at +60 min; the watch's buffer overflowed for minutes 10-20 of it and
        // the recording that followed holds minutes 20-30.
        let streamStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "after-resume", stream: 1, startTimeMs: streamStart,
            firstSample: minutesSamples(20), durationSamples: minutesSamples(10),
            gaps: [lossGap(atSample: minutesSamples(10), minutes: 10, reasonRaw: Int(GapReason.spoolOverflow.rawValue))])

        let coverage = day([meta], nowMs: dayStart + minutesMs(120))
        #expect(
            coverage.spans == [
                .init(kind: .off, startMs: dayStart, endMs: streamStart + minutesMs(10)),
                .init(kind: .missing, startMs: streamStart + minutesMs(10), endMs: streamStart + minutesMs(20)),
                .init(kind: .recorded, startMs: streamStart + minutesMs(20), endMs: streamStart + minutesMs(30)),
                .init(kind: .off, startMs: streamStart + minutesMs(30), endMs: dayStart + minutesMs(120)),
            ])
        #expect(coverage.totalMissingMs == minutesMs(10))
    }

    @Test("nothing is invented between a record and the first frame")
    func theStretchBetweenARecordAndTheFirstFrameStaysOff() {
        let streamStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "after-resume", stream: 1, startTimeMs: streamStart,
            firstSample: minutesSamples(20), durationSamples: minutesSamples(5),
            gaps: [lossGap(atSample: minutesSamples(10), minutes: 4)])

        let coverage = day([meta], nowMs: dayStart + minutesMs(120))
        let between = coverage.spans.first { $0.startMs <= streamStart + minutesMs(16) && streamStart + minutesMs(16) < $0.endMs }
        #expect(between?.kind == .off, "minutes 14-20 have no record of any kind; they are not loss and not quiet")
        #expect(coverage.totalMissingMs == minutesMs(4))
        #expect(coverage.totalRecordedMs == minutesMs(5))
    }

    @Test("a recording that stored no frame still shows the loss it recorded")
    func aFramelessRecordingDrawsItsLoss() {
        let streamStart = dayStart + minutesMs(60)
        var meta = makeSegment(
            id: "empty", stream: 1, startTimeMs: streamStart, firstSample: minutesSamples(30),
            durationSamples: 0,
            gaps: [lossGap(atSample: minutesSamples(25), minutes: 5, reasonRaw: Int(GapReason.transportReset.rawValue))])
        meta.firstSampleIndex = nil
        meta.lastSampleIndexExclusive = nil
        meta.firstSequence = nil
        meta.lastSequence = nil

        let coverage = day([meta], nowMs: dayStart + minutesMs(120))
        #expect(coverage.totalMissingMs == minutesMs(5))
        #expect(coverage.totalRecordedMs == 0)
    }

    @Test("a record cannot reach past the moment the phone closed its recording")
    func aRecordIsBoundedByTheClose() {
        let streamStart = dayStart + minutesMs(60)
        // A corrupt count claiming ten hours of loss after the last frame of a recording that
        // closed at +10 min.
        var meta = makeSegment(
            id: "corrupt", stream: 1, startTimeMs: streamStart, durationSamples: minutesSamples(10),
            gaps: [lossGap(atSample: minutesSamples(10), minutes: 600)])
        meta.closedAtMs = streamStart + minutesMs(10)

        let coverage = day([meta], nowMs: dayStart + minutesMs(600))
        #expect(coverage.totalMissingMs == CoverageComputer.recordAfterCloseSlackMs)
    }

    @Test("quiet stays inside the recording's own frames")
    func quietIsNotExtendedByOutsideLoss() {
        let streamStart = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: streamStart, firstSample: minutesSamples(20),
            durationSamples: minutesSamples(3),
            gaps: [lossGap(atSample: minutesSamples(10), minutes: 5)])
        // Frames cover minutes 20-21 and 22-23; minute 21-22 is a frame hole (quiet).
        let input = SegmentCoverageInput(
            meta: meta,
            frameSampleRanges: [
                minutesSamples(20)..<minutesSamples(21), minutesSamples(22)..<minutesSamples(23),
            ])
        let coverage = CoverageComputer.compute(
            dateKey: dateKey, timeZoneID: zone, segments: [input], pauses: [], nowMs: dayStart + minutesMs(120))

        let quiet = coverage.spans.filter { $0.kind == .quiet }
        #expect(quiet == [.init(kind: .quiet, startMs: streamStart + minutesMs(21), endMs: streamStart + minutesMs(22))])
        #expect(coverage.totalMissingMs == minutesMs(5))
    }
}
