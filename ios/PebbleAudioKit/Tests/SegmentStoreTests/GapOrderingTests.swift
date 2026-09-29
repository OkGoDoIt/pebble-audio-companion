import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// How a segment's gap list takes a record that arrives out of sequence order.
//
// That is the ordinary shape of a RESUME, not an edge case: the watch drains its pending gap
// table first, so its overflow records are stored before the receiver has seen any audio, and
// the hole BELOW them only shows up when the buffered audio arrives. The store used to compare
// each new record with the LAST one only and "merge" it whenever it started before that one's
// end — without moving the start back — so the earlier range simply vanished. On 2026-09-24
// 17:37 seven held overflow records went in, the receiver's skip for 11975590..11976422
// followed, and the 352 frames between the overflow records were left with no record at all.
@Suite struct GapOrderingTests {
    private let streamId: UInt32 = 0x5EED_0002

    private func openStore() async throws -> (SegmentStore, String) {
        let store = SegmentStore(root: try makeTempRoot("gap-order"), nowMs: { 1_000_000 })
        try await store.openSegment(
            start: StreamStart(
                protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1,
                frameSamples: 320, sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
                startTimeMs: 1_781_000_000_000, startMonotonicMs: 1, flags: 0),
            receivedAtMs: 1_000_000, provenance: nil)
        return (store, try #require(await store.openSegmentId))
    }

    private func overflow(_ first: UInt32, _ count: UInt32, counter: UInt32 = 0) -> GapRecord {
        GapRecord(
            firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320,
            origin: .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: counter))
    }

    private func skip(_ first: UInt32, _ count: UInt32) -> GapRecord {
        GapRecord(
            firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320, origin: .sequenceSkip)
    }

    private func ranges(_ gaps: [GapMeta]) -> [String] {
        gaps.map { "\($0.origin)[\($0.firstMissingSequence),\(UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)))" }
    }

    @Test("a record that arrives below the last one is kept, in sequence order")
    func aLowerRecordIsNotSwallowed() async throws {
        let (store, id) = try await openStore()
        // The watch's held notices first, then the receiver's skip for the hole under them.
        try await store.recordGap(streamId: streamId, gap: overflow(100, 10))
        try await store.recordGap(streamId: streamId, gap: overflow(120, 10))
        try await store.recordGap(streamId: streamId, gap: skip(90, 10))

        let gaps = try #require(await store.readMeta(id)).gaps
        #expect(ranges(gaps) == ["sequence_skip[90,100)", "watch[100,110)", "watch[120,130)"])
        #expect(gaps[0].firstMissingSampleIndex == 90 * 320)
    }

