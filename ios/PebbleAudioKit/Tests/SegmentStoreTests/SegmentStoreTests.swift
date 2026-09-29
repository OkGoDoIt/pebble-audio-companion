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

    // Was `silenceSuppressedGapsAreNotPersistedAsDurableLoss`, and asserted the record was
    // DROPPED. Every reader of the sidecar — the timeline's quiet layer, Today's day strip, the
    // media clock — expects to find it there, so dropping it meant quiet never rendered and a
    // skipped stretch looked exactly like lost audio. It is kept now, as quiet: the reason
    // travels with it, and nothing that counts loss counts it.
    @Test func silenceSuppressedGapsArePersistedAsQuietNotLoss() async throws {
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

        let stored = try single(try #require(await store.readMeta(segmentId)).gaps)
        #expect(stored.firstMissingSequence == 20)
        #expect(stored.missingFrameCount == 150)
        #expect(stored.origin == GapMeta.originWatch)
        #expect(stored.reasonRaw == Int(GapReason.silenceSuppressed.rawValue))
        #expect(!stored.countsAsLoss)
        try await store.closeSegment(reason: .interrupted)

        let reopened = makeStore(root)
        try await reopened.recover()
        #expect(try #require(await reopened.readMeta(segmentId)).gaps == [stored])
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

        // The repeated skips collapse into one period, and the watch's account wins for every
        // frame it covers: the transport reset keeps 100..149 with its reason, and only the ten
        // frames past it that the watch never mentioned remain the receiver's skip. (This used
        // to fold them into the reset, which put the watch's reason on frames it never claimed.)
        let gaps = try #require(await store.readMeta(segmentId)).gaps
        #expect(gaps.count == 2)
        #expect(gaps[0].firstMissingSequence == 100)
        #expect(gaps[0].missingFrameCount == 50)
        #expect(gaps[0].origin == GapMeta.originWatch)
        #expect(gaps[0].reasonRaw == Int(GapReason.transportReset.rawValue))
        #expect(gaps[1].firstMissingSequence == 150)
        #expect(gaps[1].missingFrameCount == 10)
        #expect(gaps[1].firstMissingSampleIndex == 150 * 320)
        #expect(gaps[1].origin == GapMeta.originSequenceSkip)
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

        // The silence record stays, as quiet; the skip under it is the watch's quiet, not loss,
        // and disappears; the skip that runs past the reset keeps only the frames the reset does
        // not account for.
        let gaps = try #require(await reopened.readMeta(segmentId)).gaps
        #expect(gaps.count == 4)
        #expect(gaps[0].firstMissingSequence == 10)
        #expect(gaps[0].missingFrameCount == 5)
        #expect(gaps[0].reasonRaw == Int(GapReason.silenceSuppressed.rawValue))
        #expect(gaps[1].firstMissingSequence == 100)
        #expect(gaps[1].missingFrameCount == 50)
        #expect(gaps[1].origin == GapMeta.originWatch)
        #expect(gaps[1].reasonRaw == Int(GapReason.transportReset.rawValue))
        #expect(gaps[2].firstMissingSequence == 150)
        #expect(gaps[2].missingFrameCount == 10)
        #expect(gaps[2].origin == GapMeta.originSequenceSkip)
        #expect(gaps[3].firstMissingSequence == 200)
        #expect(gaps[3].missingFrameCount == 5)
        #expect(gaps[3].origin == GapMeta.originSequenceSkip)

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

        // The quiet record is kept as quiet, and the loss that follows it stays its own record
        // with its own reason — quiet never absorbs loss.
        let gaps = try #require(await resumed.readMeta(segmentId)).gaps
        #expect(gaps.count == 2)
        #expect(gaps[0].firstMissingSequence == 100)
        #expect(gaps[0].reasonRaw == Int(GapReason.silenceSuppressed.rawValue))
        #expect(gaps[1].firstMissingSequence == 105)
        #expect(gaps[1].missingFrameCount == 2)
        #expect(gaps[1].reasonRaw == Int(GapReason.spoolOverflow.rawValue))
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
        // `startTimeMs` is the STREAM anchor (wall clock of sample index 0) and must survive
        // rotation verbatim: it is one half of a pair with `firstSampleIndex`, and overwriting it
        // with the rotation clock while the successor's samples keep counting from stream birth is
        // what used to place segments up to 24 h in the future. The successor's OWN start is
        // `startWallMs`, and that is what must land at the rotation.
        #expect(
            successor.startTimeMs == streamStart().startTimeMs,
            "the stream anchor survives rotation unchanged")
        #expect(
            successor.startWallMs == rotationClock,
            "the successor's own start is where it was minted")

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
        let resumed = try #require(await store.readMeta(newId))
        #expect(
            resumed.startTimeMs == streamStart().startTimeMs,
            "the stream anchor is kept verbatim, so sample index -> wall clock stays valid")
        #expect(resumed.startWallMs == clock.now, "the segment itself is filed at receipt")
    }

    @Test func resumeMintedSegmentIsNotPlacedInTheFutureByItsSampleIndex() async throws {
        // The regression this guards is the largest single source of wrong times in the field:
        // storing `startTimeMs = receivedAtMs` for a resume/rotation segment while its frames kept
        // stream-birth sample indexes added the whole elapsed stream twice, placing 91 of Roger's
        // 767 segments more than a minute after their own arrival (413 h of phantom shift, worst
        // case +24.4 h). Anchoring must never put a segment ahead of when the phone received it.
        let root = try tempRoot()
        let store = makeStore(root)
        let birth: UInt64 = 1_781_000_000_000
        let fourHours: Int64 = 4 * 60 * 60_000
        clock.now = Int64(birth) + fourHours
        try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume, startTimeMs: birth),
            receivedAtMs: clock.now,
            provenance: nil)
        let id = try #require(await store.openSegmentId)
        // Four hours of stream: 16 kHz x 4 h = 230.4 M samples, i.e. sequence 720_000.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(720_000, 2))
        try await store.closeSegment(reason: .interrupted)
        let meta = try #require(await store.readMeta(id))
        #expect(meta.firstSampleIndex == 720_000 * 320, "frames keep their stream-relative index")
        #expect(meta.startWallMs <= meta.receivedAtMs, "audio cannot be recorded after receipt")
        #expect(
            abs(meta.startWallMs - meta.receivedAtMs) < 1_000,
            "a live resume segment starts at receipt, not four hours later")
    }

    @Test func decodingRepairsLegacyResumeAnchoredSidecar() async throws {
        // Sidecars already on disk from the broken store: `startTimeMs == receivedAtMs` with a
        // stream-relative `firstSampleIndex`. Decoding restores the pair rather than rewriting the
        // user's files, so the whole existing library is correct the next time it is read.
        let receivedAt: Int64 = 1_781_004_000_000
        let sampleIndex: UInt64 = 720_000 * 320  // four hours at 16 kHz
        let broken = """
            {"segmentId":"seg-x","streamId":1,"protocolVersion":1,"codecIdRaw":1,"channels":1,
             "frameSamples":320,"sampleRateHz":16000,"bitRateBps":9800,"frameDurationMs":20,
             "startTimeMs":\(receivedAt),"startMonotonicMs":0,"receivedAtMs":\(receivedAt),
             "firstSampleIndex":\(sampleIndex)}
            """
        let meta = try JSONDecoder().decode(SegmentMeta.self, from: Data(broken.utf8))
        #expect(meta.startTimeMs == UInt64(receivedAt - 4 * 60 * 60_000))
        #expect(meta.startWallMs == receivedAt, "repaired pair anchors the segment at receipt")

        // A healthy sidecar must be left exactly alone: the birth clock already sits one sample
        // offset before receipt, so the two never coincide unless the offset is zero.
        let healthy = """
            {"segmentId":"seg-y","streamId":1,"protocolVersion":1,"codecIdRaw":1,"channels":1,
             "frameSamples":320,"sampleRateHz":16000,"bitRateBps":9800,"frameDurationMs":20,
             "startTimeMs":\(receivedAt - 4 * 60 * 60_000),"startMonotonicMs":0,
             "receivedAtMs":\(receivedAt),"firstSampleIndex":\(sampleIndex)}
            """
        let ok = try JSONDecoder().decode(SegmentMeta.self, from: Data(healthy.utf8))
        #expect(ok.startTimeMs == UInt64(receivedAt - 4 * 60 * 60_000))

        // A genuine stream-birth segment (firstSampleIndex 0) legitimately has
        // startTimeMs == receivedAtMs and must not be moved.
        let birth = """
            {"segmentId":"seg-z","streamId":1,"protocolVersion":1,"codecIdRaw":1,"channels":1,
             "frameSamples":320,"sampleRateHz":16000,"bitRateBps":9800,"frameDurationMs":20,
             "startTimeMs":\(receivedAt),"startMonotonicMs":0,"receivedAtMs":\(receivedAt),
             "firstSampleIndex":0}
            """
        let fresh = try JSONDecoder().decode(SegmentMeta.self, from: Data(birth.utf8))
        #expect(fresh.startTimeMs == UInt64(receivedAt))
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

    // Nothing ever read `quarantine/` back except the one-shot legacy importer, so anything
    // quarantined since sat there permanently — invisible to retention, never recovered, never
    // deleted. On a real device that was 33 files and 5.2 MB, the oldest from June.
    //
    // The sweep is deliberately ASYMMETRIC, and the second half matters far more than the first:
    // reclaiming a few megabytes is worth nothing next to deleting somebody's audio.
    // A sidecar is written BEFORE its log is created, so a crash between the two leaves a meta
    // with no log — three were on the real device. They show in the Library as a recording with no
    // audio, and they used to be enqueued for a transcription that could only fail.
    @Test func recoverDropsASidecarThatDescribesNoAudio() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 2))
        try await store.closeSegment(reason: .interrupted)
        let realId = try #require(await store.listSegments().first?.segmentId)

        // A phantom: sidecar present, log never created, no frames recorded.
        let phantom = SegmentMeta(
            segmentId: "seg-phantom",
            streamId: streamId,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 1,
            startMonotonicMs: 0,
            receivedAtMs: 1
        )
        let phantomURL = segmentsDir(root).appendingPathComponent("seg-phantom.meta.json")
        try JSONEncoder().encode(phantom).write(to: phantomURL)

        let reopened = makeStore(root)
        try await reopened.recover()

        #expect(!FileManager.default.fileExists(atPath: phantomURL.path))
        let ids = await reopened.listSegments().map(\.segmentId)
        #expect(ids == [realId], "the real recording is untouched")
    }

    // ...but a sidecar whose log has GONE, and which claims frames, is real loss. Deleting the
    // record would turn a visible gap into a silent one, which this product does not do.
    @Test func recoverKeepsASidecarWhoseAudioIsMissing() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        try await store.closeSegment(reason: .interrupted)
        let id = try #require(await store.listSegments().first?.segmentId)

        // The audio disappears from under it.
        try FileManager.default.removeItem(
            at: segmentsDir(root).appendingPathComponent("\(id).spxlog")
        )

        let reopened = makeStore(root)
        try await reopened.recover()

        #expect(
            await reopened.listSegments().map(\.segmentId) == [id],
            "a recording whose audio is gone stays on the record"
        )
    }

    @Test func quarantineSweepReclaimsEmptyLogs() async throws {
        let root = try tempRoot()
        let store = makeStore(root)
        let quarantine = root.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)

        // The shape actually found on the device: a zero-byte log, with a stray sidecar that on
        // its own describes audio which no longer exists.
        let empty = quarantine.appendingPathComponent("seg-empty.spxlog")
        try Data().write(to: empty)
        let strandedMeta = quarantine.appendingPathComponent("seg-empty.meta.json")
        try Data("{}".utf8).write(to: strandedMeta)

        let swept = await store.sweepQuarantine()

        #expect(swept.removed == 1)
        #expect(swept.retainedWithAudio == 0)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(!FileManager.default.fileExists(atPath: strandedMeta.path))
    }

    @Test func quarantineSweepNeverDeletesRealAudio() async throws {
        let root = try tempRoot()
        let store = makeStore(root)

        // Build a log with genuine frames by letting the store write one, then orphan it.
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let openId = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 4))
        try await store.closeSegment(reason: .interrupted)

        let quarantine = root.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let withAudio = quarantine.appendingPathComponent("seg-has-audio.spxlog")
        try FileManager.default.moveItem(
            at: segmentsDir(root).appendingPathComponent("\(openId).spxlog"), to: withAudio
        )

        let swept = await store.sweepQuarantine()

        #expect(swept.removed == 0)
        #expect(swept.retainedWithAudio == 1)
        #expect(
            FileManager.default.fileExists(atPath: withAudio.path),
            "audio must survive a tidy-up; it is counted for diagnostics, not discarded"
        )
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
