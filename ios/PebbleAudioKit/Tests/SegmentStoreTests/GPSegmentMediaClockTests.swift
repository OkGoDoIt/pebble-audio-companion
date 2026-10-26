import Foundation
import Testing
import WireProtocol

@testable import SegmentStore

// The wall↔media conversion, exercised against the shape watch-side silence suppression is
// about to produce for the first time.
//
// The feature (PebbleOS a47acac74) had fired ZERO times in 88 days: its entry rule wanted N
// consecutive frames under threshold and a wrist never delivers them. It now arms on "at least
// 98% of the last 5-20 s was quiet" and writes one `silenceSuppressed` gap record per run. The
// firmware's own simulation over 116.5 h of this watch's recordings puts that at 4.1% / 8.7% /
// 13.8% of airtime withheld across 60-200 episodes an hour, which at this library's 1.5 h of
// capture a day is 90-300 records a day where there were none.
//
// The consequence for timing is arithmetic and unavoidable: every withheld millisecond is
// elapsed time with no stored frame, so the provider's clock — which counts stored frames and
// nothing else — falls behind the wall clock by the whole suppressed prefix. These fixtures
// build that segment and pin the conversion that undoes it.

@Suite("segment media clock — silence-suppressed segments")
struct GPSegmentMediaClockTests {

    /// A closed 16 kHz / 20 ms segment of `wallMs`, with `runs` of withheld silence in it.
    private func suppressedMeta(
        wallMs: Int64,
        runs: [(startMs: Int64, durationMs: Int64)],
        reason: GapReason = .silenceSuppressed
    ) -> SegmentMeta {
        let withheld = runs.reduce(Int64(0)) { $0 + $1.durationMs }
        return SegmentMeta(
            segmentId: "seg-gp",
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 1_700_000_000_000,
            startMonotonicMs: 0,
            receivedAtMs: 1_700_000_000_000 + wallMs,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(wallMs) * 16,
            headReceivedAtMs: 1_700_000_000_000 + wallMs,
            frameCount: (wallMs - withheld) / 20,
            gaps: runs.map { run in
                GapMeta(
                    firstMissingSequence: UInt32(run.startMs / 20),
                    missingFrameCount: UInt32(run.durationMs / 20),
                    firstMissingSampleIndex: UInt64(run.startMs) * 16,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(reason.rawValue)
                )
            },
            closeReason: .rotated
        )
    }

    /// Suppression runs at the firmware's own measured shape for balanced mode: 110 episodes an
    /// hour, 8.7% of airtime, so a 15-minute segment withholds ~78 s across ~28 runs.
    private func balancedRuns(wallMs: Int64) -> [(startMs: Int64, durationMs: Int64)] {
        let count = Int(wallMs * 110 / 3_600_000)
        let each = (wallMs * 87 / 1_000) / Int64(max(count, 1))
        let stride = wallMs / Int64(max(count, 1))
        return (0..<count).map { index in
            // Rounded to whole frames, like the firmware's own counters.
            let start = (Int64(index) * stride + stride / 2) / 20 * 20
            return (start, max(each / 20 * 20, 20))
        }
    }

    @Test("a word's media time is its wall time minus every suppressed run before it")
    func mediaIsWallMinusSuppressedPrefix() {
        let meta = suppressedMeta(
            wallMs: 900_000,
            runs: [(100_000, 40_000), (300_000, 20_000), (600_000, 18_000)])
        let clock = SegmentMediaClock(meta)

        #expect(clock.wallSpanMs == 900_000)
        #expect(clock.mediaSpanMs == 822_000)
        #expect(clock.isExact)

        // Before anything is withheld the two clocks agree.
        #expect(clock.media(fromWall: 50_000) == 50_000)
        // Inside a suppressed run the media clock stands still.
        #expect(clock.media(fromWall: 120_000) == 100_000)
        // After it, it is behind by the whole run.
        #expect(clock.media(fromWall: 200_000) == 160_000)
        // After all three: 900 s of wall time is 822 s of audio.
        #expect(clock.media(fromWall: 900_000) == 822_000)

        // And back: a provider offset lands on the moment it was said, not 78 s early.
        #expect(clock.wall(fromMedia: 160_000) == 200_000)
        #expect(clock.wall(fromMedia: 822_000) == 900_000)
    }

