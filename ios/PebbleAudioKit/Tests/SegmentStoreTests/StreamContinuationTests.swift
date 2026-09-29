import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// What `openSegment` tells the receiver about a stream it is asked to CONTINUE: where the stored
// audio ends, what is already recorded past it, and whether the open segment is the one holding
// it. The receiver seeds its sequence base from this, which is the only way the hole a reconnect
// leaves can be checked against anything (see `StreamContinuation`).
@Suite struct StreamContinuationTests {
    private let streamId: UInt32 = 0x5EED_0004
    private let clock = ClockBox(1_000_000)

    private func makeStore(_ root: URL, _ config: SegmentStoreConfig = SegmentStoreConfig()) -> SegmentStore {
        SegmentStore(root: root, nowMs: { [clock] in clock.now }, config: config)
    }

    private func start(resume: Bool) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1,
            flags: resume ? ProtocolConstants.streamStartFlagResume : 0)
    }

    private func frames(_ first: UInt32, _ count: Int) -> [SegmentFrame] {
        (0..<count).map {
            SegmentFrame(
                sequence: first + UInt32($0), sampleIndex: UInt64(first + UInt32($0)) * 320,
                payload: Array(repeating: 0x42, count: 25))
        }
    }

    @Test("a fresh stream has nothing to continue")
    func aFreshStreamAnswersNothing() async throws {
        let store = makeStore(try makeTempRoot("continuation"))
        #expect(try await store.openSegment(start: start(resume: false), receivedAtMs: clock.now, provenance: nil) == nil)
    }

    @Test("a re-announcement of the open stream says where its stored audio ends")
    func inPlace() async throws {
        let store = makeStore(try makeTempRoot("continuation"))
        try await store.openSegment(start: start(resume: false), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 40))

        let answer = try await store.openSegment(start: start(resume: true), receivedAtMs: clock.now, provenance: nil)
        #expect(answer == StreamContinuation(nextSequence: 40, nextSampleIndex: 40 * 320, continuesSameSegment: true))
    }

    @Test("a reattached recording answers with its own extent and the gaps recorded past it")
    func reattach() async throws {
        let root = try makeTempRoot("continuation")
        let store = makeStore(root)
        try await store.openSegment(start: start(resume: false), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 40))
        // A notice for frames past the last one stored, recorded just before the link dropped.
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 45, missingFrameCount: 5, firstMissingSampleIndex: 45 * 320,
                origin: .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 5)))
        try await store.closeSegment(reason: .interrupted)
        let id = try #require(await store.listSegments().first?.segmentId)

        clock.now += 5_000
        let answer = try await store.openSegment(start: start(resume: true), receivedAtMs: clock.now, provenance: nil)
        #expect(await store.openSegmentId == id)
        #expect(
            answer
                == StreamContinuation(
                    nextSequence: 40, nextSampleIndex: 40 * 320,
                    recordedRanges: [.init(firstSequence: 45, frameCount: 5, firstSampleIndex: 45 * 320)],
                    continuesSameSegment: true))
    }

    @Test("a stream that must continue in a new recording still says where it got to, and is not stored twice")
    func newRecording() async throws {
        let store = makeStore(try makeTempRoot("continuation"))
        try await store.openSegment(start: start(resume: false), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 40))
        try await store.closeSegment(reason: .interrupted)

        clock.now += 11 * 60_000  // past the reattach window
        let answer = try await store.openSegment(start: start(resume: true), receivedAtMs: clock.now, provenance: nil)
        #expect(answer == StreamContinuation(nextSequence: 40, nextSampleIndex: 40 * 320, continuesSameSegment: false))

        // The watch's rewind re-sends the earlier recording's tail: none of it lands here.
        let newId = try #require(await store.openSegmentId)
        let accepted = try await store.appendFrames(streamId: streamId, frames: frames(35, 10))
        #expect(accepted.map(\.sequence) == Array(40..<45))
        try await store.closeSegment(reason: .interrupted)
        #expect(try #require(await store.readMeta(newId)).dedupeFloorSequence == 39)
        #expect(await store.readFrames(newId).map(\.sequence) == Array(40..<45))
    }

    @Test("an empty rotation successor defers to the predecessor that holds the last frame")
    func emptyRotationSuccessor() async throws {
        // 39 bytes per frame record: 6 frames exceed a 200-byte rotation cap.
        let store = makeStore(try makeTempRoot("continuation"), SegmentStoreConfig(rotateAfterBytes: 200))
        try await store.openSegment(start: start(resume: false), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 6))  // rotates
        let successor = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .interrupted)  // the link drops before it gets a frame

        clock.now += 5_000
        let answer = try await store.openSegment(start: start(resume: true), receivedAtMs: clock.now, provenance: nil)
        #expect(await store.openSegmentId == successor, "the empty successor is the one reattached")
        // The audio ends at 5, in the predecessor: below that is not the open segment's to refill.
        #expect(answer == StreamContinuation(nextSequence: 6, nextSampleIndex: 6 * 320, continuesSameSegment: false))
    }
}
