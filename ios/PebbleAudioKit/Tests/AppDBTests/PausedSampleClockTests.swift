import Foundation
import SegmentStore
import Testing

@testable import AppDB

// The watch's sample count is not wall time. On G17 (stream 3254668809) recordings arrived a
// steady 27–30 s after their sample-clock time from 2026-10-23 to 10-25 14:09Z, then fell back
// about a minute an hour overnight to 910 s by 10-26 05:26Z: everything after that was filed
// 15 minutes early, with its transcript, its day and its marked moments. Every recording is now
// placed by its own arrival evidence, `SegmentMeta.deliveryMs` before it
// (`SegmentMeta.sampleClockAnchorMs`); spooled backfill, which arrives late and then catches
// up, is not shifted.

@Suite("a sample clock that fell behind")
struct PausedSampleClockTests {
    static let stream: UInt32 = 3_254_668_809
    /// 2026-10-23 00:00Z, the stream's birth on the watch's clock.
    static let birth: Int64 = 1_792_713_600_000
    /// 2026-10-25 14:09Z, the last of the steady lag.
    static let driftBegins: Int64 = 1_792_937_340_000
    /// 2026-10-26 05:26Z, 910 s behind.
    static let driftEnds: Int64 = 1_792_992_360_000
    static let rotation: Int64 = 15 * 60_000

    /// One recording of the stream. Its first frame reached the phone at `arrivedAtMs`, `lagMs`
    /// after that frame's sample-clock time; its newest frame `spanMs` later, `headLagMs` behind.
    /// `headEvidence: false` is a sidecar from before `headReceivedAtMs`: the close is all the
    /// evidence there is. `open` has no close at all.
    static func recording(
        _ id: String = "seg-1", arrivedAtMs: Int64, lagMs: Int64, headLagMs: Int64? = nil,
        spanMs: Int64 = rotation, headEvidence: Bool = true, open: Bool = false
    ) -> SegmentMeta {
        let headLag = headLagMs ?? lagMs
        let headArrival = arrivedAtMs + spanMs
        let first = UInt64(arrivedAtMs - lagMs - birth) * 16
        let last = UInt64(headArrival - headLag - birth) * 16
        var meta = makeSegment(
            id: id, stream: stream, startTimeMs: birth, firstSample: first,
            durationSamples: last - first, close: open ? nil : .rotated, tz: "UTC")
        meta.receivedAtMs = arrivedAtMs
        meta.closedAtMs = open ? nil : headArrival
        meta.headReceivedAtMs = headEvidence ? headArrival : nil
        return meta
    }

    @Test("G17's steady half-minute lag: placed its delivery time before its arrival")
    func steadyLag() {
        let arrived = Self.driftBegins - Self.rotation
        let meta = Self.recording(arrivedAtMs: arrived, lagMs: 28_000, headLagMs: 30_000)
        #expect(meta.sampleClockLagMs == 28_000)
        #expect(meta.sampleClockAnchorMs == Self.birth + 26_000)
        #expect(meta.startWallMs == arrived - SegmentMeta.deliveryMs)
    }

    @Test("G17 fifteen minutes behind is placed by its arrival, and every mapping agrees")
    func fifteenMinutesBehindPlacedByArrival() throws {
        let arrived = Self.driftEnds
        let placed = arrived - SegmentMeta.deliveryMs
        let meta = Self.recording(arrivedAtMs: arrived, lagMs: 910_000, headLagMs: 912_000)
        #expect(meta.sampleClockLagMs == 910_000)
        #expect(meta.startWallMs == placed)
        #expect(ConversationGrouper.segmentStartMs(meta) == placed)
        let first = try #require(meta.firstSampleIndex)
        #expect(ConversationGrouper.wallMs(ofSample: first + 60 * 16_000, in: meta) == placed + 60_000)
        #expect(SegmentMediaClock(meta).startWallMs == placed)
        // The sidecar keeps what the watch sent.
        #expect(meta.startTimeMs == UInt64(Self.birth))

        // The recording still open, with only its first frame's arrival to go on.
        var opened = Self.recording(arrivedAtMs: arrived, lagMs: 910_000, open: true)
        opened.headReceivedAtMs = nil
        #expect(opened.isOpen)
        #expect(opened.startWallMs == placed)
    }

    @Test("spooled backfill arrives late and catches up, so it is not shifted")
    func backfillThatCaughtUpIsNotShifted() {
        // A reconnect drains a spool whose 98 s of speech spanned six quiet-skipped minutes; the
        // newest frame then arrives three seconds after it was recorded.
        let arrived = Self.driftBegins - 4 * Self.rotation
        let meta = Self.recording(arrivedAtMs: arrived, lagMs: 6 * 60_000, headLagMs: 3_000)
        #expect(meta.sampleClockLagMs == 3_000)
        #expect(meta.startWallMs == arrived - 6 * 60_000 + 1_000)

        // A sidecar written before `headReceivedAtMs` reads the same from its close.
        let older = Self.recording(
            arrivedAtMs: arrived, lagMs: 6 * 60_000, headLagMs: 3_000, headEvidence: false)
        #expect(older.headReceivedAtMs == nil)
        #expect(older.startWallMs == arrived - 6 * 60_000 + 1_000)
    }

