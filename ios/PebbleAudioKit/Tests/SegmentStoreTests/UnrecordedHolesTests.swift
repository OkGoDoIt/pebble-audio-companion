import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// The quiet an older build discarded, recorded after the fact (`UnrecordedHoles.swift`).
//
// Before 42dc693 the store dropped every `silenceSuppressed` notice the receiver handed it, and
// the receiver — having accounted for the jump with that very notice — synthesized no skip. So a
// recording from then holds its quiet as bare holes in its sequence numbers: the backup of
// 2026-09-30 01:14 has 330 such recordings, 54 h, drawn everywhere as recorded audio.
@Suite struct UnrecordedHolesTests {
    private let streamId: UInt32 = 0x5EED_0003
    private let quiet = Int(GapReason.silenceSuppressed.rawValue)

    private func frames(_ sequences: ClosedRange<UInt32>...) -> [StoredFramePosition] {
        sequences.flatMap { $0 }.map { StoredFramePosition(sequence: $0, sampleIndex: UInt64($0) * 320) }
    }

    private func meta(_ first: UInt32, _ last: UInt32, frameCount: Int64, gaps: [GapMeta] = []) -> SegmentMeta {
        var meta = SegmentMeta(
            segmentId: "seg-test", streamId: streamId, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1, receivedAtMs: 1)
        meta.firstSequence = first
        meta.lastSequence = last
        meta.frameCount = frameCount
        meta.gaps = gaps
        return meta
    }

    private func watch(_ reason: GapReason, _ first: UInt32, _ count: UInt32) -> GapMeta {
        GapMeta(
            firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320, origin: GapMeta.originWatch,
            reasonRaw: Int(reason.rawValue))
    }

    private func describe(_ gaps: [GapMeta]) -> [String] {
        gaps.map {
            "\($0.origin)/\($0.reasonRaw.map(String.init) ?? "-")"
                + "[\($0.firstMissingSequence),\(UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)))"
        }
    }

    // MARK: - what a hole is taken to be

    @Test("a hole no record explains is quiet, placed on the sample clock where its frames were")
    func aFreeStandingHoleIsQuiet() {
        let records = unrecordedHoleRecords(
            in: meta(0, 29, frameCount: 20), frames: frames(0...9, 20...29))
        #expect(describe(records) == ["frame_log_hole/8[10,20)"])
        #expect(records[0].firstMissingSampleIndex == 10 * 320)
        // Quiet everywhere quiet is read: the classifier, the loss lane, the strip's recut.
        #expect(GapClassifier(records).classify(records[0]) == .quiet)
        #expect(!records[0].countsAsLoss)
    }

    @Test("only the part of a hole no record already covers is added")
    func recordedPartsAreLeftAlone() {
        let existing = [watch(.silenceSuppressed, 12, 4)]
        let records = unrecordedHoleRecords(
            in: meta(0, 29, frameCount: 20, gaps: existing), frames: frames(0...9, 20...29))
        #expect(describe(records) == ["frame_log_hole/8[10,12)", "frame_log_hole/8[16,20)"])
    }

