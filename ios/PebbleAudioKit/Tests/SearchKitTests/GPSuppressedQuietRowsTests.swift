import Foundation
import SegmentStore
import StatusUI
import Testing
import WireProtocol

@testable import SearchKit

// What a transcript looks like once the watch starts withholding silence.
//
// Watch-side silence suppression (PebbleOS a47acac74) fired zero times in 88 days and is about
// to fire 90-300 times a day. Two things had to survive that, and neither did by accident:
//
//  1. The transcript must not grow a wall of markers. A suppression run is short — the
//     firmware's own numbers are 60-200 episodes an hour withholding 4.1-13.8% of airtime, so
//     roughly 2.5 s each — and there can be dozens inside one silence.
//  2. A marker must describe the silence the reader lived through, not the arithmetic sum of
//     what the watch chose not to send. The watch withholds only the part of a quiet stretch
//     its detector is sure about, so the sum is a small fraction of the stretch.

@Suite("suppressed silence in the transcript")
struct GPSuppressedQuietRowsTests {

    private func meta(
        wallMs: Int64, runs: [(startMs: Int64, durationMs: Int64)]
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
            frameCount: (wallMs - withheld) / 20,
            gaps: runs.map {
                GapMeta(
                    firstMissingSequence: UInt32($0.startMs / 20),
                    missingFrameCount: UInt32($0.durationMs / 20),
                    firstMissingSampleIndex: UInt64($0.startMs) * 16,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                )
            },
            closeReason: .rotated
        )
    }

    /// Suppression scattered through `[fromMs, toMs)` at `perHour` episodes an hour, each
    /// `eachMs` long — the firmware's measured shape, not a single tidy span.
    private func scattered(
        fromMs: Int64, toMs: Int64, perHour: Int64, eachMs: Int64
    ) -> [(startMs: Int64, durationMs: Int64)] {
        let count = max((toMs - fromMs) * perHour / 3_600_000, 1)
        let stride = (toMs - fromMs) / count
        return (0..<count).map { index in
            ((fromMs + Int64(index) * stride) / 20 * 20, eachMs)
        }
    }

    private func turn(_ text: String, _ startMs: Int64, _ endMs: Int64) -> TranscriptSegment {
        TranscriptSegment(text: text, startMs: startMs, endMs: endMs, speaker: "1")
    }

    @Test("dozens of suppressed runs inside one silence become one calm row")
    func manyRunsCollapseToOneRow() throws {
        // A 15-minute rotation: two minutes of conversation, eight minutes in a quiet room,
        // then conversation again. Balanced mode withholds ~24 short runs of that eight
        // minutes — the rest of it is audio we hold and nobody spoke in.
        let runs = scattered(fromMs: 130_000, toMs: 590_000, perHour: 190, eachMs: 2_500)
        #expect(runs.count == 24)

        let items = transcriptTimelineItems(
            meta: meta(wallMs: 900_000, runs: runs),
            segments: [
                turn("morning", 5_000, 9_000),
                turn("did you sleep alright", 30_000, 34_000),
                turn("more or less", 90_000, 120_000),
                turn("right, back to it", 600_000, 604_000),
                turn("that meeting moved to four", 700_000, 730_000),
            ]
        )

        let pauses = items.compactMap(\.asPause)
        // One row per SILENCE, not one per record: the recording has three stretches over
        // half a minute with nothing said in them, and 24 records inside the middle one.
        #expect(pauses.count == 3, "\(pauses.map(\.label))")
        let quiet = try #require(pauses.first { $0.durationMs > 300_000 })
        #expect(quiet.missing == false)
        // It describes the eight minutes of silence, not the 60 s the watch withheld inside it.
        // Summing the records — what this did before — read "quiet for 1 min".
        #expect(quiet.durationMs == 480_000, "\(quiet.durationMs)")
        #expect(quiet.label == "quiet for 8 min")
        // Never framed as loss, and no interruption reasons attached to it.
        #expect(quiet.reasons.isEmpty)
        #expect(!items.contains { $0.asPause?.missing == true })
    }

    @Test("a whole segment of scattered suppression adds at most one row per silence")
    func rowCountStaysProportionalToSilences() {
        // The worst realistic case: aggressive mode, 200 episodes an hour for fifteen minutes,
        // i.e. 50 gap records, spread across three separate quiet stretches.
        var runs: [(startMs: Int64, durationMs: Int64)] = []
        runs += scattered(fromMs: 40_000, toMs: 240_000, perHour: 300, eachMs: 2_000)
        runs += scattered(fromMs: 300_000, toMs: 500_000, perHour: 300, eachMs: 2_000)
        runs += scattered(fromMs: 560_000, toMs: 860_000, perHour: 300, eachMs: 2_000)
        #expect(runs.count == 57)

        let items = transcriptTimelineItems(
            meta: meta(wallMs: 900_000, runs: runs),
            segments: [
                turn("one", 10_000, 20_000),
                turn("two", 260_000, 280_000),
                turn("three", 520_000, 540_000),
                turn("four", 870_000, 890_000),
            ]
        )
        let pauses = items.compactMap(\.asPause)
        #expect(pauses.count == 3, "\(pauses.map(\.label))")
        #expect(pauses.allSatisfy { !$0.missing })
        // 57 records a segment, ~8 segments a day: the transcript gains three rows, not 456.
        // Each says how long the reader was looking at nothing, gap to gap.
        #expect(pauses.map(\.label) == ["quiet for 4 min", "quiet for 4 min", "quiet for 5 min"])
    }

    @Test("loss inside the same stretch is still counted, and still called loss")
    func lossKeepsItsOwnAccounting() throws {
        // A dropout in the middle of a quiet stretch. The quiet row may not swallow it, and the
        // interruption row must report the audio actually missing — not the stretch around it.
        var runs = scattered(fromMs: 130_000, toMs: 300_000, perHour: 190, eachMs: 2_500)
        var segment = meta(wallMs: 900_000, runs: runs)
        runs.append((400_000, 30_000))
        segment.gaps.append(
            GapMeta(
                firstMissingSequence: 20_000,
                missingFrameCount: 1_500,
                firstMissingSampleIndex: 400_000 * 16,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.transportReset.rawValue)
            ))
        segment.frameCount -= 1_500

        let items = transcriptTimelineItems(
            meta: segment,
            segments: [turn("before", 100_000, 120_000), turn("after", 600_000, 620_000)]
        )
        let pauses = items.compactMap(\.asPause)
        let missing = pauses.filter(\.missing)
        #expect(missing.count == 1)
        let interruption = try #require(missing.first)
        // The sum of the records, not the silence around them.
        #expect(interruption.durationMs == 30_000)
        #expect(interruption.label == "audio interrupted for 30 sec (connection was interrupted)")
        // Quiet and missing are never merged into one row.
        #expect(pauses.contains { !$0.missing })
    }

    @Test("a suppressed run too short to matter still says nothing at all")
    func shortRunsStayInvisible() {
        // Two turns 20 s apart with one 3-second suppressed run between them: below every
        // threshold, so the transcript shows an unlabelled break and no marker.
        let items = transcriptTimelineItems(
            meta: meta(wallMs: 120_000, runs: [(30_000, 3_000)]),
            segments: [turn("one", 10_000, 25_000), turn("two", 45_000, 60_000)]
        )
        #expect(items.compactMap(\.asPause).isEmpty)
        #expect(items.contains { $0.asBreak != nil })
    }
}
