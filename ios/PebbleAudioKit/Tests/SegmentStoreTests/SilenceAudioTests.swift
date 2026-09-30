import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// Deleting PART of a segment. A conversation owns a range of a segment's stored audio and its
// neighbours own the rest, so the range is silenced in place rather than cut out: the same
// records, the same clock, only the payloads of the deleted frames replaced. These pin the two
// halves of that — everything inside the range is gone, and nothing outside it moved.
@Suite struct SilenceAudioTests {

    private let clock = ClockBox(1_000_000)
    private let streamId: UInt32 = 0x5EED_0001
    /// Stands in for `SpeexSilence.frame()`: the store does not care what the bytes are, only
    /// that they are what it was handed. 25 bytes, like a real frame.
    private let silence = [UInt8](repeating: 0xEE, count: 25)

    private final class Recorder: @unchecked Sendable {
        var lines: [String] = []
        /// "recover: N segment(s), T from the index, R read"
        var last: (trusted: Int, read: Int)? {
            guard let line = lines.last(where: { $0.hasPrefix("recover: ") }) else { return nil }
            let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 3 else { return nil }
            return (numbers[1], numbers[2])
        }
    }

    private func makeStore(_ root: URL, _ recorder: Recorder = Recorder()) -> SegmentStore {
        SegmentStore(
            root: root, nowMs: { [clock] in clock.now },
            log: { [recorder] line in recorder.lines.append(line) })
    }