    @Test("a pause inside a recording keeps its start; the next recording carries it")
    func pauseInsideKeepsItsStart() {
        let arrived = Self.driftBegins
        let paused = Self.recording(arrivedAtMs: arrived, lagMs: 30_000, headLagMs: 150_000)
        #expect(paused.startWallMs == arrived - SegmentMeta.deliveryMs)
        let next = Self.recording(
            "seg-2", arrivedAtMs: arrived + Self.rotation, lagMs: 150_000, headLagMs: 152_000)
        #expect(next.startWallMs == arrived + Self.rotation - SegmentMeta.deliveryMs)
        // The time the clock lost shows as a stretch between them, never as an overlap.
        #expect(ConversationGrouper.segmentEndMs(paused) == next.startWallMs - 120_000)
    }

    @Test("the overnight drift: every recording where it was recorded, none overlapping")
    func overnightDrift() {
        func lag(at t: Int64) -> Int64 {
            let grown = min(max(t - Self.driftBegins, 0), Self.driftEnds - Self.driftBegins)
            return 28_000 + grown * 882_000 / (Self.driftEnds - Self.driftBegins)
        }
        var previous: SegmentMeta?
        var count = 0
        var arrived = Self.driftBegins - 8 * Self.rotation
        while arrived <= Self.driftEnds + 4 * Self.rotation {
            let meta = Self.recording(
                "seg-\(arrived)", arrivedAtMs: arrived, lagMs: lag(at: arrived),
                headLagMs: lag(at: arrived + Self.rotation))
            // Recorded two seconds before it arrived; the sample clock said up to 15 min earlier.
            #expect(meta.startWallMs == arrived - SegmentMeta.deliveryMs, "\(arrived)")
            if let previous {
                #expect(ConversationGrouper.segmentEndMs(previous) <= meta.startWallMs, "\(arrived)")
            }
            previous = meta
            count += 1
            arrived += Self.rotation
        }
        #expect(count > 70)
    }

    @Test("a clock already on time, ahead, or never set keeps its own rule")
    func otherClocksUnchanged() {
        let onTime = Self.recording(arrivedAtMs: Self.driftBegins, lagMs: 1_500)
        #expect(onTime.sampleClockAnchorMs == Self.birth)
        #expect(onTime.startWallMs == Self.driftBegins - 1_500)

        let ahead = Self.recording(arrivedAtMs: Self.driftBegins, lagMs: -20_000)
        #expect(ahead.sampleClockAnchorMs == Self.birth)
        #expect(ahead.startWallMs == Self.driftBegins)

        var unset = Self.recording(arrivedAtMs: Self.driftBegins, lagMs: 0)
        unset.startTimeMs = 1_262_304_012_425
        #expect(unset.sampleClockLagMs == nil)
        #expect(unset.startWallMs == Self.driftBegins)
    }

    @Test("a mark goes where its recording now sits: the watch's clock, unless the sample clock is on time")
    func markWallMs() {
        let marked = Self.driftEnds
        #expect(SegmentMeta.markWallMs(sampleClockMs: marked - 910_000, watchClockMs: marked) == marked)
        #expect(SegmentMeta.markWallMs(sampleClockMs: marked - 28_000, watchClockMs: marked) == marked)
        #expect(
            SegmentMeta.markWallMs(sampleClockMs: marked - 1_000, watchClockMs: marked) == marked - 1_000)
        #expect(
            SegmentMeta.markWallMs(sampleClockMs: marked, watchClockMs: 1_262_304_012_425) == marked)
    }

    @Test("stored marks on the lagging clock are moved once and their reviews read again")
    func storedMarksRepaired() async throws {
        let database = try AppDatabase.inMemory()
        let store = MomentStore(db: database)
        let marked = Self.driftEnds
        try await store.add(
            Moment(id: "watch-\(marked)-7", wallMs: marked - 910_000, onAudioClock: true, createdAtMs: marked))
        try await store.add(
            Moment(id: "watch-\(marked + 60_000)-8", wallMs: marked + 59_000, onAudioClock: true,
                   createdAtMs: marked + 60_000))
        try await store.add(
            Moment(id: "watch-\(marked + 120_000)-9", wallMs: marked + 100_000, onAudioClock: false,
                   createdAtMs: marked + 120_000))
        try await store.saveReview(
            id: "watch-\(marked)-7", review: MomentReview(summary: "The wrong minute", suggestions: []),
            state: "reviewed")

        for _ in 0..<2 {
            try await database.writer.write { try MomentStore.repairPausedClockMarks($0) }
        }
        let read = try await store.moments(fromWallMs: 0, to: .max)
        #expect(read.map(\.wallMs) == [marked, marked + 59_000, marked + 100_000])
        #expect(read[0].review == nil)
        #expect(read[0].reviewState == "pending")
    }
}