    @Test("a skip across the watch's records keeps exactly the frames the watch never mentioned")
    func aSkipIsCutBackToWhatTheWatchDidNotAccountFor() async throws {
        let (store, id) = try await openStore()
        // The 2026-09-24 17:37 shape: overflow records with holes between them, then one skip
        // from the last stored frame to the first frame after the reconnect.
        try await store.recordGap(streamId: streamId, gap: overflow(100, 10))
        try await store.recordGap(streamId: streamId, gap: overflow(120, 10))
        try await store.recordGap(streamId: streamId, gap: overflow(140, 10))
        try await store.recordGap(streamId: streamId, gap: skip(95, 65))

        let gaps = try #require(await store.readMeta(id)).gaps
        #expect(
            ranges(gaps) == [
                "sequence_skip[95,100)", "watch[100,110)", "sequence_skip[110,120)",
                "watch[120,130)", "sequence_skip[130,140)", "watch[140,150)",
                "sequence_skip[150,160)",
            ])
        // Each piece of the skip sits on the sample clock where its frames were.
        #expect(gaps[2].firstMissingSampleIndex == 110 * 320)
        #expect(gaps[6].firstMissingSampleIndex == 150 * 320)
        // Every frame of the hole is claimed, and none twice.
        #expect(gaps.reduce(0) { $0 + Int($1.missingFrameCount) } == 65)
    }

    @Test("touching records merge only when they tell the same story")
    func touchingRecordsWithDifferentStoriesStayApart() async throws {
        let (store, id) = try await openStore()
        try await store.recordGap(streamId: streamId, gap: skip(90, 10))
        try await store.recordGap(streamId: streamId, gap: overflow(100, 10, counter: 10))
        try await store.recordGap(streamId: streamId, gap: overflow(110, 5, counter: 15))

        let gaps = try #require(await store.readMeta(id)).gaps
        // The phone's skip and the watch's overflow are two facts; the two overflow notices are
        // one period and keep the newer drop counter.
        #expect(ranges(gaps) == ["sequence_skip[90,100)", "watch[100,115)"])
        #expect(gaps[1].reasonRaw == Int(GapReason.spoolOverflow.rawValue))
        #expect(gaps[1].watchDropCounter == 15)
    }

    @Test("overlapping watch records with different reasons each keep their own frames")
    func overlappingRecordsWithDifferentReasonsAreTrimmedNotOverwritten() async throws {
        let (store, id) = try await openStore()
        try await store.recordGap(streamId: streamId, gap: overflow(100, 20))
        try await store.recordGap(
            streamId: streamId,
            gap: GapRecord(
                firstMissingSequence: 90, missingFrameCount: 20, firstMissingSampleIndex: 90 * 320,
                origin: .watchReported(reasonRaw: Int(GapReason.transportReset.rawValue), watchDropCounter: 0)))

        let gaps = try #require(await store.readMeta(id)).gaps
        #expect(ranges(gaps) == ["watch[90,110)", "watch[110,120)"])
        #expect(gaps[0].reasonRaw == Int(GapReason.transportReset.rawValue))
        #expect(gaps[1].reasonRaw == Int(GapReason.spoolOverflow.rawValue))
        #expect(gaps[1].firstMissingSampleIndex == 110 * 320)
    }

    @Test("any arrival order yields the same sorted, non-overlapping list covering the same frames")
    func arrivalOrderDoesNotChangeWhatIsRecorded() async throws {
        // A fixed pseudo-random mix of overflow notices, receiver skips and quiet notices, fed in
        // many orders.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: UInt64) -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (seed >> 33) % bound
        }
        var records: [GapRecord] = []
        for _ in 0..<30 {
            let first = UInt32(next(400))
            let count = UInt32(1 + next(40))
            switch next(3) {
            case 0: records.append(overflow(first, count))
            case 1: records.append(skip(first, count))
            default: records.append(quiet(first, count))
            }
        }
        func covered(_ gaps: [GapMeta]) -> Set<UInt32> {
            var set = Set<UInt32>()
            for gap in gaps { for s in gap.firstMissingSequence..<(gap.firstMissingSequence + gap.missingFrameCount) { set.insert(s) } }
            return set
        }
        let input = records.map(GapMeta.from)
        let watchLoss = covered(input.filter { $0.origin == GapMeta.originWatch && $0.countsAsLoss })
        let watchQuiet = covered(input.filter { !$0.countsAsLoss })
        let skips = covered(input.filter { $0.origin == GapMeta.originSequenceSkip })
        // What must come out: the watch's loss as the watch said it; the receiver's skips only
        // where the watch said nothing; quiet only where nothing says loss.
        let expectedLoss = watchLoss.union(skips.subtracting(watchQuiet))
        let expectedQuiet = watchQuiet.subtracting(expectedLoss)

        var reference: [GapMeta]?
        for round in 0..<12 {
            let (store, id) = try await openStore()
            var order = records
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                order.swapAt(i, Int(next(UInt64(i + 1))))
            }
            if round == 0 { order = records }
            for record in order { try await store.recordGap(streamId: streamId, gap: record) }
            let gaps = try #require(await store.readMeta(id)).gaps

            #expect(covered(gaps.filter(\.countsAsLoss)) == expectedLoss, "loss lost a claim")
            #expect(covered(gaps.filter { !$0.countsAsLoss }) == expectedQuiet)
            #expect(covered(gaps.filter { $0.origin == GapMeta.originWatch && $0.countsAsLoss }) == watchLoss)
            for (a, b) in zip(gaps, gaps.dropFirst()) {
                #expect(a.endExclusive <= UInt64(b.firstMissingSequence), "records overlap: \(ranges([a, b]))")
            }
            #expect(
                gaps.reduce(0) { $0 + Int($1.missingFrameCount) } == expectedLoss.count + expectedQuiet.count,
                "a frame is claimed twice")
            if let reference {
                #expect(gaps == reference, "the stored list depends on arrival order")
            } else {
                reference = gaps
            }
        }
    }

    private func quiet(_ first: UInt32, _ count: UInt32) -> GapRecord {
        GapRecord(
            firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320,
            origin: .watchReported(reasonRaw: Int(GapReason.silenceSuppressed.rawValue), watchDropCounter: 0))
    }

    @Test("quiet never merges into loss, and loss keeps frames the watch also called quiet")
    func quietAndLossStayApartAndLossWins() async throws {
        let (store, id) = try await openStore()
        try await store.recordGap(streamId: streamId, gap: quiet(100, 20))
        try await store.recordGap(streamId: streamId, gap: overflow(110, 20))
        try await store.recordGap(streamId: streamId, gap: quiet(130, 10))

        let gaps = try #require(await store.readMeta(id)).gaps
        // 100..109 quiet; 110..129 lost (the overflow keeps the frames the watch ALSO called
        // quiet — quiet over real loss would hide it); 130..139 quiet again, touching the loss
        // but never folded into it.
        #expect(ranges(gaps) == ["watch[100,110)", "watch[110,130)", "watch[130,140)"])
        #expect(gaps.map(\.countsAsLoss) == [false, true, false])
    }

    @Test("consecutive quiet notices become one quiet period")
    func consecutiveQuietMerges() async throws {
        let (store, id) = try await openStore()
        try await store.recordGap(streamId: streamId, gap: quiet(10, 10))
        try await store.recordGap(streamId: streamId, gap: quiet(20, 15))

        let gaps = try #require(await store.readMeta(id)).gaps
        #expect(ranges(gaps) == ["watch[10,35)"])
        #expect(!gaps[0].countsAsLoss)
    }

    @Test("a receiver skip is dropped where the watch later says the frames were quiet")
    func aSkipOverReportedQuietIsNotLoss() async throws {
        let (store, id) = try await openStore()
        // The phone saw the jump before the watch's quiet notice reached it.
        try await store.recordGap(streamId: streamId, gap: skip(50, 30))
        try await store.recordGap(streamId: streamId, gap: quiet(50, 20))

        let gaps = try #require(await store.readMeta(id)).gaps
        // The 20 frames the watch accounts for are quiet; the 10 it never mentioned stay loss.
        #expect(ranges(gaps) == ["watch[50,70)", "sequence_skip[70,80)"])
        #expect(gaps.map(\.countsAsLoss) == [false, true])
    }

    @Test("stored quiet lets the media clock map exactly across it")
    func storedQuietMakesTheMediaClockExact() async throws {
        let (store, id) = try await openStore()
        func frames(_ first: UInt32, _ count: Int) -> [SegmentFrame] {
            (0..<count).map { i in
                SegmentFrame(
                    sequence: first + UInt32(i), sampleIndex: UInt64(first + UInt32(i)) * 320,
                    payload: [0x5A, 0x5A])
            }
        }
        // 2 s of speech, 10 s the watch skipped as quiet, 2 s of speech.
        _ = try await store.appendFrames(streamId: streamId, frames: frames(0, 100))
        try await store.recordGap(streamId: streamId, gap: quiet(100, 500))
        _ = try await store.appendFrames(streamId: streamId, frames: frames(600, 100))
        try await store.closeSegment(reason: .interrupted)

        let meta = try #require(await store.readMeta(id))
        let clock = SegmentMediaClock(meta)
        #expect(clock.wallSpanMs == 14_000)
        #expect(clock.mediaSpanMs == 4_000)
        #expect(clock.recordedGapMs == 10_000)
        #expect(clock.isExact, "without the quiet record the clock falls back to a proportional guess")
        // The first word after the quiet is 12 s into the recording, 2 s into the stored audio.
        #expect(clock.wall(fromMedia: 2_000) == 12_000)
        #expect(clock.media(fromWall: 12_000) == 2_000)
    }
}
