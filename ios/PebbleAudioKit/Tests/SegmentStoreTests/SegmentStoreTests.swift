import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// Port of `core/storage/src/jvmTest/.../SegmentStoreTest.kt` — all 31 cases, same names.
@Suite struct SegmentStoreTests {

    private let streamId: UInt32 = 0x5EED_0001
    private let clock = ClockBox(1_000_000)

    private func tempRoot() throws -> URL { try makeTempRoot("segstore") }

    private func makeStore(_ root: URL, _ config: SegmentStoreConfig = SegmentStoreConfig()) -> SegmentStore {
        SegmentStore(root: root, nowMs: { [clock] in clock.now }, config: config)
    }

    private func streamStart(
        id: UInt32? = nil,
        flags: UInt32 = 0,
        frameSamples: Int = 320,
        startTimeMs: UInt64 = 1_781_000_000_000,
        startMonotonicMs: UInt64 = 86_400_123
    ) -> StreamStart {
        StreamStart(
            protocolVersion: 1,
            streamId: id ?? streamId,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: frameSamples,
            sampleRateHz: 16000,
            bitRateBps: 9800,
            frameDurationMs: 20,
            startTimeMs: startTimeMs,
            startMonotonicMs: startMonotonicMs,
            flags: flags
        )
    }

    private func frames(_ firstSequence: UInt32, _ count: Int, len: Int = 25) -> [SegmentFrame] {
        (0..<count).map { i in
            SegmentFrame(
                sequence: firstSequence + UInt32(i),
                sampleIndex: UInt64(firstSequence + UInt32(i)) * 320,
                payload: (0..<len).map { b in UInt8((Int(firstSequence) + i + b) & 0xFF) }
            )
        }
    }

    private func gap(
        _ firstSequence: UInt32,
        _ count: UInt32,
        _ origin: GapOrigin = .sequenceSkip
    ) -> GapRecord {
        GapRecord(
            firstMissingSequence: firstSequence,
            missingFrameCount: count,
            firstMissingSampleIndex: UInt64(firstSequence) * 320,
            origin: origin
        )
    }

    private func segmentsDir(_ root: URL) -> URL {
        root.appendingPathComponent("segments", isDirectory: true)
    }

    private func metaFile(_ root: URL, _ segmentId: String) -> URL {
        segmentsDir(root).appendingPathComponent("\(segmentId)\(SegmentStore.metaSuffix)")
    }

