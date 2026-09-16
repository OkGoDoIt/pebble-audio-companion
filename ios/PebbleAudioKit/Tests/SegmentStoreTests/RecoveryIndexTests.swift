import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// The recovery index — `segments_index.json` — lets a launch skip reading the sidecar of every
// segment nothing has touched since the previous recovery. These pin the two properties it must
// have: it is TRUSTED only while both files are byte-for-byte as recorded, and being wrong is
// impossible by construction — anything changed, new, open, missing or unreadable is read from
// disk exactly as before the index existed.
@Suite struct RecoveryIndexTests {

    private let clock = ClockBox(1_000_000)

    /// A store whose `recover:` log lines are captured, so a test can say how many sidecars a
    /// recovery trusted and how many it read.
    private final class Recorder: @unchecked Sendable {
        var lines: [String] = []
        var last: (trusted: Int, read: Int)? {
            // "recover: N segment(s), T from the index, R read"
            guard let line = lines.last(where: { $0.hasPrefix("recover: ") }) else { return nil }
            let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 3 else { return nil }
            return (numbers[1], numbers[2])
        }
    }

    private func makeStore(_ root: URL, _ recorder: Recorder) -> SegmentStore {
        SegmentStore(
            root: root, nowMs: { [clock] in clock.now },
            log: { [recorder] line in recorder.lines.append(line) })
    }

    private func streamStart(id: UInt32) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: id, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000 + UInt64(id) * 60_000, startMonotonicMs: 86_400_123,
            flags: 0)
    }

    private func frames(_ firstSequence: UInt32, _ count: Int) -> [SegmentFrame] {
        (0..<count).map { i in
            SegmentFrame(
                sequence: firstSequence + UInt32(i),
                sampleIndex: UInt64(firstSequence + UInt32(i)) * 320,
                payload: (0..<25).map { b in UInt8((Int(firstSequence) + i + b) & 0xFF) })
        }
    }

    /// Records `count` closed segments and returns their ids.
    private func recordClosedSegments(_ store: SegmentStore, count: Int) async throws -> [String] {
        var ids: [String] = []
        for n in 0..<count {
            let id: UInt32 = 0x5EED_0000 + UInt32(n)
            try await store.openSegment(start: streamStart(id: id), receivedAtMs: clock.now, provenance: nil)
            _ = try await store.appendFrames(streamId: id, frames: frames(0, 4))
            ids.append(try #require(await store.openSegmentId))
            try await store.closeSegment(reason: .stopped(reasonRaw: 0, finalSequence: 3, finalSampleIndex: 960))
            clock.now += 60_000
        }
        return ids
    }

    private func sidecarURL(_ root: URL, _ id: String) -> URL {
        root.appendingPathComponent("segments").appendingPathComponent("\(id)\(SegmentStore.metaSuffix)")
    }

    @Test("the first recovery reads everything and leaves an index; the next trusts all of it")
    func secondLaunchTrustsUntouchedSegments() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        let ids = try await recordClosedSegments(makeStore(root, recorder), count: 3)

        try await makeStore(root, recorder).recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [0, 3])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("segments_index.json").path))

        try await makeStore(root, recorder).recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [3, 0])
        let listed = await makeStore(root, recorder).listSegments().map(\.segmentId)
        #expect(Set(listed) == Set(ids))
    }

    @Test("a sidecar rewritten between launches is read again, even at the same byte length")
    func rewrittenSidecarIsNotTrusted() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        let ids = try await recordClosedSegments(makeStore(root, recorder), count: 2)
        try await makeStore(root, recorder).recover()

        // Same length, different content: the kind of change a size-only validator would miss.
        let url = sidecarURL(root, ids[0])
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"receivedAtMs\" : 1000000"), "sidecar was: \(text)")
        text = text.replacingOccurrences(of: "\"receivedAtMs\" : 1000000", with: "\"receivedAtMs\" : 1000001")
        // The rewrite must land at a later modification time than the index recorded.
        try await Task.sleep(for: .milliseconds(20))
        try text.write(to: url, atomically: true, encoding: .utf8)

        let store = makeStore(root, recorder)
        try await store.recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [1, 1])
        #expect(await store.readMeta(ids[0])?.receivedAtMs == 1_000_001)
    }

    @Test("a segment that appears, or disappears, between launches is handled from disk")
    func newAndDeletedSegments() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        let first = try await recordClosedSegments(makeStore(root, recorder), count: 2)
        try await makeStore(root, recorder).recover()

        // One more recording after the index was written, and one deleted behind its back.
        let store = makeStore(root, recorder)
        try await store.openSegment(start: streamStart(id: 0x5EED_0099), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: 0x5EED_0099, frames: frames(0, 2))
        let added = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .stopped(reasonRaw: 0, finalSequence: 1, finalSampleIndex: 320))
        try FileManager.default.removeItem(at: sidecarURL(root, first[1]))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("segments").appendingPathComponent("\(first[1])\(SegmentStore.logSuffix)"))

        let relaunched = makeStore(root, recorder)
        try await relaunched.recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [1, 1])
        let listed = await relaunched.listSegments().map(\.segmentId)
        #expect(Set(listed) == [first[0], added])
    }

    @Test("the segment open at the crash is reconciled, never taken from the index")
    func openAtCrashIsAlwaysReconciled() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        _ = try await recordClosedSegments(makeStore(root, recorder), count: 1)
        try await makeStore(root, recorder).recover()

        // Die with a segment open.
        let store = makeStore(root, recorder)
        try await store.openSegment(start: streamStart(id: 0x5EED_0042), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: 0x5EED_0042, frames: frames(0, 5))
        let openId = try #require(await store.openSegmentId)

        let relaunched = makeStore(root, recorder)
        try await relaunched.recover()
        let meta = try #require(await relaunched.readMeta(openId))
        #expect(meta.closeReason == .interrupted)
        #expect(meta.frameCount == 5)
        // The index now carries it closed; a third launch trusts it along with the rest.
        try await makeStore(root, recorder).recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [2, 0])
    }

    @Test("a corrupt or foreign index is ignored, not trusted")
    func corruptIndexFallsBackToDisk() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        let ids = try await recordClosedSegments(makeStore(root, recorder), count: 2)
        try await makeStore(root, recorder).recover()

        let indexURL = root.appendingPathComponent("segments_index.json")
        try Data("not json".utf8).write(to: indexURL)
        let store = makeStore(root, recorder)
        try await store.recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [0, 2])
        #expect(Set(await store.listSegments().map(\.segmentId)) == Set(ids))

        // A future version of the file is not ours to interpret either.
        var text = try String(contentsOf: indexURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        try text.write(to: indexURL, atomically: true, encoding: .utf8)
        try await makeStore(root, recorder).recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [0, 2])
    }

    @Test("a read before recovery trusts the index too, and never writes")
    func readOnlyIndexUsesTheCache() async throws {
        let root = try makeTempRoot("recovery-index")
        let recorder = Recorder()
        let ids = try await recordClosedSegments(makeStore(root, recorder), count: 2)
        try await makeStore(root, recorder).recover()
        let indexURL = root.appendingPathComponent("segments_index.json")
        let before = try Data(contentsOf: indexURL)

        // `listSegments` before `recover()` is what the early coverage snapshot does at launch.
        let store = makeStore(root, recorder)
        #expect(Set(await store.listSegments().map(\.segmentId)) == Set(ids))
        #expect(try Data(contentsOf: indexURL) == before)
        #expect(recorder.lines.filter { $0.hasPrefix("recover:") }.count == 1)
    }
}
