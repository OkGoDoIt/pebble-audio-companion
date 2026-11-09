import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// What the day strip draws for a recording from before the store kept the watch's quiet records,
// before and after `unrecordedHoleRecords` gives it the records (`UnrecordedHoles.swift`).
// Sidecars only, as Today, Live and History compute it.
@Suite struct CoverageUnrecordedHolesTests {
    let zone = "UTC"
    let dateKey = "2026-03-10"
    var dayStart: Int64 { LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.startMs }

    /// Three minutes of stream: minute 1 and minute 3 stored, minute 2 a bare hole.
    func recording(gaps: [GapMeta] = []) -> (SegmentMeta, [StoredFramePosition]) {
        var meta = makeSegment(
            id: "s", stream: 1, startTimeMs: dayStart + minutesMs(60),
            durationSamples: minutesSamples(3), gaps: gaps)
        meta.lastSequence = 8_999
        meta.frameCount = 6_000
        let frames = (Array(0..<3_000) + Array(6_000..<9_000)).map {
            StoredFramePosition(sequence: UInt32($0), sampleIndex: UInt64($0) * 320)
        }
        return (meta, frames)
    }

    func strip(_ meta: SegmentMeta) -> [CoverageSpan] {
        CoverageComputer.computeAttributed(
            dateKey: dateKey, timeZoneID: zone, segments: [SegmentCoverageInput(meta: meta)],
            pauses: [], nowMs: dayStart + minutesMs(64)
        ).spansWithWatchQuiet
    }

    var start: Int64 { dayStart + minutesMs(60) }

    @Test func aBareHoleWasDrawnAsRecordedAndIsNowQuiet() {
        var (meta, frames) = recording()
        #expect(strip(meta).filter { $0.kind == .recorded }.map(\.durationMs) == [minutesMs(3)])

        meta.gaps = unrecordedHoleRecords(in: meta, frames: frames)
        #expect(
            strip(meta) == [
                .init(kind: .off, startMs: dayStart, endMs: start),
                .init(kind: .recorded, startMs: start, endMs: start + minutesMs(1)),
                .init(kind: .quiet, startMs: start + minutesMs(1), endMs: start + minutesMs(2)),
                .init(kind: .recorded, startMs: start + minutesMs(2), endMs: start + minutesMs(3)),
                .init(kind: .off, startMs: start + minutesMs(3), endMs: dayStart + minutesMs(64)),
            ])
    }

    @Test func aHoleBesideRecordedLossIsDrawnMissing() {
        // The watch's overflow record covers the second half of the hole; the first half, which
        // nothing recorded, ends exactly where it begins.
        let overflow = GapMeta(
            firstMissingSequence: 4_500, missingFrameCount: 1_500, firstMissingSampleIndex: 4_500 * 320,
            origin: GapMeta.originWatch, reasonRaw: Int(GapReason.spoolOverflow.rawValue))
        var (meta, frames) = recording(gaps: [overflow])
        meta.gaps += unrecordedHoleRecords(in: meta, frames: frames)
        let missing = strip(meta).filter { $0.kind == .missing }
        #expect(missing == [.init(kind: .missing, startMs: start + minutesMs(1), endMs: start + minutesMs(2))])
        #expect(!strip(meta).contains { $0.kind == .quiet })
    }
}
