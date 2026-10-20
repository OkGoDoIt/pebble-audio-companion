import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// Day coverage over a real backup's sidecars, measured rather than reasoned about.
//
// The 2026-09-29 backup holds 35 loss records that lie entirely BEFORE the first frame of the
// segment that carries them — the watch's account of an outage, delivered after a RESUME that
// had to open a new segment. Twelve are genuine buffer overflow (71,046 frames, 23.7 min; one
// is a 10-minute overflow on 09-20 14:53:44-15:03:43) and twenty-three are power-save pauses
// (45 h). Coverage used to clip every loss record to its own segment's frame extent, so all of
// that time rendered as "off" — as if nothing had been recording — instead of "missing".
//
// Computed the way Today computes it (sidecars only, no frame ranges), per logical day in the
// zone the audio was recorded in. Measured 2026-09-30 over the 12 days of that backup: recorded
// 12,751 min before and after; missing 651 min before, 3,378 min after; loss frames drawn as
// "off" 8,180,296 before, 0 after. Nearly all of the difference is the power-save records
// (2,703 min) — `PowerSave` is deliberately a calm but genuine gap, and the same reason inside a
// segment's frames was already drawn as missing (9.6 h of the 10.9 h missing before).
//
// Power save has since become a pause (02df7f7), and the day strip and gap status now share one
// classifier (`GapClassifier`). Over the 2026-09-30 backup the unification changed nothing here,
// to the millisecond: recorded 772,341,820 ms and missing 5,827,720 ms (12,872 / 97 min) before
// and after — no receiver skip in that backup lies wholly inside a single silence record.
//
// Gated: set PEBBLE_GAP_BACKUP to a backup root.

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_GAP_BACKUP"]

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

@Suite(
    "Day coverage over a real backup",
    .enabled(if: backupAvailable, "set PEBBLE_GAP_BACKUP to a backup root")
)
struct RealCoverageLossTests {
    @Test("loss recorded outside a segment's frames is drawn as missing, not off")
    func lossOutsideTheFrameExtentIsMissing() throws {
        let metas = SegmentFileReader(root: URL(fileURLWithPath: backupRoot!)).listSegments()
        try #require(!metas.isEmpty)
        let zone = metas.compactMap(\.recordedTimeZone).first ?? TimeZone.current.identifier

        // Loss records that lie wholly outside their own segment's frames, by reason.
        var outside: [String: (records: Int, frames: Int64)] = [:]
        for meta in metas {
            guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive else { continue }
            let frameSamples = UInt64(meta.frameSamples)
            let classifier = GapClassifier(meta.gaps)
            for gap in meta.gaps where classifier.isVisibleLoss(gap) && gap.missingFrameCount > 0 {
                let start = gap.firstMissingSampleIndex
                let end = start + UInt64(gap.missingFrameCount) * frameSamples
                guard end <= first || start >= last else { continue }
                let key = "\(gap.origin)/\(gap.reasonRaw.map(String.init) ?? "-")/\(end <= first ? "before" : "after")"
                let entry = outside[key] ?? (0, 0)
                outside[key] = (entry.records + 1, entry.frames + Int64(gap.missingFrameCount))
            }
        }
        for key in outside.keys.sorted() {
            let entry = outside[key]!
            print(
                "real-coverage: loss outside its segment's frames \(key): \(entry.records) record(s), "
                    + "\(entry.frames) frames (\(String(format: "%.1f", Double(entry.frames) * 0.02 / 60)) min)")
        }

        let inputs = metas.map { SegmentCoverageInput(meta: $0) }
        var days: [String: DayCoverage] = [:]
        func day(_ key: String) -> DayCoverage {
            if let cached = days[key] { return cached }
            let computed = CoverageComputer.compute(dateKey: key, timeZoneID: zone, segments: inputs, pauses: [])
            days[key] = computed
            return computed
        }
        let keys = Set(metas.map { LogicalDay.dateKey(forMs: $0.startWallMs, timeZoneID: zone) }).sorted()
        var recorded: Int64 = 0
        var missing: Int64 = 0
        for key in keys {
            let coverage = day(key)
            recorded += coverage.totalRecordedMs
            missing += coverage.totalMissingMs
            print(
                "real-coverage: \(key) recorded \(coverage.totalRecordedMs / 60_000) min, "
                    + "missing \(coverage.totalMissingMs / 60_000) min")
        }
        print(
            "real-coverage: \(keys.count) days, recorded \(recorded / 60_000) min, missing \(missing / 60_000) min "
                + "(\(recorded) ms / \(missing) ms)")

        // Every loss record's own time is inside a missing span on the day it happened, unless
        // recorded audio covers the same moment (recorded always wins).
        var hidden: Int64 = 0
        for meta in metas {
            let frameSamples = UInt64(meta.frameSamples)
            let classifier = GapClassifier(meta.gaps)
            for gap in meta.gaps where classifier.isVisibleLoss(gap) && gap.missingFrameCount > 0 {
                let startMs = ConversationGrouper.wallMs(ofSample: gap.firstMissingSampleIndex, in: meta)
                let endMs = ConversationGrouper.wallMs(
                    ofSample: gap.firstMissingSampleIndex + UInt64(gap.missingFrameCount) * frameSamples,
                    in: meta)
                let mid = startMs + (endMs - startMs) / 2
                let coverage = day(LogicalDay.dateKey(forMs: mid, timeZoneID: zone))
                if let span = coverage.spans.first(where: { $0.startMs <= mid && mid < $0.endMs }), span.kind == .off {
                    hidden += Int64(gap.missingFrameCount)
                }
            }
        }
        print("real-coverage: loss frames whose midpoint renders as off: \(hidden)")
        #expect(hidden == 0, "a loss record must never be drawn as time nothing was recording")
    }
}
