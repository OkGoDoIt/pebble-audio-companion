import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// The checkpoint safety property on a full phone: a write the store refuses must not be
// acknowledged, the session must say why it stopped, and once space is back the watch's re-send
// must be stored and only then checkpointed. Driven end to end through the REAL store with the
// file system failing underneath it (`SegmentStore.Faults`).
@Suite struct StorageFullTests {
    private let streamId: UInt32 = 0x5EED_0F00

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

    private static func enospc() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: nil)
    }

    /// The file system as a full phone presents it: part of every append lands, then ENOSPC;
    /// and, when `sidecarsToo`, every sidecar write is refused as well.
    private static func fullDisk(sidecarsToo: Bool) -> SegmentStore.Faults {
        var faults = SegmentStore.Faults(logWrite: { handle, data in
            try handle.write(contentsOf: data.prefix(9))
            throw enospc()
        })
        if sidecarsToo {
            faults.beforeMetaWrite = { _ in throw enospc() }
        }
        return faults
    }

    /// Sequences in [0, through] neither stored nor recorded as a gap — what a checkpoint through
    /// `through` would have told the watch to delete with no copy anywhere.
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

    @Test(arguments: [false, true])
    func aRefusedWriteIsNeverCheckpointedAndTheResendIsStoredOnceSpaceIsBack(sidecarsToo: Bool)
        async throws
    {
        let h = try StoreBackedSession()
        try await h.connectAndAuthorize()
        h.link.pushData(start(resume: false))
        for first in stride(from: UInt32(0), to: 100, by: 25) { try await h.push(data(first, 25)) }
        await h.clock.advance(by: 3_500)
        try await h.push(data(100, 1))
        try #require(await h.waitUntil { !h.checkpoints().isEmpty }, "no checkpoint while healthy")
        let healthy = try #require(h.checkpoints().map(\.highestContiguousSequencePersisted).max())
        #expect(healthy >= 100)

        // The disk fills. The next batch is refused; the session leaves streaming and says why.
        await h.store.injectFaults(Self.fullDisk(sidecarsToo: sidecarsToo))
        let resyncsBefore = h.link.resyncCount
        h.link.pushData(data(101, 25))
        try #require(
            await h.waitUntil {
                if case .connectionFailed = h.session.state.value { return true }
                return false
            }, "the session must not keep claiming to record into a store that refused")
        if case .connectionFailed(_, let detail) = h.session.state.value {
            #expect(detail?.contains("could not be stored") == true, "\(detail ?? "nil")")
        }
        // No checkpoint moved past what was stored before the refusal, and nothing a checkpoint
        // ever covered is missing from the store.
        let claimed = try #require(h.checkpoints().map(\.highestContiguousSequencePersisted).max())
        #expect(claimed == healthy, "a refused batch must not be checkpointed")
        #expect(await unaccounted(h, through: claimed).isEmpty)
        #expect(await h.store.lastWriteFailure?.isStorageFull == true)

        // The rebuild is backed off to the ceiling, not the two-second first rung: every retry
        // re-sends the spool into the same full disk.
        await h.clock.advance(by: AudioReceiverSession.handshakeRetryBaseMs)
        await h.clock.settle()
        #expect(h.link.resyncCount == resyncsBefore, "a storage refusal must not retry on the short ladder")
        await h.clock.advance(by: AudioReceiverSession.handshakeRetryMaxMs)
        await h.clock.settle()
        #expect(h.link.resyncCount == resyncsBefore + 1, "...but it must still retry")

        // Space comes back. The watch re-announces and re-sends everything above its trim point
        // (which is what it does after a checkpoint through `healthy`); all of it is stored,
        // and the checkpoint that follows covers only stored audio.
        try await h.disconnect()
        await h.store.injectFaults(SegmentStore.Faults())
        await h.clock.advance(by: 5_000)
        let before = h.checkpoints().count
        try await h.connectAndAuthorize()
        h.link.pushData(start(resume: true))
        h.link.pushData(data(101, 25))
        try await h.push(data(126, 25))
        await h.clock.advance(by: 3_500)
        try await h.push(data(151, 1))
        try #require(await h.waitUntil { h.checkpoints().count > before }, "no checkpoint after recovery")
        let after = try #require(
            h.checkpoints().dropFirst(before).map(\.highestContiguousSequencePersisted).max())
        #expect(after >= 151)
        #expect(await unaccounted(h, through: after).isEmpty)
        var sequences = Set<UInt32>()
        for meta in await h.store.listSegments() {
            for f in await h.store.readFrames(meta.segmentId) { sequences.insert(f.sequence) }
        }
        #expect(sequences == Set(0...151), "every frame the watch sent is stored exactly once")
        #expect(await h.store.lastWriteFailure == nil)
    }
}
