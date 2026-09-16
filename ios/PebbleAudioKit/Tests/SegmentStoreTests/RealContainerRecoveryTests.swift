import Foundation
import Testing

@testable import SegmentStore

// `SegmentStore.recover()` on the phone's own library, timed. It is the one step the receiver
// has to wait for on every launch — while the watch's ~6 s spool has nobody to send to — and on
// 2026-09-16 the flight recorder showed it taking 1.6 s, 3.2 s, 8.7 s and 20 s for the same
// 1,344 segments across four relaunches of one afternoon. This is where that number is measured
// rather than reasoned about.
//
// Runs on a COPY of the newest backup's `segments/` (recovery truncates and rewrites), and skips
// cleanly where no backup exists, like the other real-library suites.

private let backupRoot: String? = {
    if let env = ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP_ROOT"] { return env }
    let parent = NSHomeDirectory() + "/Desktop/PebbleAudioBackup"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
    return names.filter { $0.hasPrefix("audio-companion-") }.sorted().last.map { parent + "/" + $0 }
}()

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

@Suite(
    "Recovery over the real library",
    .enabled(if: backupAvailable, "no PebbleAudioBackup on this machine"),
    .serialized
)
struct RealContainerRecoveryTests {
    /// Copies `segments/` into a fresh temp root. Sidecars only would not do: recovery stats
    /// every log and parses the drifted ones.
    private func copiedRoot() throws -> URL {
        let root = try makeTempRoot("real-recovery")
        let src = URL(fileURLWithPath: backupRoot! + "/segments")
        try FileManager.default.copyItem(at: src, to: root.appendingPathComponent("segments"))
        return root
    }

    @Test("a warm second recovery of an untouched library is cheap")
    func secondRecoveryIsCheap() async throws {
        let root = try copiedRoot()
        let lines = LogBox()
        let log: @Sendable (String) -> Void = { [lines] in lines.lines.append($0) }
        let store = SegmentStore(root: root, nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }, log: log)
        let count = await store.listSegments().count

        var first = Date()
        try await store.recover()
        let firstMs = Date().timeIntervalSince(first) * 1000

        // A second store over the same root, as the next launch would be.
        let again = SegmentStore(root: root, nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }, log: log)
        first = Date()
        try await again.recover()
        let secondMs = Date().timeIntervalSince(first) * 1000

        print("real-recovery: \(count) segments; first \(Int(firstMs)) ms, second \(Int(secondMs)) ms")
        #expect(await again.listSegments().count == count)
        // The second launch took every segment from the index and read no sidecar.
        let last = lines.lines.last { $0.hasPrefix("recover: ") } ?? ""
        #expect(last.contains("\(count) from the index, 0 read"), "\(last)")
        // The second launch finds nothing to reconcile; the bar is what a launch can afford
        // while the watch waits. Generous on purpose — a Mac is not the phone.
        #expect(secondMs < 2_000, "recovery of an untouched \(count)-segment library took \(Int(secondMs)) ms")
    }
}
