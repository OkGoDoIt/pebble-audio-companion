import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// The one property a CHECKPOINT must never break: the watch deletes every frame below it, so it
// may only ever cover audio this app has STORED or RECORDED AS LOST.
//
// The RESUME accounting seeds the watermark from the store — "one past the highest sequence
// stored" — which is only as safe as the store's shape: no frame may sit above a hole nothing
// records. A review of that accounting (2026-09-30) found the one way to get that shape: a batch
// appended, then the process killed before the skip under it was recorded. On relaunch the store
// answered "stored through the batch", the session seeded there, and its checkpoint told the
// watch to delete the hole's frames — which it still held and would have re-sent. The session now
// records the hole FIRST, so a kill leaves a recorded gap with nothing above it.
@Suite struct CheckpointSafetyTests {
    private let streamId: UInt32 = 0x5EED_0999

    private func start(resume: Bool) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1,
            flags: resume ? ProtocolConstants.streamStartFlagResume : 0)
    }

    private func data(_ first: UInt32, _ count: Int) -> StreamData {
        StreamData(
            streamId: streamId, firstSequence: first, firstSampleIndex: UInt64(first) * 320, flags: 0,
            frames: (0..<count).map { _ in [UInt8](repeating: 0x21, count: 12) })
    }

    /// Sequences in [0, through] that are neither stored in any segment of the stream nor covered
    /// by any of its gap records — what a checkpoint through `through` would delete unrecorded.
    private func unaccounted(_ h: StoreBackedSession, through: UInt32) async -> [UInt32] {
        var stored = Set<UInt32>()
        var recorded = Set<UInt32>()
        for meta in await h.store.listSegments() where meta.streamId == streamId {
            for f in await h.store.readFrames(meta.segmentId) { stored.insert(f.sequence) }
            for g in meta.gaps where g.missingFrameCount > 0 {
                for s in g.firstMissingSequence..<(g.firstMissingSequence + g.missingFrameCount) {
                    recorded.insert(s)
                }
            }
        }
        return (0...through).filter { !stored.contains($0) && !recorded.contains($0) }
    }

    /// The ORDER is the fix: the skip under a batch is written before the batch.
    @Test func theSkipUnderABatchIsWrittenBeforeTheBatch() async throws {
        let h = try StoreBackedSession()
        try await h.connectAndAuthorize()
        h.link.pushData(start(resume: false))
        try await h.push(data(0, 8))
        try await h.push(data(12, 4))  // 8..11 never arrive

        let order = h.sink.ledger.map { entry -> String in
            switch entry {
            case .gap(let first, _): return "gap \(first)"
            case .append(let first): return "append \(first)"
            }
        }
        let gapAt = try #require(order.firstIndex(of: "gap 8"))
        let appendAt = try #require(order.firstIndex(of: "append 12"))
        #expect(gapAt < appendAt, "the hole must be on record before anything above it is stored: \(order)")
    }

    /// What a kill between the two writes now leaves on disk — the skip recorded, the batch above
    /// it not stored — and what the next RESUME does with it: the watch re-sends what it still
    /// holds, and no checkpoint covers a frame that is neither stored nor recorded.
    @Test(arguments: [false, true])
    func aKillBetweenTheSkipAndTheBatchLeavesNothingUnrecordedToDelete(newSegment: Bool)
        async throws
    {
        let h = try StoreBackedSession()
        try await h.connectAndAuthorize()
        h.link.pushData(start(resume: false))
        for first in stride(from: UInt32(0), to: 100, by: 25) { try await h.push(data(first, 25)) }
        #expect(h.checkpoints().isEmpty)
        // 100..149 lost in transit (the watch still holds them); 150..159 arrived, and the process
        // died after recording the skip and before storing the batch.
        try await h.store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 100, missingFrameCount: 50, firstMissingSampleIndex: 100 * 320,
                origin: .sequenceSkip))

        try await h.disconnect()
        let before = h.checkpoints().count
        await h.clock.advance(by: newSegment ? 11 * 60_000 : 5_000)
        try await h.connectAndAuthorize()

        // The watch rewinds to its trim point (0: never checkpointed) and re-sends all it holds.
        h.link.pushData(start(resume: true))
        for first in stride(from: UInt32(0), to: 150, by: 25) { h.link.pushData(data(first, 25)) }
        h.link.pushData(data(150, 10))
        try await h.push(data(160, 10))
        await h.clock.advance(by: 3_500)
        try await h.push(data(170, 1))
        await h.waitUntil { h.checkpoints().count > before }

        let claimed = try #require(
            h.checkpoints().dropFirst(before).map(\.highestContiguousSequencePersisted).max())
        let lost = await unaccounted(h, through: claimed)
        #expect(
            lost.isEmpty,
            "checkpoint \(claimed) covers \(lost.count) unstored, unrecorded frames: \(lost.first ?? 0)...\(lost.last ?? 0)")
    }

    /// Main's own failure, kept pinned: a held notice ABOVE the rewind point (quiet the watch
    /// skipped while we were away) must not set the base, or the re-sent audio below it is
    /// discarded and then checkpointed away.
    @Test func aHeldNoticeAboveTheRewindPointCannotCheckpointTheResentAudioAway() async throws {
        let h = try StoreBackedSession()
        try await h.connectAndAuthorize()
        h.link.pushData(start(resume: false))
        for first in stride(from: UInt32(0), to: 100, by: 25) { try await h.push(data(first, 25)) }
        try await h.disconnect()
        let before = h.checkpoints().count
        await h.clock.advance(by: 5_000)
        try await h.connectAndAuthorize()
        h.link.pushData(
            StreamGap(
                streamId: streamId, firstMissingSequence: 150, missingFrameCount: 20,
                firstMissingSampleIndex: 150 * 320, reasonRaw: GapReason.silenceSuppressed.rawValue,
                watchDropCounter: 0))
        h.link.pushData(start(resume: true))
        for first in stride(from: UInt32(0), to: 150, by: 25) { h.link.pushData(data(first, 25)) }
        try await h.push(data(170, 10))
        await h.clock.advance(by: 3_500)
        try await h.push(data(180, 1))
        await h.waitUntil { h.checkpoints().count > before }
        let claimed = try #require(
            h.checkpoints().dropFirst(before).map(\.highestContiguousSequencePersisted).max())
        let lost = await unaccounted(h, through: claimed)
        #expect(
            lost.isEmpty,
            "checkpoint \(claimed) covers \(lost.count) unstored, unrecorded frames: \(lost.first ?? 0)...\(lost.last ?? 0)")
    }
}