    private func streamStart() -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 86_400_123, flags: 0)
    }

    /// Distinct 25-byte payloads, so a frame that moved or was swapped is visible.
    private func frames(_ firstSequence: UInt32, _ count: Int) -> [SegmentFrame] {
        (0..<count).map { i in
            let sequence = firstSequence + UInt32(i)
            return SegmentFrame(
                sequence: sequence, sampleIndex: UInt64(sequence) * 320,
                payload: (0..<25).map { b in UInt8((Int(sequence) * 7 + b) & 0x7F) })
        }
    }

    /// One closed segment of `count` frames; returns its id.
    private func recordSegment(_ store: SegmentStore, count: Int) async throws -> String {
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, count))
        let id = try #require(await store.openSegmentId)
        try await store.closeSegment(
            reason: .stopped(
                reasonRaw: 0, finalSequence: UInt32(count - 1), finalSampleIndex: UInt64(count) * 320))
        return id
    }

    private func logURL(_ root: URL, _ id: String) -> URL {
        root.appendingPathComponent("segments").appendingPathComponent("\(id)\(SegmentStore.logSuffix)")
    }

    private func sidecarURL(_ root: URL, _ id: String) -> URL {
        root.appendingPathComponent("segments").appendingPathComponent("\(id)\(SegmentStore.metaSuffix)")
    }

    @Test("frames in the range are silenced; every other byte of the segment is what it was")
    func silencesExactlyTheRange() async throws {
        let root = try makeTempRoot("silence")
        let store = makeStore(root)
        let id = try await recordSegment(store, count: 50)
        let before = await store.readFrames(id)
        let metaBefore = try #require(await store.readMeta(id))
        let sidecarBefore = try Data(contentsOf: sidecarURL(root, id))
        let sizeBefore = await store.logSizeBytes(id)

        // 200 ms ..< 600 ms: the frames that START at 200, 220, … 580 — positions 10 through 29.
        let count = try await store.silenceAudio(id, mediaRangeMs: 200..<600, silenceFrame: silence)

        #expect(count == 20)
        let after = await store.readFrames(id)
        #expect(after.count == before.count)
        for (index, frame) in after.enumerated() {
            #expect(frame.sequence == before[index].sequence)
            #expect(frame.sampleIndex == before[index].sampleIndex)
            if (10..<30).contains(index) {
                #expect(frame.payload == silence, "frame \(index) still holds its audio")
            } else {
                #expect(frame.payload == before[index].payload, "frame \(index) changed")
            }
        }
        // The sidecar was not written at all, so the clock and every placement are untouched.
        #expect(await store.readMeta(id) == metaBefore)
        #expect(try Data(contentsOf: sidecarURL(root, id)) == sidecarBefore)
        #expect(await store.logSizeBytes(id) == sizeBefore)
        let clockBefore = SegmentMediaClock(metaBefore)
        let clockAfter = SegmentMediaClock(try #require(await store.readMeta(id)))
        #expect(clockAfter.mediaSpanMs == clockBefore.mediaSpanMs)
        #expect(clockAfter.wallSpanMs == clockBefore.wallSpanMs)
        // No temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("segments").path
        ).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("a frame belongs to the range its first instant falls in")
    func rangeBoundsAreFrameStarts() async throws {
        let root = try makeTempRoot("silence-bounds")
        let store = makeStore(root)
        let id = try await recordSegment(store, count: 10)

        // 30 ms ..< 70 ms: the frame at 20 ms started before the range and keeps its audio;
        // the frames at 40 and 60 start inside it.
        #expect(try await store.silenceAudio(id, mediaRangeMs: 30..<70, silenceFrame: silence) == 2)

        let silenced = await store.readFrames(id).enumerated()
            .filter { $0.element.payload == silence }.map(\.offset)
        #expect(silenced == [2, 3])
    }

    /// A refilled gap leaves the log out of sequence order on disk. The media clock is the
    /// SEQUENCE order, so that is what the range is measured in — and the file keeps its order.
    @Test("the range is measured in sequence order, and the on-disk order is kept")
    func refilledLogIsSilencedBySequencePosition() async throws {
        let root = try makeTempRoot("silence-refill")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 10))
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 10, missingFrameCount: 5, firstMissingSampleIndex: 3200,
                origin: .watchReported(reasonRaw: 1, watchDropCounter: 1)))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(15, 5))
        // The watch redelivers what it had kept: appended AFTER the later frames.
        #expect(try await store.appendFrames(streamId: streamId, frames: frames(10, 5)).count == 5)
        let id = try #require(await store.openSegmentId)
        try await store.closeSegment(
            reason: .stopped(reasonRaw: 0, finalSequence: 19, finalSampleIndex: 6400))
        let diskOrderBefore = SegmentFrameLog.parse(
            [UInt8](try Data(contentsOf: logURL(root, id)))
        ).records.map(\.sequence)
        #expect(diskOrderBefore == Array(0..<10) + Array(15..<20) + Array(10..<15))
        let metaBefore = await store.readMeta(id)

        // Media 200 ms ..< 300 ms is positions 10...14 in sequence order: sequences 10...14,
        // which sit at the END of the file.
        #expect(try await store.silenceAudio(id, mediaRangeMs: 200..<300, silenceFrame: silence) == 5)

        let disk = SegmentFrameLog.parse([UInt8](try Data(contentsOf: logURL(root, id)))).records
        #expect(disk.map(\.sequence) == diskOrderBefore)
        #expect(disk.filter { $0.payload == silence }.map(\.sequence) == Array(10..<15))
        #expect(await store.readMeta(id) == metaBefore)
    }

    @Test("a silenced segment is still trusted by the recovery index, and still silent after a relaunch")
    func survivesRecoveryAndRelaunch() async throws {
        let root = try makeTempRoot("silence-relaunch")
        let recorder = Recorder()
        let id = try await recordSegment(makeStore(root, recorder), count: 40)
        // A launch that leaves the index behind.
        try await makeStore(root, recorder).recover()

        let store = makeStore(root, recorder)
        try await store.recover()
        let metaBefore = try #require(await store.readMeta(id))
        _ = try await store.silenceAudio(id, mediaRangeMs: 0..<400, silenceFrame: silence)

        // Same process: recovery changes nothing.
        try await store.recover()
        #expect(await store.readMeta(id) == metaBefore)

        // Relaunch: the sidecar and the log's size are as the index recorded them, so the entry
        // is trusted without reading either — and what it says is still true.
        let relaunched = makeStore(root, recorder)
        try await relaunched.recover()
        #expect(recorder.last.map { [$0.trusted, $0.read] } == [1, 0])
        #expect(await relaunched.readMeta(id) == metaBefore)
        let frames = await relaunched.readFrames(id)
        #expect(frames.count == 40)
        #expect(frames.prefix(20).allSatisfy { $0.payload == silence })
        #expect(frames.dropFirst(20).allSatisfy { $0.payload != silence })
        #expect(frames.map(\.sequence) == Array(0..<40))
    }

    @Test("a replacement of another size moves logBytes and nothing else")
    func differentSizedSilenceUpdatesLogBytesOnly() async throws {
        let root = try makeTempRoot("silence-resize")
        let store = makeStore(root)
        let id = try await recordSegment(store, count: 10)
        let metaBefore = try #require(await store.readMeta(id))
        let short = [UInt8](repeating: 0xEE, count: 20)

        _ = try await store.silenceAudio(id, mediaRangeMs: 0..<100, silenceFrame: short)

        var expected = metaBefore
        expected.logBytes = metaBefore.logBytes - 5 * 5
        #expect(await store.readMeta(id) == expected)
        #expect(await store.logSizeBytes(id) == expected.logBytes)

        let relaunched = makeStore(root)
        try await relaunched.recover()
        #expect(await relaunched.readMeta(id) == expected)
        #expect(await relaunched.readFrames(id).prefix(5).allSatisfy { $0.payload == short })
    }

    /// The one window a crash can land in: the new log is in place and the sidecar still says
    /// the old size. Recovery must reconcile the size and leave everything else as it was —
    /// the frames are all there, so nothing about the segment's extent may change.
    @Test("a crash between the log and its sidecar is reconciled by recovery")
    func crashAfterTheLogIsReplacedIsRecovered() async throws {
        let root = try makeTempRoot("silence-crash")
        let store = makeStore(root)
        let id = try await recordSegment(store, count: 10)
        let metaBefore = try #require(await store.readMeta(id))
        let staleSidecar = try Data(contentsOf: sidecarURL(root, id))

        _ = try await store.silenceAudio(
            id, mediaRangeMs: 0..<100, silenceFrame: [UInt8](repeating: 0xEE, count: 20))
        // Put the old sidecar back: the state a crash before the sidecar write leaves.
        try staleSidecar.write(to: sidecarURL(root, id))

        let relaunched = makeStore(root)
        try await relaunched.recover()
        var expected = metaBefore
        expected.logBytes = metaBefore.logBytes - 5 * 5
        #expect(await relaunched.readMeta(id) == expected)
        #expect(await relaunched.readFrames(id).count == 10)
    }

    @Test("silencing the same range again writes nothing")
    func repeatingADeleteIsFree() async throws {
        let root = try makeTempRoot("silence-repeat")
        let store = makeStore(root)
        let id = try await recordSegment(store, count: 10)
        #expect(try await store.silenceAudio(id, mediaRangeMs: 0..<100, silenceFrame: silence) == 5)
        let modified = try FileManager.default.attributesOfItem(
            atPath: logURL(root, id).path)[.modificationDate] as? Date
        let bytes = try Data(contentsOf: logURL(root, id))

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(try await store.silenceAudio(id, mediaRangeMs: 0..<100, silenceFrame: silence) == 5)

        #expect(try Data(contentsOf: logURL(root, id)) == bytes)
        #expect(
            try FileManager.default.attributesOfItem(
                atPath: logURL(root, id).path)[.modificationDate] as? Date == modified)
        // And a range past the end of the audio touches nothing.
        #expect(try await store.silenceAudio(id, mediaRangeMs: 5_000..<9_000, silenceFrame: silence) == 0)
    }

    @Test("the open segment is refused out loud, never silently skipped")
    func refusesTheOpenSegment() async throws {
        let root = try makeTempRoot("silence-open")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 10))
        let id = try #require(await store.openSegmentId)

        await #expect(throws: SegmentStoreError.segmentIsOpen(segmentId: id)) {
            try await store.silenceAudio(id, mediaRangeMs: 0..<100, silenceFrame: silence)
        }
        #expect(await store.readFrames(id).allSatisfy { $0.payload != silence })

        await #expect(throws: SegmentStoreError.unknownSegment(segmentId: "seg-nope")) {
            try await store.silenceAudio("seg-nope", mediaRangeMs: 0..<100, silenceFrame: silence)
        }
        try await store.closeSegment(
            reason: .stopped(reasonRaw: 0, finalSequence: 9, finalSampleIndex: 3200))
        await #expect(throws: SegmentStoreError.invalidSilenceFrame(byteCount: 0)) {
            try await store.silenceAudio(id, mediaRangeMs: 0..<100, silenceFrame: [])
        }
    }
}