    @Test("the conversion removes the drift the suppressed runs would otherwise cause")
    func driftIsEliminated() {
        // A 15-minute rotation segment at the firmware's balanced-mode rate.
        let wallMs: Int64 = 900_000
        let runs = balancedRuns(wallMs: wallMs)
        let meta = suppressedMeta(wallMs: wallMs, runs: runs)
        let clock = SegmentMediaClock(meta)
        #expect(clock.isExact)
        #expect(runs.count == 27)

        // Words at 30-second intervals of REAL time. The provider reports each one at its media
        // offset — wall minus everything withheld before it.
        var worstRaw: Int64 = 0
        var worstConverted: Int64 = 0
        for saidAtWallMs in stride(from: Int64(0), through: wallMs, by: 30_000) {
            // Only instants where audio actually exists: nothing is spoken inside a suppressed
            // run by construction, and a media instant has no way to name one (the media clock
            // does not advance there).
            let insideARun = runs.contains {
                saidAtWallMs > $0.startMs && saidAtWallMs < $0.startMs + $0.durationMs
            }
            if insideARun { continue }
            let withheldBefore = runs.reduce(Int64(0)) { total, run in
                total + max(min(saidAtWallMs, run.startMs + run.durationMs) - run.startMs, 0)
            }
            let providerMs = saidAtWallMs - withheldBefore
            // What every consumer that reads the media clock as wall time would believe.
            worstRaw = max(worstRaw, abs(providerMs - saidAtWallMs))
            // What it believes through the clock.
            worstConverted = max(
                worstConverted, abs(clock.wall(fromMedia: providerMs) - saidAtWallMs))
        }

        // Unfixed, the last word of a 15-minute segment is a minute and a quarter early — and
        // that is the AVERAGE case for balanced mode, not the tail. Measured over the real
        // library with suppression synthesised at these rates, the last word of a segment lands
        // a median of 20.8 s early in balanced mode, p90 2 m 20 s, worst 41.8 min.
        #expect(worstRaw >= 70_000, "\(worstRaw)")
        // Converted, it is exact to the frame quantisation and nothing else.
        #expect(worstConverted == 0, "\(worstConverted)")
    }

    @Test("wall→media→wall round-trips through hundreds of suppressed runs")
    func roundTripsThroughManyRuns() {
        // A pathological but reachable segment: aggressive mode at 200 episodes an hour for the
        // whole 15 minutes, every run its own record.
        let runs: [(Int64, Int64)] = (0..<50).map { (Int64($0) * 18_000 + 4_000, 2_400) }
        let clock = SegmentMediaClock(suppressedMeta(wallMs: 900_000, runs: runs))
        #expect(clock.isExact)
        for mediaMs in stride(from: Int64(0), to: clock.mediaSpanMs, by: 1_700) {
            #expect(clock.media(fromWall: clock.wall(fromMedia: mediaMs)) == mediaMs)
        }
    }

    @Test("a silence-suppressed record moves the clock exactly like a lost one")
    func quietAndLossCountTheSameForTiming() {
        // Presentation keeps them strictly apart — quiet is calm, loss is explicit — but for
        // "how much audio precedes this instant" the cause is irrelevant: neither is in the
        // frame log. Anything else would put the same word in two places depending on WHY the
        // audio is absent.
        let runs: [(startMs: Int64, durationMs: Int64)] = [(120_000, 60_000)]
        let quiet = SegmentMediaClock(suppressedMeta(wallMs: 600_000, runs: runs))
        let lost = SegmentMediaClock(
            suppressedMeta(wallMs: 600_000, runs: runs, reason: .transportReset))
        #expect(quiet.wall(fromMedia: 200_000) == lost.wall(fromMedia: 200_000))
        #expect(quiet.media(fromWall: 400_000) == lost.media(fromWall: 400_000))
    }

