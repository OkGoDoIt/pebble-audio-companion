import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// What the store does when the file system refuses a write — a full phone, in practice.
//
// Two things must hold, and neither used to. The log must stay PARSEABLE: a refused append
// leaves a torn record at the end of the file (the kernel writes what fits), the handle's offset
// sits past it, and every frame appended after that — on a reattach, or simply the next batch —
// was unreachable to `parseRecords`, which stops at the first bad record: stored, invisible, and
// claimed by the next checkpoint. And the in-memory index must stay COHERENT when the sidecar
// write on close fails: a stale "open" entry with the last flushed counters set the next
// reattach's dedupe floor below what the log really held, so the watch's re-sent tail was
// appended a second time.
//
// The failure is injected through `SegmentStore.Faults`; the ENOSPC shape is "some of the bytes,
// then the error", which is exactly what a partial write to a full volume looks like.
@Suite struct WriteFailureTests {
    private let streamId: UInt32 = 0x5EED_0F11
    private let clock = ClockBox(1_000_000)

    private func makeStore(_ root: URL) -> SegmentStore {
        SegmentStore(root: root, nowMs: { [clock] in clock.now })
    }

    private func streamStart(flags: UInt32 = 0) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 86_400_123, flags: flags)
    }

    private func frames(_ first: UInt32, _ count: Int) -> [SegmentFrame] {
        (0..<count).map { i in
            SegmentFrame(
                sequence: first + UInt32(i), sampleIndex: UInt64(first + UInt32(i)) * 320,
                payload: (0..<25).map { b in UInt8((Int(first) + i + b) & 0xFF) })
        }
    }

    private static let recordBytes = 25 + SegmentStore.recordHeaderBytes

    private static func enospc() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: nil)
    }

    /// Writes the first `partial` bytes, then refuses the rest.
    private static func partialWriteThenFull(_ partial: Int) -> SegmentStore.Faults {
        SegmentStore.Faults(logWrite: { handle, data in
            try handle.write(contentsOf: data.prefix(partial))
            throw enospc()
        })
    }

    private func logFile(_ root: URL, _ id: String) -> URL {
        root.appendingPathComponent("segments").appendingPathComponent("\(id)\(SegmentStore.logSuffix)")
    }

    private func sidecarOnDisk(_ root: URL, _ id: String) throws -> SegmentMeta {
        let url = root.appendingPathComponent("segments").appendingPathComponent("\(id)\(SegmentStore.metaSuffix)")
        return try JSONDecoder().decode(SegmentMeta.self, from: Data(contentsOf: url))
    }

    // MARK: Appends

    @Test func aRefusedAppendClaimsNothingAndLeavesTheLogParseable() async throws {
        let root = try makeTempRoot("write-fail")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 10))

        await store.injectFaults(Self.partialWriteThenFull(17))
        await #expect(throws: SegmentStoreError.storageFull(segmentId: id)) {
            _ = try await store.appendFrames(streamId: streamId, frames: frames(10, 10))
        }

        // Reported, classified, and nothing of the refused batch is on disk — not even the
        // seventeen bytes that did land.
        let failure = try #require(await store.lastWriteFailure)
        #expect(failure.isStorageFull)
        #expect(failure.operation == "frame log append")
        #expect(failure.segmentId == id)
        let size = try FileManager.default.attributesOfItem(atPath: logFile(root, id).path)[.size] as? Int
        #expect(size == 10 * Self.recordBytes, "the torn tail must be cut back to the last good record")
        #expect(await store.readFrames(id).map(\.sequence) == Array(0..<10))

        // Space comes back: the next append lands where the counters say, and every frame is
        // readable in order. The failure record clears.
        await store.injectFaults(SegmentStore.Faults())
        let stored = try await store.appendFrames(streamId: streamId, frames: frames(10, 10))
        #expect(stored.count == 10)
        #expect(await store.lastWriteFailure == nil)
        #expect(await store.readFrames(id).map(\.sequence) == Array(0..<20))
        try await store.closeSegment(reason: .interrupted)
        let meta = try #require(await store.readMeta(id))
        #expect(meta.frameCount == 20)
        #expect(meta.lastSequence == 19)
        #expect(meta.logBytes == 20 * Self.recordBytes)
        #expect(try sidecarOnDisk(root, id) == meta)
    }

    /// The same refusal, then a relaunch before any write succeeded: recovery reconciles the
    /// sidecar from the (intact) log, and the refused batch is simply not there.
    @Test func aRefusedAppendThenARelaunchRecoversExactlyTheStoredFrames() async throws {
        let root = try makeTempRoot("write-fail-relaunch")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 10))
        await store.injectFaults(Self.partialWriteThenFull(5))
        await #expect(throws: SegmentStoreError.storageFull(segmentId: id)) {
            _ = try await store.appendFrames(streamId: streamId, frames: frames(10, 10))
        }

        let relaunched = makeStore(root)
        try await relaunched.recover()
        let meta = try #require(await relaunched.readMeta(id))
        #expect(meta.closeReason?.kind == CloseReasonMeta.kindInterrupted)
        #expect(meta.frameCount == 10)
        #expect(meta.lastSequence == 9)
        #expect(await relaunched.readFrames(id).map(\.sequence) == Array(0..<10))
    }

    @Test func anIOErrorIsReportedAsAWriteFailureNotAsStorageFull() async throws {
        let root = try makeTempRoot("write-fail-eio")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        await store.injectFaults(
            SegmentStore.Faults(logWrite: { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
            }))
        do {
            _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 3))
            Issue.record("the append must throw")
        } catch SegmentStoreError.writeFailed(let segmentId, let reason) {
            #expect(segmentId == id)
            #expect(reason.hasPrefix("frame log append"))
        }
        let failure = try #require(await store.lastWriteFailure)
        #expect(!failure.isStorageFull)
        #expect(await store.readFrames(id).isEmpty)
    }

    // MARK: Sidecars

    @Test func aRefusedSidecarWriteOnCloseKeepsTheIndexCoherentForTheReattach() async throws {
        let root = try makeTempRoot("meta-fail-close")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        // Past the periodic flush, so the sidecar on disk is behind the live counters.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 300))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(300, 40))

        await store.injectFaults(SegmentStore.Faults(beforeMetaWrite: { _ in throw Self.enospc() }))
        await #expect(throws: SegmentStoreError.storageFull(segmentId: id)) {
            try await store.closeSegment(reason: .interrupted)
        }
        #expect(await store.openSegmentId == nil)
        #expect(await store.lastWriteFailure?.operation == "sidecar write")

        // What the process believes: closed, with the live counters. What the disk says: still
        // open, at the last flush. The process view is the one the reattach reads.
        let believed = try #require(await store.readMeta(id))
        #expect(believed.closeReason?.kind == CloseReasonMeta.kindInterrupted)
        #expect(believed.lastSequence == 339)
        #expect(believed.frameCount == 340)
        let onDisk = try sidecarOnDisk(root, id)
        #expect(onDisk.closeReason == nil)
        #expect(onDisk.lastSequence == 299)

        // Space comes back; the watch re-announces and rewinds to its trim point, re-sending a
        // tail the store already holds. Reattached, deduped against the LIVE floor: none of
        // 320..339 is stored twice, and the sidecar catches up.
        await store.injectFaults(SegmentStore.Faults())
        clock.now += 5_000
        let continuation = try await store.openSegment(
            start: streamStart(flags: ProtocolConstants.streamStartFlagResume),
            receivedAtMs: clock.now, provenance: nil)
        #expect(continuation?.nextSequence == 340)
        #expect(continuation?.continuesSameSegment == true)
        #expect(await store.openSegmentId == id)
        let stored = try await store.appendFrames(streamId: streamId, frames: frames(320, 30))
        #expect(stored.map(\.sequence) == Array(340..<350))
        let sequences = await store.readFrames(id).map(\.sequence)
        #expect(sequences == Array(0..<350), "no frame may be stored twice")
        try await store.closeSegment(reason: .interrupted)
        #expect(try sidecarOnDisk(root, id).lastSequence == 349)
    }

    /// The refused close, then a relaunch with no successful write in between: the on-disk
    /// sidecar still says open, and recovery reconciles it from the log.
    @Test func aRefusedSidecarWriteThenARelaunchReconcilesFromTheLog() async throws {
        let root = try makeTempRoot("meta-fail-relaunch")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 300))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(300, 40))
        await store.injectFaults(SegmentStore.Faults(beforeMetaWrite: { _ in throw Self.enospc() }))
        try? await store.closeSegment(reason: .interrupted)

        let relaunched = makeStore(root)
        try await relaunched.recover()
        let meta = try #require(await relaunched.readMeta(id))
        #expect(meta.closeReason?.kind == CloseReasonMeta.kindInterrupted)
        #expect(meta.lastSequence == 339)
        #expect(meta.frameCount == 340)
        #expect(try sidecarOnDisk(root, id) == meta)
    }

    /// A refused periodic sidecar flush mid-append: the frames ARE in the log (that write came
    /// first), the counters moved with them, and the error still goes to the caller — which is
    /// right, because the caller will fail the connection and the re-sent frames dedupe against
    /// the live counters rather than being appended again.
    @Test func aRefusedPeriodicSidecarFlushKeepsTheFramesAndTheCounters() async throws {
        let root = try makeTempRoot("meta-fail-flush")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        await store.injectFaults(SegmentStore.Faults(beforeMetaWrite: { _ in throw Self.enospc() }))
        await #expect(throws: SegmentStoreError.storageFull(segmentId: id)) {
            _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 300))
        }
        #expect(await store.readFrames(id).count == 300)
        await store.injectFaults(SegmentStore.Faults())
        // The re-send after the connection is rebuilt: nothing new, nothing duplicated.
        let again = try await store.appendFrames(streamId: streamId, frames: frames(0, 300))
        #expect(again.isEmpty)
        #expect(await store.readFrames(id).count == 300)
    }

    // MARK: Flush

    @Test func aRefusedFlushIsReportedToTheCallerAndRecorded() async throws {
        let root = try makeTempRoot("flush-fail")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 5))
        #expect(await store.unflushedBytes == 5 * Self.recordBytes)
        await store.injectFaults(SegmentStore.Faults(beforeFlush: { throw Self.enospc() }))
        await #expect(throws: SegmentStoreError.storageFull(segmentId: id)) {
            try await store.flush()
        }
        #expect(await store.unflushedBytes == 5 * Self.recordBytes, "a refused flush leaves the bytes dirty")
        #expect(await store.lastWriteFailure?.operation == "flush")
        // Still dirty: the next flush has to do the work, not skip it. The record stays until a
        // frame-log append succeeds — a flush that goes through says nothing about room on the
        // volume.
        await store.injectFaults(SegmentStore.Faults())
        try await store.flush()
        #expect(await store.lastWriteFailure?.operation == "flush")
        _ = try await store.appendFrames(streamId: streamId, frames: frames(5, 1))
        #expect(await store.lastWriteFailure == nil)
    }

    /// The record of a refused append must survive the small sidecar write that follows it
    /// (the close), or Diagnostics would show a clean slate on a disk that is still full.
    @Test func theRecordOfARefusedAppendSurvivesASuccessfulSidecarWrite() async throws {
        let root = try makeTempRoot("write-fail-sticky")
        let store = makeStore(root)
        try await store.openSegment(start: streamStart(), receivedAtMs: clock.now, provenance: nil)
        let id = try #require(await store.openSegmentId)
        await store.injectFaults(Self.partialWriteThenFull(0))
        try? await store.appendFrames(streamId: streamId, frames: frames(0, 3))
        await store.injectFaults(SegmentStore.Faults())
        try await store.closeSegment(reason: .interrupted)
        #expect(await store.lastWriteFailure?.segmentId == id)
        #expect(await store.lastWriteFailure?.operation == "frame log append")
    }

    // MARK: Classification

    @Test func storageFullIsRecognisedInEveryShapeItArrivesIn() {
        #expect(SegmentStore.isStorageFull(Self.enospc()))
        #expect(SegmentStore.isStorageFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        #expect(
            SegmentStore.isStorageFull(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(
            SegmentStore.isStorageFull(
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                    userInfo: [NSUnderlyingErrorKey: Self.enospc()])))
        #expect(!SegmentStore.isStorageFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
        #expect(!SegmentStore.isStorageFull(SegmentStoreError.noOpenSegment(streamId: 1)))
    }
}
