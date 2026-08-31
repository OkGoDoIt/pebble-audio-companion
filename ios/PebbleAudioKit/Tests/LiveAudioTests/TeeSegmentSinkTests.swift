import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import LiveAudio

// Port of `app/src/commonTest/.../TeeSegmentSinkTest.kt` — the 1 case, same name.
@Suite struct TeeSegmentSinkTests {

    private static let streamId: UInt32 = 7

    @Test func rotationEmitsLiveCloudCloseAndOpenBoundaries() async throws {
        let clock = ClockBox(1_000)
        let root = try makeTempRoot("tee-sink")
        let store = SegmentStore(
            root: root,
            nowMs: { [clock] in clock.now },
            config: SegmentStoreConfig(rotateAfterBytes: 10)
        )
        let tap = LiveAudioTap()
        let eventStream = tap.events()

        let closedWakeups = Box(0)
        let sink = TeeSegmentSink(
            store: store,
            monitor: LiveAudioMonitor(decoder: nil, nowMs: { [clock] in clock.now }),
            nowMs: { [clock] in clock.now },
            tap: tap,
            onSegmentClosed: { closedWakeups.mutate { $0 += 1 } }
        )

        try await sink.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let originalSegmentId = await store.openSegmentId
        _ = try await sink.appendFrames(streamId: Self.streamId, frames: frames(firstSequence: 0, count: 1))
        let rotatedSegmentId = await store.openSegmentId

        var events: [LiveAudioEvent] = []
        var iterator = eventStream.makeAsyncIterator()
        for _ in 0..<4 {
            guard let event = await iterator.next() else { break }
            events.append(event)
        }

        #expect(events.count == 4)
        guard events.count == 4 else { return }
        if case .segmentOpened(let openedEvent) = events[0] {
            #expect(openedEvent.segmentId == originalSegmentId)
        } else {
            Issue.record("expected SegmentOpened, got \(events[0])")
        }
        if case .framesAppended(let segmentId, _) = events[1] {
            #expect(segmentId == originalSegmentId)
        } else {
            Issue.record("expected FramesAppended, got \(events[1])")
        }
        if case .segmentClosed(let segmentId) = events[2] {
            #expect(segmentId == originalSegmentId)
        } else {
            Issue.record("expected SegmentClosed, got \(events[2])")
        }
        if case .segmentOpened(let openedEvent) = events[3] {
            #expect(openedEvent.segmentId == rotatedSegmentId)
        } else {
            Issue.record("expected SegmentOpened, got \(events[3])")
        }
        #expect(closedWakeups.value == 1)
    }

    private func streamStart(id: UInt32 = TeeSegmentSinkTests.streamId) -> StreamStart {
        StreamStart(
            protocolVersion: 1,
            streamId: id,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000,
            startMonotonicMs: 86_400_123,
            flags: 0
        )
    }

    private func frames(firstSequence: UInt32, count: Int) -> [SegmentFrame] {
        (0..<count).map { index in
            let sequence = firstSequence + UInt32(index)
            return SegmentFrame(
                sequence: sequence,
                sampleIndex: UInt64(sequence) * 320,
                payload: (0..<25).map { UInt8($0) }
            )
        }
    }
}