    @Test("records that do not add up are reported as inexact rather than guessed at")
    func inexactRecordsAreFlagged() {
        // 15 min of claimed wall time around 15 s of audio, with nothing recorded to explain
        // it — the shape 23 of the 765 segments in the 2026-09-08 library have. The clock still
        // answers (proportionally, because a scrubber tap has to land somewhere) but says so,
        // and `ConversationBoundaryDetector.spokenRuns` declines to split on the answer.
        var meta = suppressedMeta(wallMs: 900_000, runs: [])
        meta.frameCount = 750  // 15 s
        #expect(!SegmentMediaClock(meta).isExact)
        // …while a suppressed segment's records DO add up, which is the case that matters here.
        #expect(SegmentMediaClock(suppressedMeta(wallMs: 900_000, runs: balancedRuns(wallMs: 900_000))).isExact)
    }

    @Test("a stored-audio range that straddles a gap is two wall stretches with the gap left out")
    func mediaRangeSplitsAtGaps() {
        // 10 min wall; 2 min withheld at 3:00-5:00. Stored audio 0-8 min.
        let clock = SegmentMediaClock(
            suppressedMeta(wallMs: 600_000, runs: [(180_000, 120_000)]))
        // Media 2:00-4:00 is wall 2:00-3:00, then (after the gap) wall 5:00-6:00.
        #expect(
            clock.wallRanges(fromMedia: 120_000..<240_000) == [120_000..<180_000, 300_000..<360_000])
        // Entirely before the gap, and entirely after it.
        #expect(clock.wallRanges(fromMedia: 0..<60_000) == [0..<60_000])
        #expect(clock.wallRanges(fromMedia: 420_000..<480_000) == [540_000..<600_000])
        // A range that starts exactly at the gap's media instant begins on its far side, like
        // `wall(fromMedia:)` does.
        #expect(clock.wallRanges(fromMedia: 180_000..<200_000) == [300_000..<320_000])
        #expect(clock.wall(fromMedia: 180_000) == 300_000)
        // Clamped to the stored audio; empty for an empty range.
        #expect(clock.wallRanges(fromMedia: 470_000..<900_000) == [590_000..<600_000])
        #expect(clock.wallRanges(fromMedia: 100..<100).isEmpty)
    }

    @Test("without exact gap records a media range maps proportionally, as one stretch")
    func inexactMediaRangeIsProportional() {
        var meta = suppressedMeta(wallMs: 900_000, runs: [])
        meta.frameCount = 22_500  // 7.5 min of audio in a 15 min wall span, unexplained
        let clock = SegmentMediaClock(meta)
        #expect(!clock.isExact)
        #expect(clock.wallRanges(fromMedia: 60_000..<120_000) == [120_000..<240_000])
    }
}

/// The shared turn → wall-clock helper every consumer of a transcript's timings goes through.
@Suite("segment media clock — turn to wall clock")
struct SegmentWallRangeTests {
    private let startMs: Int64 = 1_700_000_000_000

