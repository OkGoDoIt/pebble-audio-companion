import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// Port of `core/storage/src/jvmTest/.../RetentionManagerTest.kt` — all 4 cases, same names.
@Suite struct RetentionManagerTests {

    private let clock = ClockBox(1_000_000)
    private let freeSpace = FakeFreeSpace()

    final class FakeFreeSpace: FreeSpaceProvider, @unchecked Sendable {
        var bytes: Int64 = 10 * 1024 * 1024 * 1024
        func freeBytes() -> Int64 { bytes }
    }

    private func tempRoot() throws -> URL { try makeTempRoot("retention") }

    private func makeStore(_ root: URL) -> SegmentStore {
        SegmentStore(root: root, nowMs: { [clock] in clock.now })
    }

    private func streamStart(id: UInt32) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: id, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 0, startMonotonicMs: 0, flags: 0)
    }

    /// Creates a closed segment with ~`recordCount` 39-byte records and returns its id.
    private func makeSegment(
        _ store: SegmentStore,
        id: UInt32,
        recordCount: Int = 10,
        transcribed: Bool = false,
        close: Bool = true
    ) async throws -> String {
        try await store.openSegment(start: streamStart(id: id), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(
            streamId: id,
            frames: (0..<recordCount).map { i in
                SegmentFrame(
                    sequence: UInt32(i),
                    sampleIndex: UInt64(i) * 320,
                    payload: [UInt8](repeating: 0, count: 25))
            })
        if close { try await store.closeSegment(reason: .interrupted) }
        if transcribed { try await store.updateTranscriptionState(segmentId, .complete) }
        clock.now += 1_000
        return segmentId
    }

    /// Stamps `recoveredAtMs` on a segment's durable sidecar, the way `QuarantineRecovery` does.
    /// A store re-read from the same root then sees it as recovered audio.
    private func markRecovered(_ root: URL, _ segmentId: String, at ms: Int64) throws {
        let url = root.appendingPathComponent(
            "segments/\(segmentId)\(SegmentStore.metaSuffix)")
        var meta = try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: url))
        meta.recoveredAtMs = ms
        try JSONEncoder().encode(meta).write(to: url)
    }

    @Test func sizeCap_deletesOldestFullyTranscribedFirst() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let oldTranscribed = try await makeSegment(store, id: 1, transcribed: true)
        let newTranscribed = try await makeSegment(store, id: 2, transcribed: true)
        let oldRaw = try await makeSegment(store, id: 3)
        let newRaw = try await makeSegment(store, id: 4)

        // Cap fits roughly two segments (each is 390 bytes).
        let manager = RetentionManager(
            store: store, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig(maxTotalBytes: 800))
        let deleted = try await manager.enforce()

        #expect(deleted == [oldTranscribed, newTranscribed])
        #expect(
            await store.listSegments().map(\.segmentId) == [oldRaw, newRaw],
            "untranscribed audio must outlive transcribed audio")
    }

    @Test func sizeCap_fallsBackToOldestUntranscribed_butNeverOpenSegment() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let oldRaw = try await makeSegment(store, id: 1)
        let openSegment = try await makeSegment(store, id: 2, close: false)

        let manager = RetentionManager(
            store: store, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig(maxTotalBytes: 1))
        let deleted = try await manager.enforce()

        #expect(deleted == [oldRaw])
        #expect(await store.openSegmentId == openSegment)
        #expect(
            await store.listSegments().map(\.segmentId) == [openSegment],
            "the open segment is never deleted, even over cap")
    }

    @Test func ageCap_deletesExpiredSegments() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let ancient = try await makeSegment(store, id: 1)
        clock.now += 31 * 24 * 60 * 60 * 1000
        let recent = try await makeSegment(store, id: 2)

        let manager = RetentionManager(
            store: store, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig())
        let deleted = try await manager.enforce()
        #expect(deleted == [ancient])
        #expect(await store.listSegments().map(\.segmentId) == [recent])
    }

    /// Audio the migration recovered from `quarantine/` is older than the retention window by
    /// definition — being orphaned long enough to outlive its sidecar is what made it orphaned —
    /// so an age sweep would delete it again on the first pass after the user recovered it. Now
    /// that retention runs from the pipeline, that first pass is seconds away rather than a
    /// relaunch away, which is what makes this exemption load-bearing rather than theoretical.
    @Test func ageCap_neverDeletesRecoveredAudio() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let recovered = try await makeSegment(store, id: 1)
        let ancient = try await makeSegment(store, id: 2)
        clock.now += 31 * 24 * 60 * 60 * 1000
        try markRecovered(root, recovered, at: clock.now)

        let reopened = makeStore(root)
        let manager = RetentionManager(
            store: reopened, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig())
        #expect(try await manager.enforce() == [ancient])
        #expect(await reopened.listSegments().map(\.segmentId) == [recovered])
    }

    /// The size cap still applies to recovered audio — it is an ordering, not a second exemption —
    /// but it is the LAST thing evicted. Without this the oldest-first rule targets recovered
    /// audio immediately, which is precisely the audio that exists nowhere else.
    @Test func sizeCap_evictsRecoveredAudioLast() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let recovered = try await makeSegment(store, id: 1, transcribed: true)
        let ordinary = try await makeSegment(store, id: 2, transcribed: true)
        try markRecovered(root, recovered, at: clock.now)

        // Cap fits one of the two 390-byte segments.
        let reopened = makeStore(root)
        let manager = RetentionManager(
            store: reopened, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig(maxTotalBytes: 500))
        #expect(try await manager.enforce() == [ordinary])
        #expect(await reopened.listSegments().map(\.segmentId) == [recovered])
    }

    /// The per-call budget its pipeline caller uses: an unbounded age sweep after a big policy
    /// change would hand its caller hundreds of ids to cascade in one go.
    @Test func ageCap_stopsAtTheCallersLimitAndResumesOnTheNextCall() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        var ids: [String] = []
        for id in 1...4 { ids.append(try await makeSegment(store, id: UInt32(id))) }
        clock.now += 31 * 24 * 60 * 60 * 1000

        let manager = RetentionManager(
            store: store, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig())
        #expect(try await manager.enforce(limit: 2) == Array(ids.prefix(2)))
        #expect(try await manager.enforce(limit: 2) == Array(ids.suffix(2)))
        #expect(await store.listSegments().isEmpty)
    }

    @Test func storageFloors_driveReceiverFlagsAndHint() throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let manager = RetentionManager(
            store: store, freeSpace: freeSpace, nowMs: { [clock] in clock.now },
            config: RetentionConfig())

        freeSpace.bytes = 10 * 1024 * 1024 * 1024
        #expect(manager.receiverFlags() == 0)

        freeSpace.bytes = 400 * 1024 * 1024  // < 500 MB: low storage, no pause yet
        #expect(manager.receiverFlags() == ProtocolConstants.receiverFlagLowStorage)
        #expect(manager.lowStorage)
        #expect(!manager.pauseRequested)

        freeSpace.bytes = 100 * 1024 * 1024  // < 200 MB: low storage + pause requested
        #expect(
            manager.receiverFlags()
                == ProtocolConstants.receiverFlagLowStorage | ProtocolConstants.receiverFlagPauseRequested)
        #expect(manager.freeStorageHintKb() == 100 * 1024)

        // Hint saturates instead of wrapping for very large free space.
        freeSpace.bytes = 8 * 1024 * 1024 * 1024 * 1024
        #expect(manager.freeStorageHintKb() == UInt32.max)
    }
}