    private func assertNoTempFiles(_ root: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: segmentsDir(root), includingPropertiesForKeys: nil)) ?? []
        let leftovers = entries.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        #expect(
            leftovers.isEmpty, "temp files left behind: \(leftovers)", sourceLocation: sourceLocation)
    }

    private func single<T>(_ xs: [T], sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        try #require(xs.count == 1, "expected exactly one element, got \(xs)", sourceLocation: sourceLocation)
        return xs[0]
    }

    // ------------------------------------------------------------------------------------------

    @Test func appendAndReopenRoundTrip() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        let written = frames(0, 8) + frames(8, 4, len: 60)
        _ = try await store.appendFrames(streamId: streamId, frames: Array(written.prefix(8)))
        _ = try await store.appendFrames(streamId: streamId, frames: Array(written.dropFirst(8)))
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 12, missingFrameCount: 4, firstMissingSampleIndex: 12 * 320,
                origin: .watchReported(reasonRaw: 1, watchDropCounter: 4)))
        try await store.closeSegment(
            reason: .stopped(reasonRaw: 1, finalSequence: 11, finalSampleIndex: 3840))

        // Fresh instance, as after process restart.
        let reopened = makeStore(root)
        try await reopened.recover()
        let read = await reopened.readFrames(segmentId)
        #expect(read.count == written.count)
        for (w, r) in zip(written, read) {
            #expect(w.sequence == r.sequence)
            #expect(w.sampleIndex == r.sampleIndex)
            #expect(w.payload == r.payload)
        }
        let meta = try #require(await reopened.readMeta(segmentId))
        #expect(meta.firstSequence == 0)
        #expect(meta.lastSequence == 11)
        #expect(meta.lastSampleIndexExclusive == 12 * 320)
        #expect(meta.frameCount == 12)
        #expect(meta.closeReason?.kind == CloseReasonMeta.kindStopped)
        #expect(meta.closeReason?.stopReasonRaw == 1)
        let gapMeta = try single(meta.gaps)
        #expect(gapMeta.firstMissingSequence == 12)
        #expect(gapMeta.origin == GapMeta.originWatch)
        assertNoTempFiles(root)
    }

    @Test func openSegmentMetaIsFlushedPeriodicallyWhileRecording() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        // Below the flush threshold: on-disk sidecar still has the open-time counters.
        _ = try await store.appendFrames(
            streamId: streamId, frames: frames(0, SegmentStore.openMetaFlushFrames - 1))
        #expect(try #require(await store.readMeta(segmentId)).frameCount == 0)

        // Crossing the threshold flushes the live counters without closing the segment.
        _ = try await store.appendFrames(
            streamId: streamId, frames: frames(UInt32(SegmentStore.openMetaFlushFrames - 1), 2))
        let flushed = try #require(await store.readMeta(segmentId))
        #expect(flushed.frameCount == Int64(SegmentStore.openMetaFlushFrames + 1))
        #expect(flushed.isOpen, "periodic flush must not close the segment")
        assertNoTempFiles(root)
    }

    @Test func readsAreServedFromTheInMemoryIndexNotDiskEachCall() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 4))
        try await store.closeSegment(
            reason: .stopped(reasonRaw: 1, finalSequence: 3, finalSampleIndex: 4 * 320))

        // Prime the index, then delete the on-disk sidecar behind the store's back. Before the
        // in-memory index, every read re-listed and re-parsed the directory, so the segment would
        // disappear here — and that per-call full-library disk re-parse is what starved iOS launch.
        #expect(await store.listSegments().count == 1)
        try FileManager.default.removeItem(at: metaFile(root, segmentId))
        #expect(await store.listSegments().count == 1, "reads must come from the in-memory index")
        _ = try #require(await store.readMeta(segmentId))

        // deleteSegment evicts from the index as well.
        try await store.deleteSegment(segmentId)
        #expect(await store.listSegments().isEmpty)
    }

    @Test func silenceSuppressedGapsAreNotPersistedAsDurableLoss() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        try await store.recordGap(
            streamId: streamId,
            gap: gap(
                20, 150,
                .watchReported(
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue),
                    watchDropCounter: 0)))

        #expect(try #require(await store.readMeta(segmentId)).gaps.isEmpty)
        try await store.closeSegment(reason: .interrupted)

        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(try #require(await reopened.readMeta(segmentId)).gaps.isEmpty)
    }

    @Test func contiguousSequenceSkipsCoalesceIntoOneDurableLossPeriod() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        try await store.recordGap(streamId: streamId, gap: gap(10, 1))
        try await store.recordGap(streamId: streamId, gap: gap(11, 1))
        try await store.recordGap(streamId: streamId, gap: gap(12, 3))

        let stored = try single(try #require(await store.readMeta(segmentId)).gaps)
        #expect(stored.firstMissingSequence == 10)
        #expect(stored.missingFrameCount == 5)
        #expect(stored.origin == GapMeta.originSequenceSkip)
    }

    @Test func contiguousWatchLossCoalescesAndKeepsNewestDropCounter() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        try await store.recordGap(
            streamId: streamId,
            gap: gap(
                50, 4,
                .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 4)))
        try await store.recordGap(
            streamId: streamId,
            gap: gap(
                54, 6,
                .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 10)))

        let stored = try single(try #require(await store.readMeta(segmentId)).gaps)
        #expect(stored.firstMissingSequence == 50)
        #expect(stored.missingFrameCount == 10)
        #expect(stored.origin == GapMeta.originWatch)
        #expect(stored.reasonRaw == Int(GapReason.spoolOverflow.rawValue))
        #expect(stored.watchDropCounter == 10)
    }

    @Test func overlappingRepeatedLossCoalescesIntoOneDurablePeriod() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        try await store.recordGap(
            streamId: streamId,
            gap: gap(
                100, 50,
                .watchReported(reasonRaw: Int(GapReason.transportReset.rawValue), watchDropCounter: 20)))
        try await store.recordGap(streamId: streamId, gap: gap(100, 55))
        try await store.recordGap(streamId: streamId, gap: gap(100, 60))

        let stored = try single(try #require(await store.readMeta(segmentId)).gaps)
        #expect(stored.firstMissingSequence == 100)
        #expect(stored.missingFrameCount == 60)
        #expect(stored.origin == GapMeta.originWatch)
        #expect(stored.reasonRaw == Int(GapReason.transportReset.rawValue))
    }

    @Test func recoverNormalizesLegacyGapMetadata() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .interrupted)

        let sidecar = metaFile(root, segmentId)
        var polluted = try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: sidecar))
        polluted.gaps = [
            GapMeta(
                firstMissingSequence: 10,
                missingFrameCount: 5,
                firstMissingSampleIndex: 10 * 320,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.silenceSuppressed.rawValue),
                watchDropCounter: 0),
            GapMeta(
                firstMissingSequence: 10,
                missingFrameCount: 5,
                firstMissingSampleIndex: 10 * 320,
                origin: GapMeta.originSequenceSkip),
            GapMeta(
                firstMissingSequence: 100,
                missingFrameCount: 50,
                firstMissingSampleIndex: 100 * 320,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.transportReset.rawValue),
                watchDropCounter: 50),
            GapMeta(
                firstMissingSequence: 100,
                missingFrameCount: 60,
                firstMissingSampleIndex: 100 * 320,
                origin: GapMeta.originSequenceSkip),
            GapMeta(
                firstMissingSequence: 200,
                missingFrameCount: 5,
                firstMissingSampleIndex: 200 * 320,
                origin: GapMeta.originSequenceSkip),
        ]
        try JSONEncoder().encode(polluted).write(to: sidecar)

        let reopened = makeStore(root)
        try await reopened.recover()

        let gaps = try #require(await reopened.readMeta(segmentId)).gaps
        #expect(gaps.count == 2)
        #expect(gaps[0].firstMissingSequence == 100)
        #expect(gaps[0].missingFrameCount == 60)
        #expect(gaps[0].origin == GapMeta.originWatch)
        #expect(gaps[0].reasonRaw == Int(GapReason.transportReset.rawValue))
        #expect(gaps[1].firstMissingSequence == 200)
        #expect(gaps[1].missingFrameCount == 5)
        #expect(gaps[1].origin == GapMeta.originSequenceSkip)

        let persisted = try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: sidecar))
        #expect(persisted.gaps == gaps)
    }

    @Test func nonContiguousLossRemainsSeparateDurablePeriods() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)

        try await store.recordGap(streamId: streamId, gap: gap(10, 2))
        try await store.recordGap(streamId: streamId, gap: gap(13, 2))

        let gaps = try #require(await store.readMeta(segmentId)).gaps
        #expect(gaps.count == 2)
        #expect(gaps[0].firstMissingSequence == 10)
        #expect(gaps[0].missingFrameCount == 2)
        #expect(gaps[1].firstMissingSequence == 13)
        #expect(gaps[1].missingFrameCount == 2)
    }

    @Test func resumedLegacySilenceGapDoesNotAbsorbLaterLoss() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let start = streamStart()
        try await store.openSegment(start: start, receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .interrupted)

        let sidecar = metaFile(root, segmentId)
        var legacy = try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: sidecar))
        legacy.gaps = [
            GapMeta(
                firstMissingSequence: 100,
                missingFrameCount: 5,
                firstMissingSampleIndex: 100 * 320,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.silenceSuppressed.rawValue),
                watchDropCounter: 0)
        ]
        try JSONEncoder().encode(legacy).write(to: sidecar)

        clock.now += 1_000
        let resumed = makeStore(root)
        try await resumed.recover()
        try await resumed.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        #expect(await resumed.openSegmentId == segmentId)

        try await resumed.recordGap(
            streamId: streamId,
            gap: gap(
                105, 2,
                .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 2)))

        let gaps = try #require(await resumed.readMeta(segmentId)).gaps
        #expect(gaps.count == 1)
        #expect(gaps[0].firstMissingSequence == 105)
        #expect(gaps[0].missingFrameCount == 2)
        #expect(gaps[0].reasonRaw == Int(GapReason.spoolOverflow.rawValue))
    }

    @Test func killMidAppend_truncatesToLastGoodRecord() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        let goodSize = await store.logSizeBytes(segmentId)

        // Simulate power loss mid-append: a partial record lands at the end of the log
        // (header claims 25 payload bytes, only 5 made it to disk).
        let log = segmentsDir(root).appendingPathComponent("\(segmentId).spxlog")
        let partial: [UInt8] =
            [3, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [25, 0] + [UInt8](repeating: 0, count: 5)
        try appendBytes(partial, to: log)

        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(
            await reopened.logSizeBytes(segmentId) == goodSize,
            "log must be truncated to the last good record")
        let read = await reopened.readFrames(segmentId)
        #expect(read.count == 3)
        #expect(read.last?.sequence == 2)
        // Meta written while open is reconciled against the surviving log.
        let meta = try #require(await reopened.readMeta(segmentId))
        #expect(meta.frameCount == 3)
        #expect(meta.lastSequence == 2)
        #expect(meta.closeReason?.kind == CloseReasonMeta.kindInterrupted)
    }

    @Test func recoverTruncatesGarbageLengthField() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 2))
        let goodSize = await store.logSizeBytes(segmentId)

        // Record header with a length beyond MAX_ENCODED_FRAME_BYTES (corrupt bit flip).
        let log = segmentsDir(root).appendingPathComponent("\(segmentId).spxlog")
        try appendBytes(
            [9, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [0xFF, 0x7F]
                + [UInt8](repeating: 0, count: 40),
            to: log)

        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(await reopened.logSizeBytes(segmentId) == goodSize)
        #expect(await reopened.readFrames(segmentId).count == 2)
    }

    @Test func atomicMeta_neverLeavesTempBehind_andRecoverSweepsStaleTemp() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 4))
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 4, missingFrameCount: 1, firstMissingSampleIndex: 1280,
                origin: .sequenceSkip))
        try await store.closeSegment(reason: .interrupted)
        assertNoTempFiles(root)

        // A stale temp from a crash mid-meta-write must be swept by recovery.
        let stale = segmentsDir(root).appendingPathComponent("seg-bogus.meta.json.tmp")
        try Data("{ partial".utf8).write(to: stale)
        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        assertNoTempFiles(root)
    }

    @Test func resumeStartWithinContinuationWindowReopensInterruptedSegment() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        clock.now += 2_000
        try await store.closeSegment(reason: .interrupted)

        clock.now += 45_000
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)

        #expect(await store.openSegmentId == segmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(3, 2))
        let reopenedMeta = try #require(await store.readMeta(segmentId))
        #expect(reopenedMeta.isOpen, "continued segment should be open again")
        #expect(reopenedMeta.closedAtMs == nil)
        try await store.closeSegment(reason: .interrupted)
        let closedMeta = try #require(await store.readMeta(segmentId))
        #expect(closedMeta.frameCount == 5)
        #expect(closedMeta.lastSequence == 4)
        #expect(await store.readFrames(segmentId).count == 5)
    }

    @Test func resumeStartAfterContinuationWindowOpensNewSegment() async throws {
        let root = try tempRoot()
        let store = makeStore(root, SegmentStoreConfig(continueInterruptedWithinMs: 60_000))
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 1))
        try await store.closeSegment(reason: .interrupted)

        clock.now += 60_001
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)

        let secondId = try #require(await store.openSegmentId)
        #expect(secondId != firstId, "long interruptions should remain separate Library rows")
        #expect(await store.readMeta(firstId)?.closeReason?.kind == CloseReasonMeta.kindInterrupted)
    }

    @Test func resumeStartWithChangedTimestampsStillReattaches() async throws {
        // Firmware re-announcements historically recomputed start_time_ms/start_monotonic_ms at
        // send time, so reattachment must not depend on them matching the original STREAM_START.
        let root = try tempRoot()
        let store = makeStore(root)
        let start = streamStart()
        try await store.openSegment(start: start, receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        clock.now += 2_000
        try await store.closeSegment(reason: .interrupted)

        clock.now += 30_000
        try await store.openSegment(
            start: streamStart(
                flags: ProtocolConstants.streamStartFlagResume,
                startTimeMs: start.startTimeMs + 32_000,
                startMonotonicMs: start.startMonotonicMs + 32_000),
            receivedAtMs: clock.now,
            provenance: nil)

        #expect(
            await store.openSegmentId == segmentId,
            "fresh re-announce timestamps must not block reattach")
        let meta = try #require(await store.readMeta(segmentId))
        #expect(meta.startTimeMs == start.startTimeMs, "the meta keeps the stream-birth wall clock")
        #expect(meta.startMonotonicMs == start.startMonotonicMs)
    }

    @Test func resumeStartForOpenStreamContinuesInPlace() async throws {
        // A RESUME re-announcement can arrive while the segment is still open (the phone never
        // saw the link drop). That must continue the open segment, not supersede it.
        let root = try tempRoot()
        let store = makeStore(root)
        let start = streamStart()
        try await store.openSegment(start: start, receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))

        clock.now += 5_000
        try await store.openSegment(
            start: streamStart(
                flags: ProtocolConstants.streamStartFlagResume,
                startTimeMs: start.startTimeMs + 5_000,
                startMonotonicMs: start.startMonotonicMs + 5_000),
            receivedAtMs: clock.now,
            provenance: nil)

        #expect(
            await store.openSegmentId == segmentId,
            "in-place RESUME must not supersede the open segment")
        _ = try await store.appendFrames(streamId: streamId, frames: frames(3, 2))
        try await store.closeSegment(
            reason: .stopped(reasonRaw: 1, finalSequence: 4, finalSampleIndex: 1600))

        let meta = try #require(await store.readMeta(segmentId))
        #expect(meta.frameCount == 5)
        #expect(meta.lastSequence == 4)
        #expect(meta.closeReason?.kind == CloseReasonMeta.kindStopped)
        #expect(await store.listSegments().count == 1, "no superseded twin segment may appear")
    }

    @Test func resumeRewindDoesNotDuplicatePersistedFrames() async throws {
        // After a reattach the watch rewinds its spool to the last checkpoint, re-sending frames
        // the phone may already have persisted. Those exact re-sends must be dropped, while new
        // frames past the persisted high-water mark append normally.
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 5))

        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        // Rewound batch: sequences 3..6 — 3 and 4 are duplicates, 5 and 6 are new.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(3, 4))
        try await store.closeSegment(reason: .interrupted)

        let read = await store.readFrames(segmentId)
        #expect(
            read.map(\.sequence) == (0..<7).map { UInt32($0) }, "no duplicate sequences in the log")
        let meta = try #require(await store.readMeta(segmentId))
        #expect(meta.frameCount == 7)
        #expect(meta.lastSequence == 6)
    }

    @Test func resumeStartForOpenStreamWithChangedCodecSupersedes() async throws {
        // Same stream id but a different codec contract cannot continue in place: the open
        // segment closes as superseded and a fresh segment takes over.
        let root = try tempRoot()
        let logged = LogBox()
        let storeWithLog = SegmentStore(
            root: root, nowMs: { [clock] in clock.now }, config: SegmentStoreConfig(),
            log: { [logged] in logged.lines.append($0) })
        try await storeWithLog.openSegment(
            start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await storeWithLog.openSegmentId)
        _ = try await storeWithLog.appendFrames(streamId: streamId, frames: frames(0, 2))

        try await storeWithLog.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume, frameSamples: 160),
            receivedAtMs: clock.now,
            provenance: nil)

        let secondId = try #require(await storeWithLog.openSegmentId)
        #expect(secondId != firstId)
        #expect(
            await storeWithLog.readMeta(firstId)?.closeReason?.kind == CloseReasonMeta.kindSuperseded)
        #expect(
            logged.lines.contains { $0.contains("frameSamples") },
            "the failing field must be logged, got: \(logged.lines)")
    }

    @Test func reattachResetsTranscriptionStateToPending() async throws {
        // A segment transcribed while briefly interrupted must become transcribable again when it
        // reattaches and grows — a preserved terminal state would mask everything after resume.
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        try await store.closeSegment(reason: .interrupted)
        try await store.updateTranscriptionState(segmentId, .complete)

        clock.now += 5_000
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)

        #expect(await store.openSegmentId == segmentId)
        #expect(try #require(await store.readMeta(segmentId)).transcriptionState == .pending)
    }

    @Test func crashRecoveredInterruptedSegmentReattaches() async throws {
        // Process death leaves the segment open on disk; recover() marks it Interrupted and must
        // stamp a close time, or it can never be a reattach candidate (the window keys off it).
        let root = try tempRoot()
        let start = streamStart()
        do {
            let store = makeStore(root)
            try await store.openSegment(start: start, receivedAtMs: clock.now, provenance: nil)
            _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
            // No close: the process dies here.
        }

        clock.now += 30_000
        let relaunched = makeStore(root)
        try await relaunched.recover()
        let recovered = try single(await relaunched.listSegments())
        #expect(recovered.closeReason?.kind == CloseReasonMeta.kindInterrupted)
        #expect(recovered.closedAtMs != nil, "recovery must stamp the close time")

        clock.now += 60_000
        try await relaunched.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        #expect(
            await relaunched.openSegmentId == recovered.segmentId,
            "crash-interrupted segments must reattach")
    }

    @Test func reattachKeepsOriginalRotationBudget() async throws {
        // Reattachment must not grant a fresh 15-minute rotation window, or a blip-prone stream's
        // segment never wall-rotates and grows to the byte cap.
        let root = try tempRoot()
        let store = makeStore(root)
        let openedAt = clock.now
        try await store.openSegment(start: streamStart(), receivedAtMs: openedAt, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        clock.now = openedAt + 2 * 60_000
        try await store.closeSegment(reason: .interrupted)

        clock.now = openedAt + 11 * 60_000
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        #expect(await store.openSegmentId == segmentId)

        clock.now = openedAt + 16 * 60_000  // 16 min after FIRST open: past the 15-min budget
        _ = try await store.appendFrames(streamId: streamId, frames: frames(3, 2))
        #expect(await store.openSegmentId != segmentId, "rotation must fire on the original clock")
        #expect(await store.readMeta(segmentId)?.closeReason?.kind == CloseReasonMeta.kindRotated)
    }

    @Test func rotationSuccessorDropsPreRotationRewindsAndAnchorsAtRotationTime() async throws {
        // 39 bytes per 25-byte frame record: 6 frames (234 B) exceed a 200-byte rotation cap.
        let root = try tempRoot()
        let store = makeStore(root, SegmentStoreConfig(rotateAfterBytes: 200))
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)
        let rotationClock = clock.now
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 6))  // rotates after this append
        let successorId = try #require(await store.openSegmentId)
        #expect(successorId != firstId)
        let successor = try #require(await store.readMeta(successorId))
        #expect(
            successor.dedupeFloorSequence == 5, "successor must inherit the stream high-water mark")
        #expect(
            successor.startTimeMs == UInt64(rotationClock),
            "mid-stream segment anchors at receive time")

        // A rewind re-sends the predecessor's tail: it must not duplicate into the empty
        // successor, while genuinely new frames append normally.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(4, 2))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(6, 2))
        try await store.closeSegment(reason: .interrupted)  // flushes the sidecar for readMeta
        let closed = try #require(await store.readMeta(successorId))
        #expect(closed.frameCount == 2, "only the two new frames may land in the successor")
        #expect(closed.firstSequence == 6)
        #expect(await store.readFrames(successorId).map(\.sequence) == (6..<8).map { UInt32($0) })
    }

    @Test func resumeOutsideWindowAnchorsNewSegmentAtReceiveTime() async throws {
        // A stream can stay alive on the watch for hours while the phone is away; a new segment
        // minted from its RESUME must not be filed at the stream's birth time.
        let root = try tempRoot()
        let store = makeStore(root, SegmentStoreConfig(continueInterruptedWithinMs: 60_000))
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 1))
        try await store.closeSegment(reason: .interrupted)

        clock.now += 4 * 60 * 60_000  // 4 hours later, far outside the window
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        let newId = try #require(await store.openSegmentId)
        #expect(newId != firstId)
        #expect(try #require(await store.readMeta(newId)).startTimeMs == UInt64(clock.now))
    }

    @Test func rewindRefillFillsRecordedGapAndShrinksIt() async throws {
        // Frames lost in transit (sequence-skip gap) that the watch re-delivers on rewind are the
        // one below-high-water case that must append: the audio is recovered and the gap shrinks.
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 5))
        try await store.recordGap(streamId: streamId, gap: gap(5, 5))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(10, 5))  // persisted past the hole

        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        #expect(await store.openSegmentId == segmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(5, 5))  // the rewind re-delivers the hole

        let meta = try #require(await store.readMeta(segmentId))
        #expect(meta.gaps.isEmpty, "a fully refilled gap must disappear, got \(meta.gaps)")
        #expect(meta.frameCount == 15)
        #expect(
            await store.readFrames(segmentId).map(\.sequence) == (0..<15).map { UInt32($0) },
            "readFrames must return stream order despite the out-of-order refill append")
    }

    @Test func rewindRefillPartiallyCoveringGapSplitsIt() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let segmentId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 5))
        try await store.recordGap(streamId: streamId, gap: gap(5, 5))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(10, 5))

        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now,
            provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(6, 2))  // refills 6 and 7 only

        let gaps = try #require(await store.readMeta(segmentId)).gaps
        #expect(gaps.count == 2, "a middle refill must split the gap, got \(gaps)")
        #expect(gaps[0].firstMissingSequence == 5)
        #expect(gaps[0].missingFrameCount == 1)
        #expect(gaps[1].firstMissingSequence == 8)
        #expect(gaps[1].missingFrameCount == 2)
        #expect(gaps[1].firstMissingSampleIndex == 8 * 320)
    }

    @Test func freshStreamStartDoesNotReopenInterruptedSegment() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)
        try await store.closeSegment(reason: .interrupted)

        clock.now += 10_000
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)

        #expect(await store.openSegmentId != firstId)
    }

    @Test func rotationBySize() async throws {
        let root = try tempRoot()
        // 25-byte payloads -> 39-byte records; 3 records cross the 100-byte cap.
        let store = makeStore(root, SegmentStoreConfig(rotateAfterBytes: 100))
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)

        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        let secondId = try #require(await store.openSegmentId)
        #expect(firstId != secondId, "size cap must rotate to a new segment")

        let firstMeta = try #require(await store.readMeta(firstId))
        #expect(firstMeta.closeReason?.kind == CloseReasonMeta.kindRotated)
        #expect(firstMeta.frameCount == 3)

        // The stream continues in the new segment with the same stream metadata.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(3, 1))
        let secondMeta = try #require(await store.readMeta(secondId))
        #expect(secondMeta.streamId == streamId)
        #expect(try single(await store.readFrames(secondId)).sequence == 3)
    }

    @Test func rotationByTime() async throws {
        let root = try tempRoot()
        let store = makeStore(root, SegmentStoreConfig(rotateAfterMs: 15 * 60 * 1000))
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let firstId = try #require(await store.openSegmentId)

        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 2))
        #expect(await store.openSegmentId == firstId, "no rotation before the time cap")

        clock.now += 15 * 60 * 1000 + 1
        _ = try await store.appendFrames(streamId: streamId, frames: frames(2, 2))
        #expect(await store.openSegmentId != firstId, "time cap must rotate")
        #expect(await store.readMeta(firstId)?.closeReason?.kind == CloseReasonMeta.kindRotated)
    }

    @Test func orphanLogIsQuarantined() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 1))
        try await store.closeSegment(reason: .interrupted)

        let orphan = segmentsDir(root).appendingPathComponent("seg-orphan.spxlog")
        try Data([UInt8](repeating: 1, count: 10)).write(to: orphan)

        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(
            !FileManager.default.fileExists(atPath: orphan.path),
            "orphan must be moved out of segments/")
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("quarantine/seg-orphan.spxlog").path))
        // The healthy segment is untouched.
        #expect(await reopened.listSegments().count == 1)
    }

    @Test func resumeStateRoundTrip() async throws {
        let root = try tempRoot()
        let store = FileReceiverResumeStore(root: root)
        #expect(await store.load() == nil)

        let state = ReceiverResumeState(
            lastStreamId: streamId,
            lastContiguousSequence: 4999,
            lastSampleIndex: 1_600_000)
        await store.save(state)
        #expect(await FileReceiverResumeStore(root: root).load() == state)

        // Overwrite with a nothing-persisted state.
        let empty = ReceiverResumeState(
            lastStreamId: 7,
            lastContiguousSequence: nil,
            lastSampleIndex: 0)
        await store.save(empty)
        #expect(await FileReceiverResumeStore(root: root).load() == empty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("receiver_state.json.tmp").path))

        await store.clear()
        #expect(await store.load() == nil)
    }
}
