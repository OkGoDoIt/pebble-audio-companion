import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The quiet an older build discarded, measured on a real backup before and after
// `SegmentStore.accountForUnrecordedHoles` (see `UnrecordedHoles.swift`).
//
// Each logical day in the recording zone is drawn three ways: "before" and "after" are what
// Today, Live and History draw — sidecars only, with the watch's quiet cut out of recorded time
// (`spansWithWatchQuiet`) — and "frames" is the same day computed from the frame logs themselves
// (`SegmentCoverageInput.from`), the ground truth for how much audio is held, at a cost no screen
// can pay.
//
// Measured 2026-09-30 on the 19:37 backup (930 recordings; the phone ran the fixed build from
// 01:07): the repair accounts for 329 recordings — 3,247 min quiet, 12.8 min missing (holes that
// touch a loss or power-save record) — in 4.0 s on a Mac for the whole library at once, and the
// next call, with nothing left, costs 4 ms of sidecar arithmetic. Across all 13 days recorded
// time went 13,335 -> 10,074 min against 10,020 min in the frame logs; 2026-09-24 went 1,234 ->
// 1,019 min, exactly the frame logs' 1,019. What is left unaccounted (30,808 frames) is the
// recording the fixed build began in (09-30 01:07, the evidence itself, so never inferred),
// a quiet record stored in the recording before the one it covers, and one sidecar whose log is
// gone. On the 01:14 backup — no kept quiet record anywhere — the repair correctly does nothing.
//
// Runs on a CLONE of the backup's segments (APFS clone, so a 1 GB copy is instant); the backup
// itself is never opened for writing. Gated: set PEBBLE_GAP_BACKUP to a backup root.

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_GAP_BACKUP"]

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

@Suite(
    "Unrecorded holes over a real backup",
    .enabled(if: backupAvailable, "set PEBBLE_GAP_BACKUP to a backup root")
)
struct RealUnrecordedHolesTests {
    private struct Totals {
        var recorded: Int64 = 0
        var quiet: Int64 = 0
        var missing: Int64 = 0

        mutating func add(_ spans: [CoverageSpan]) {
            for span in spans {
                switch span.kind {
                case .recorded: recorded += span.durationMs
                case .quiet: quiet += span.durationMs
                case .missing: missing += span.durationMs
                case .paused, .off: break
                }
            }
        }

        var line: String {
            func min(_ ms: Int64) -> String { String(format: "%6.0f", Double(ms) / 60_000) }
            return "recorded \(min(recorded)) min, quiet \(min(quiet)) min, missing \(min(missing)) min"
        }
    }

    @Test("the old build's quiet stops being drawn as recorded audio")
    func quietIsNoLongerRecorded() async throws {
        let source = URL(fileURLWithPath: backupRoot!)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrecorded-holes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("segments"), to: root.appendingPathComponent("segments"))

        let store = SegmentStore(root: root, nowMs: { Int64(Date().timeIntervalSince1970 * 1000) })
        try await store.recover()
        let before = await store.listSegments()
        try #require(!before.isEmpty)
        let zone = ProcessInfo.processInfo.environment["PEBBLE_GAP_ZONE"] ?? "Asia/Jakarta"
        let keys = Set(before.map { LogicalDay.dateKey(forMs: $0.startWallMs, timeZoneID: $0.recordedTimeZone ?? zone) }).sorted()

        let unaccountedBefore = before.map(\.unaccountedFrameCount)
        print(
            "real-holes: before: \(unaccountedBefore.filter { $0 > 0 }.count) of \(before.count) recordings, "
                + "\(unaccountedBefore.reduce(0, +)) unaccounted frames")

        let clock = ContinuousClock()
        var repair = UnrecordedHoleRepair()
        let elapsed = try await clock.measure {
            repair = try await store.accountForUnrecordedHoles(maxLogBytes: .max)
        }
        print(
            "real-holes: repair: \(repair.repaired) recordings, \(repair.quietFrames) quiet frames "
                + "(\(repair.quietFrames / 3000) min), \(repair.lossFrames) loss frames "
                + "(\(String(format: "%.1f", Double(repair.lossFrames) / 3000)) min), \(repair.remaining) left, \(elapsed)")
        var second = UnrecordedHoleRepair()
        let again = try await clock.measure {
            second = try await store.accountForUnrecordedHoles(maxLogBytes: .max)
        }
        #expect(second == UnrecordedHoleRepair())
        print("real-holes: second call (nothing left): \(again)")

        let after = await store.listSegments()
        let unaccountedAfter = after.map(\.unaccountedFrameCount).reduce(0, +)
        print("real-holes: after: \(unaccountedAfter) unaccounted frames")

        // Ground truth from the frame logs, once per recording.
        var frameInputs: [SegmentCoverageInput] = []
        for meta in before {
            frameInputs.append(.from(meta: meta, frames: await store.readFrames(meta.segmentId)))
        }

        var totals = (before: Totals(), after: Totals(), frames: Totals())
        for key in keys {
            func strip(_ metas: [SegmentMeta]) -> [CoverageSpan] {
                CoverageComputer.computeAttributed(
                    dateKey: key, timeZoneID: zone, segments: metas.map { SegmentCoverageInput(meta: $0) },
                    pauses: []
                ).spansWithWatchQuiet
            }
            var day = (before: Totals(), after: Totals(), frames: Totals())
            day.before.add(strip(before))
            day.after.add(strip(after))
            day.frames.add(
                CoverageComputer.compute(dateKey: key, timeZoneID: zone, segments: frameInputs, pauses: []).spans)
            print("real-holes: \(key) before  \(day.before.line)")
            print("real-holes: \(key) after   \(day.after.line)")
            print("real-holes: \(key) frames  \(day.frames.line)")
            totals.before.recorded += day.before.recorded
            totals.before.quiet += day.before.quiet
            totals.before.missing += day.before.missing
            totals.after.recorded += day.after.recorded
            totals.after.quiet += day.after.quiet
            totals.after.missing += day.after.missing
            totals.frames.recorded += day.frames.recorded
            totals.frames.quiet += day.frames.quiet
            totals.frames.missing += day.frames.missing
        }
        print("real-holes: all days before  \(totals.before.line)")
        print("real-holes: all days after   \(totals.after.line)")
        print("real-holes: all days frames  \(totals.frames.line)")

        // Every hole the repair could reach is now accounted for, and nothing it wrote is
        // recorded audio: the strip's recorded time is what the frame logs hold, to within the
        // audio outside any recording's extent that neither view places.
        #expect(repair.remaining == 0)
        #expect(totals.after.recorded < totals.before.recorded)
        let drift = abs(totals.after.recorded - totals.frames.recorded)
        #expect(drift <= totals.frames.recorded / 100, "strip recorded vs frame-log recorded: \(drift) ms apart")
    }
}