    private func meta(wallMs: Int64, runs: [(Int64, Int64)], storedMs: Int64? = nil) -> SegmentMeta {
        let withheld = runs.reduce(Int64(0)) { $0 + $1.1 }
        return SegmentMeta(
            segmentId: "seg-wr", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(startMs), startMonotonicMs: 0, receivedAtMs: startMs + wallMs,
            firstSampleIndex: 0, lastSampleIndexExclusive: UInt64(wallMs) * 16,
            headReceivedAtMs: startMs + wallMs,
            frameCount: (storedMs ?? (wallMs - withheld)) / 20,
            gaps: runs.map {
                GapMeta(
                    firstMissingSequence: UInt32($0.0 / 20), missingFrameCount: UInt32($0.1 / 20),
                    firstMissingSampleIndex: UInt64($0.0) * 16, origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue))
            },
            closeReason: .rotated)
    }

    @Test("an exact clock converts the turn through the gap records, anchored on the segment start")
    func exactClockConverts() {
        let segment = meta(wallMs: 900_000, runs: [(100_000, 40_000), (300_000, 20_000)])
        let clock = SegmentMediaClock(segment)
        #expect(clock.isExact)
        #expect(clock.startWallMs == segment.startWallMs)

        // Media 160-170 s is 40 s behind the wall clock: the first run was withheld before it.
        let turn = clock.wallRange(ofMediaStartMs: 160_000, endMs: 170_000)
        #expect(turn == SegmentWallRange(startMs: startMs + 200_000, endMs: startMs + 210_000, isApproximate: false))
        #expect(clock.wallOffset(ofMedia: 160_000) == clock.wall(fromMedia: 160_000))
        // The one-off form builds the same clock.
        #expect(SegmentMediaClock.wallRange(ofMediaStartMs: 160_000, endMs: 170_000, in: segment) == turn)
        // A reversed turn is a point, never an end before its start.
        let reversed = clock.wallRange(ofMediaStartMs: 170_000, endMs: 160_000)
        #expect(reversed.startMs == reversed.endMs)
        #expect(reversed.startMs == startMs + 210_000)
    }

    @Test("an inexact clock leaves the offsets on the media clock and says the time is approximate")
    func inexactClockPassesThrough() {
        // 15 min of claimed wall time around 15 s of audio and nothing recorded to explain it.
        let segment = meta(wallMs: 900_000, runs: [], storedMs: 15_000)
        let clock = SegmentMediaClock(segment)
        #expect(!clock.isExact)

        let turn = clock.wallRange(ofMediaStartMs: 5_000, endMs: 8_000)
        #expect(turn == SegmentWallRange(startMs: startMs + 5_000, endMs: startMs + 8_000, isApproximate: true))
        // Not the proportional guess `wall(fromMedia:)` falls back to (5 s of 15 → 300 s of 900).
        #expect(clock.wall(fromMedia: 5_000) == 300_000)
        #expect(clock.wallOffset(ofMedia: 5_000) == 5_000)
    }

    @Test("clamping pins the start into the bounds and the end between the start and the upper bound")
    func clampingAtBothEnds() {
        let bounds: ClosedRange<Int64> = 1_000...2_000
        func range(_ a: Int64, _ b: Int64) -> SegmentWallRange {
            SegmentWallRange(startMs: a, endMs: b, isApproximate: false)
        }
        // Inside: untouched.
        #expect(range(1_200, 1_500).clamped(to: bounds) == range(1_200, 1_500))
        // Before the start: pinned to the lower bound.
        #expect(range(500, 800).clamped(to: bounds) == range(1_000, 1_000))
        #expect(range(500, 1_300).clamped(to: bounds) == range(1_000, 1_300))
        // Past the end: pinned to the upper bound.
        #expect(range(1_800, 2_600).clamped(to: bounds) == range(1_800, 2_000))
        #expect(range(2_500, 2_900).clamped(to: bounds) == range(2_000, 2_000))
        // Spanning the whole window.
        #expect(range(0, 9_000).clamped(to: bounds) == range(1_000, 2_000))
        // The flag survives.
        #expect(SegmentWallRange(startMs: 0, endMs: 1, isApproximate: true).clamped(to: bounds).isApproximate)

        // And on a real clock: a turn the provider placed past the end of the stored audio.
        let clock = SegmentMediaClock(meta(wallMs: 60_000, runs: []))
        let segmentBounds = clock.startWallMs...(clock.startWallMs + clock.wallSpanMs)
        let late = clock.wallRange(ofMediaStartMs: 58_000, endMs: 75_000).clamped(to: segmentBounds)
        #expect(late.startMs == startMs + 58_000)
        #expect(late.endMs == startMs + 60_000)
    }
}
