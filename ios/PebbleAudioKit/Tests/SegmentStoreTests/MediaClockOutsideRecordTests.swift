import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// A gap record before a segment's first sample is not inside the recording, so it is not on the
// recording's clocks. The media clock used to clamp such a record's start to zero and keep its
// whole length, reading the watch's account of the outage BEFORE the recording (delivered after a
// RESUME that had to open a new segment) as the recording's own opening being missing.
@Suite struct MediaClockOutsideRecordTests {
    private let minute: UInt64 = 960_000  // samples at 16 kHz

    private func meta(
        firstSample: UInt64, lastSampleExclusive: UInt64, frameCount: Int64, gaps: [GapMeta]
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: "seg-outside", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: 1_700_000_000_000, startMonotonicMs: 0, receivedAtMs: 1_700_001_000_000,
            firstSampleIndex: firstSample, lastSampleIndexExclusive: lastSampleExclusive,
            frameCount: frameCount, gaps: gaps, closeReason: .interrupted)
    }

    private func gap(fromSample start: UInt64, minutes: UInt32, _ reason: GapReason) -> GapMeta {
        GapMeta(
            firstMissingSequence: UInt32(start / 320), missingFrameCount: minutes * 3_000,
            firstMissingSampleIndex: start, origin: GapMeta.originWatch, reasonRaw: Int(reason.rawValue))
    }

    @Test("a record of the outage before the recording is not on its clock")
    func aRecordBeforeTheFirstSampleIsIgnored() {
        // Minutes 10-15 of the stream: 2 min of audio, 2 min skipped as quiet, 1 min of audio.
        // Before it, the watch's account of a six-minute overflow (minutes 2-8).
        let clock = SegmentMediaClock(
            meta(
                firstSample: 10 * minute, lastSampleExclusive: 15 * minute, frameCount: 3 * 3_000,
                gaps: [
                    gap(fromSample: 2 * minute, minutes: 6, .spoolOverflow),
                    gap(fromSample: 12 * minute, minutes: 2, .silenceSuppressed),
                ]))

        #expect(clock.wallSpanMs == 300_000)
        #expect(clock.mediaSpanMs == 180_000)
        #expect(clock.recordedGapMs == 120_000, "only the quiet inside the recording is on its clock")
        #expect(clock.isExact)
        // Thirty seconds into the last minute of audio is 4.5 min into the recording.
        #expect(clock.wall(fromMedia: 150_000) == 270_000)
        #expect(clock.media(fromWall: 270_000) == 150_000)
    }

    @Test("a record straddling the first sample counts only the part inside the recording")
    func aStraddlingRecordIsClipped() {
        // Minutes 10-15 again, with an overflow from minute 8 to minute 11: one minute of it is
        // this recording's.
        let clock = SegmentMediaClock(
            meta(
                firstSample: 10 * minute, lastSampleExclusive: 15 * minute, frameCount: 4 * 3_000,
                gaps: [gap(fromSample: 8 * minute, minutes: 3, .spoolOverflow)]))

        #expect(clock.recordedGapMs == 60_000)
        #expect(clock.isExact)
        #expect(clock.wall(fromMedia: 0) == 60_000, "the stored audio begins after the missing minute")
    }
}
