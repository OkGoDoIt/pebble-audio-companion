import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import CompanionRuntime

// Integration: the REAL composed runtime (real store, real queue, real grouping) runs the same
// order the closure-level tests pin, and the sink decorator that feeds Q9 observes only durable
// state.

@Suite struct RuntimeIntegrationTests {

    @Test func theComposedRuntimeRunsThePassInPlanOrder() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store)

        await fixture.runtime.start()
        #expect(
            await waitUntil { fixture.stages.stages.contains(.idleModelRelease) },
            "the first pass never reached its last stage"
        )

        let stages = fixture.stages.stages
        #expect(!stages.isEmpty)
        let firstPass = Array(stages.prefix(10))
        #expect(
            firstPass == [
                .reconsiderDisabled,
                .enqueueClosedSegments,
                .drainQueue,
                .enrich,
                .donate,
                .recap,
                .liveLocal,
                .liveCloudPrune,
                .wavExport,
                .idleModelRelease,
            ]
        )
        await fixture.runtime.stop()
    }

    @Test func aBackgroundedRuntimeOnlyEverRunsTheEarlyReturn() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setForeground(false)
        fixture.stages.reset()

        await fixture.runtime.start()
        _ = await waitUntil { !fixture.stages.stages.isEmpty }
        await fixture.clock.advance(by: 5 * 60_000)

        #expect(fixture.stages.stages.allSatisfy { $0 == .backgroundDefer })
        #expect(!fixture.stages.stages.isEmpty)
        await fixture.runtime.stop()
    }

    @Test func configChangesWakeTheLoopWithoutWaitingOutTheFallbackTimer() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.start()
        _ = await waitUntil { fixture.stages.stages.contains(.idleModelRelease) }
        let passesBefore = fixture.stages.stages.filter { $0 == .drainQueue }.count

        fixture.runtime.notifyConfigChanged()
        _ = await waitUntil {
            fixture.stages.stages.filter { $0 == .drainQueue }.count > passesBefore
        }

        let passesAfter = fixture.stages.stages.filter { $0 == .drainQueue }.count
        #expect(passesAfter > passesBefore, "a config change must not wait out the 30 s idle timer")
        #expect(fixture.clock.nowMs == 0, "and must not consume virtual time to do it")
        await fixture.runtime.stop()
    }

    // MARK: - The sink decorator behind Q9

    private final class SpySink: SegmentSink, @unchecked Sendable {
        let calls = CallRecorder()
        func openSegment(
            start: StreamStart, receivedAtMs: Int64, provenance: DurableSegmentProvenance?
        ) async throws {
            calls.record("open")
        }
        func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
            calls.record("append")
            return frames
        }
        func recordGap(streamId: UInt32, gap: GapRecord) async throws { calls.record("gap") }
        func closeSegment(reason: SegmentCloseReason) async throws { calls.record("close") }
    }

    @Test func theSinkObservesGapsOnlyAfterTheyAreDurable() async throws {
        let downstream = SpySink()
        let order = CallRecorder()
        let sink = LossObservingSink(
            downstream: downstream,
            openSegmentId: { "seg-1" },
            onGapPersisted: { _, _ in order.record("observed") }
        )
        downstream.calls.reset()

        try await sink.recordGap(
            streamId: 1,
            gap: GapRecord(
                firstMissingSequence: 10, missingFrameCount: 5,
                firstMissingSampleIndex: 3_200, origin: .sequenceSkip
            )
        )

        #expect(downstream.calls.calls == ["gap"])
        #expect(order.calls == ["observed"])
    }

    @Test func theSinkCapturesTheClosingSegmentIdBeforeTheCloseLandsIt() async throws {
        let downstream = SpySink()
        let observed = CallRecorder()
        let openId = OpenIdBox("seg-open")
        // The real store clears its open id inside `closeSegment`, which is exactly why the id
        // has to be captured BEFORE the downstream call — afterwards there is nothing to ask.
        let sink = LossObservingSink(
            downstream: ClearingSink(downstream: downstream, openId: openId),
            openSegmentId: { openId.value },
            onSegmentClosed: { id in
                observed.record(id)
                #expect(openId.value == nil)
            }
        )

        try await sink.closeSegment(reason: .interrupted)

        #expect(observed.calls == ["seg-open"])
    }

    private final class OpenIdBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        init(_ value: String?) { _value = value }
        var value: String? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private final class ClearingSink: SegmentSink, @unchecked Sendable {
        let downstream: any SegmentSink
        let openId: OpenIdBox
        init(downstream: any SegmentSink, openId: OpenIdBox) {
            self.downstream = downstream
            self.openId = openId
        }
        func openSegment(
            start: StreamStart, receivedAtMs: Int64, provenance: DurableSegmentProvenance?
        ) async throws {
            try await downstream.openSegment(
                start: start, receivedAtMs: receivedAtMs, provenance: provenance)
        }
        func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
            try await downstream.appendFrames(streamId: streamId, frames: frames)
        }
        func recordGap(streamId: UInt32, gap: GapRecord) async throws {
            try await downstream.recordGap(streamId: streamId, gap: gap)
        }
        func closeSegment(reason: SegmentCloseReason) async throws {
            try await downstream.closeSegment(reason: reason)
            openId.value = nil
        }
    }
}