    @Test("a hole touching a record of loss is loss of unknown cause, never quiet laid over it")
    func aHoleBesideLossFailsClosed() {
        // The RESUME-seed shape: an unrecorded run ending exactly where the watch's first
        // overflow record starts; and the out-of-order merge's: frames between two overflows.
        let existing = [watch(.spoolOverflow, 15, 5), watch(.spoolOverflow, 22, 3)]
        let records = unrecordedHoleRecords(
            in: meta(0, 39, frameCount: 20, gaps: existing), frames: frames(0...9, 30...39))
        #expect(
            describe(records)
                == ["frame_log_hole/-[10,15)", "frame_log_hole/-[20,22)", "frame_log_hole/-[25,30)"])
        let classifier = GapClassifier(existing + records)
        #expect(records.allSatisfy { classifier.classify($0) == .loss })
    }

    @Test("a hole beside the watch's power-save pause fails closed too")
    func aHoleBesideAPauseIsLoss() {
        let records = unrecordedHoleRecords(
            in: meta(0, 29, frameCount: 20, gaps: [watch(.powerSave, 15, 5)]),
            frames: frames(0...9, 20...29))
        #expect(describe(records) == ["frame_log_hole/-[10,15)"])
    }

    @Test("a hole beside the watch's own quiet stays quiet")
    func aHoleBesideQuietIsQuiet() {
        let records = unrecordedHoleRecords(
            in: meta(0, 29, frameCount: 20, gaps: [watch(.silenceSuppressed, 15, 5)]),
            frames: frames(0...9, 20...29))
        #expect(describe(records) == ["frame_log_hole/8[10,15)"])
    }

    @Test("frames out of order on disk (a refill) and stored twice make no hole")
    func orderAndDuplicatesDoNotMatter() {
        let shuffled = frames(20...29, 0...9, 5...5)
        #expect(describe(unrecordedHoleRecords(in: meta(0, 29, frameCount: 21), frames: shuffled))
            == ["frame_log_hole/8[10,20)"])
        #expect(unrecordedHoleRecords(in: meta(0, 9, frameCount: 10), frames: frames(0...9)).isEmpty)
    }

    // MARK: - the sidecar test that decides whether a log is read at all

    @Test("unaccounted frames come from the sidecar alone, and a repaired one has none")
    func unaccountedFrameArithmetic() {
        #expect(meta(0, 29, frameCount: 20).unaccountedFrameCount == 10)
        #expect(meta(0, 29, frameCount: 20, gaps: [watch(.silenceSuppressed, 10, 10)]).unaccountedFrameCount == 0)
        // A record reaching outside the span only counts inside it.
        #expect(meta(0, 29, frameCount: 20, gaps: [watch(.spoolOverflow, 25, 50)]).unaccountedFrameCount == 5)
        #expect(meta(0, 29, frameCount: 30).unaccountedFrameCount == 0)
        var noFrames = meta(0, 0, frameCount: 0)
        noFrames.firstSequence = nil
        #expect(noFrames.unaccountedFrameCount == 0)
    }

    @Test("the payload-free scan reads the same positions as the full parse")
    func positionsMatchParse() {
        var writer = WireWriter()
        for (sequence, payload) in [(UInt32(7), [UInt8](repeating: 1, count: 38)), (9, [2, 3]), (8, [])] {
            writer.u32(sequence)
            writer.u64(UInt64(sequence) * 320)
            writer.u16(payload.count)
            writer.bytes(payload)
        }
        var bytes = [UInt8](writer.toData())
        bytes += [1, 2, 3]  // a torn tail
        let parsed = SegmentFrameLog.parse(bytes).records
        #expect(SegmentFrameLog.positions(bytes)
            == parsed.map { StoredFramePosition(sequence: $0.sequence, sampleIndex: $0.sampleIndex) })
        #expect(parsed.count == 3)
    }

    // MARK: - the repair, on a store

    private func start() -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1, flags: 0)
    }

    private func append(_ store: SegmentStore, _ sequences: ClosedRange<UInt32>) async throws {
        _ = try await store.appendFrames(
            streamId: streamId,
            frames: sequences.map {
                SegmentFrame(sequence: $0, sampleIndex: UInt64($0) * 320, payload: [0xAB, 0xCD])
            })
    }

    /// A recording the old build made: frames with holes, nothing recording why.
    private func oldRecording(
        _ store: SegmentStore, at receivedAtMs: Int64, _ runs: [ClosedRange<UInt32>]
    ) async throws -> String {
        try await store.openSegment(start: start(), receivedAtMs: receivedAtMs, provenance: nil)
        let id = try #require(await store.openSegmentId)
        for run in runs { try await append(store, run) }
        try await store.closeSegment(reason: .interrupted)
        return id
    }

    /// A recording a build that keeps quiet made: its quiet is the watch's own record.
    private func keptQuietRecording(
        _ store: SegmentStore, at receivedAtMs: Int64, base: UInt32
    ) async throws -> String {
        try await store.openSegment(start: start(), receivedAtMs: receivedAtMs, provenance: nil)
        let id = try #require(await store.openSegmentId)
        try await append(store, base...(base + 9))
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: base + 10, missingFrameCount: 10,
                firstMissingSampleIndex: UInt64(base + 10) * 320,
                origin: .watchReported(reasonRaw: quiet, watchDropCounter: 0)))
        try await append(store, (base + 20)...(base + 29))
        return id
    }

    @Test("recordings from before the first kept quiet record get their holes recorded; nothing after it is touched")
    func repairsOnlyWhatTheOldBuildMade() async throws {
        let store = SegmentStore(root: try makeTempRoot("unrecorded-holes"), nowMs: { 5_000_000 })
        let old = try await oldRecording(store, at: 1_000, [0...9, 20...29, 40...49])
        // Recorded by the fixed build, but with a hole of its own: that could only be a receiver
        // fault, and must stay unexplained rather than be called quiet.
        let later = try await oldRecording(store, at: 3_000, [100...109, 120...129])
        let kept = try await keptQuietRecording(store, at: 2_000, base: 200)
        try await store.closeSegment(reason: .interrupted)

        let repair = try await store.accountForUnrecordedHoles()
        #expect(repair.repaired == 1)
        #expect(repair.quietFrames == 20)
        #expect(repair.lossFrames == 0)
        #expect(repair.remaining == 0)

        let repaired = try #require(await store.readMeta(old))
        #expect(describe(repaired.gaps) == ["frame_log_hole/8[10,20)", "frame_log_hole/8[30,40)"])
        #expect(repaired.unaccountedFrameCount == 0)
        #expect(try #require(await store.readMeta(later)).gaps.isEmpty)
        #expect(describe(try #require(await store.readMeta(kept)).gaps) == ["watch/8[210,220)"])

        // Nothing left: the next call reads no log and writes nothing.
        #expect(try await store.accountForUnrecordedHoles() == UnrecordedHoleRepair())

        // It is on disk, not just in the index: a fresh store over the same root sees it.
        let reopened = SegmentStore(root: store.rootURL, nowMs: { 5_000_000 })
        try await reopened.recover()
        #expect(describe(try #require(await reopened.readMeta(old)).gaps)
            == ["frame_log_hole/8[10,20)", "frame_log_hole/8[30,40)"])
    }

    @Test("with no kept quiet record anywhere there is no evidence, and nothing is inferred")
    func noEvidenceNoInference() async throws {
        let store = SegmentStore(root: try makeTempRoot("unrecorded-holes"), nowMs: { 5_000_000 })
        let old = try await oldRecording(store, at: 1_000, [0...9, 20...29])
        #expect(try await store.accountForUnrecordedHoles() == UnrecordedHoleRepair())
        #expect(try #require(await store.readMeta(old)).gaps.isEmpty)
    }

    @Test("the byte budget bounds a call, newest first, and always makes progress")
    func budgetIsBoundedAndProgresses() async throws {
        let store = SegmentStore(root: try makeTempRoot("unrecorded-holes"), nowMs: { 5_000_000 })
        let first = try await oldRecording(store, at: 1_000, [0...9, 20...29])
        let second = try await oldRecording(store, at: 1_100, [30...39, 50...59])
        _ = try await keptQuietRecording(store, at: 2_000, base: 200)
        try await store.closeSegment(reason: .interrupted)

        let one = try await store.accountForUnrecordedHoles(maxLogBytes: 1)
        #expect(one.repaired == 1)
        #expect(one.remaining == 1)
        #expect(try #require(await store.readMeta(second)).unaccountedFrameCount == 0)
        #expect(try #require(await store.readMeta(first)).unaccountedFrameCount == 10)

        let two = try await store.accountForUnrecordedHoles(maxLogBytes: 1)
        #expect(two.repaired == 1)
        #expect(two.remaining == 0)
        #expect(try #require(await store.readMeta(first)).unaccountedFrameCount == 0)
    }

    @Test("the open recording is never rewritten behind the receiver's back")
    func theOpenRecordingIsLeftAlone() async throws {
        let store = SegmentStore(root: try makeTempRoot("unrecorded-holes"), nowMs: { 5_000_000 })
        _ = try await keptQuietRecording(store, at: 2_000, base: 200)
        try await store.closeSegment(reason: .interrupted)
        // Opened "before" the evidence by its receive stamp, but still open.
        try await store.openSegment(start: start(), receivedAtMs: 1_000, provenance: nil)
        let open = try #require(await store.openSegmentId)
        try await append(store, 0...9)
        try await append(store, 20...29)
        #expect(try await store.accountForUnrecordedHoles() == UnrecordedHoleRepair())
        #expect(try #require(await store.readMeta(open)).gaps.isEmpty)
    }
}
