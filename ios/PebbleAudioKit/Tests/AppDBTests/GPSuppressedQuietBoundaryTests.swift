import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The conversation-boundary layer's whole job is to notice a long stretch of the record with
// nothing said in it. Watch-side silence suppression deletes exactly that stretch from the
// clock the transcript is timed against, so this is where it breaks first and worst.
//
// `ConversationBoundaries.swift` opens by recording that `GapReason.silenceSuppressed` had
// ZERO occurrences in the whole library and was therefore rejected as a signal. That is no
// longer true (PebbleOS a47acac74), and the consequence is not that a new signal appeared — it
// is that an existing one is now being erased. Measured over the 2026-09-08 library with
// suppression synthesised at the firmware's own rates, reading the transcript's media offsets
// as wall offsets loses 22% / 35% / 54% of the interior no-speech stretches over five minutes
// (light / balanced / aggressive) and 20% / 70% / 80% of those over twelve.

@Suite("boundary evidence through suppressed silence")
struct GPSuppressedQuietBoundaryTests {

    private func meta(
        id: String,
        startMs: Int64,
        wallMs: Int64,
        runs: [(startMs: Int64, durationMs: Int64)],
        reason: GapReason = .silenceSuppressed
    ) -> SegmentMeta {
        let withheld: Int64 = runs.reduce(Int64(0)) { $0 + $1.durationMs }
        let frames: Int64 = (wallMs - withheld) / 20
        let lastSample: UInt64 = UInt64(wallMs) * 16
        let gaps: [GapMeta] = runs.map { run in
            GapMeta(
                firstMissingSequence: UInt32(run.startMs / 20),
                missingFrameCount: UInt32(run.durationMs / 20),
                firstMissingSampleIndex: UInt64(run.startMs) * 16,
                origin: GapMeta.originWatch,
                reasonRaw: Int(reason.rawValue)
            )
        }
        return SegmentMeta(
            segmentId: id,
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: UInt64(startMs),
            startMonotonicMs: 0,
            receivedAtMs: startMs + wallMs,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: lastSample,
            frameCount: frames,
            gaps: gaps,
            closeReason: .rotated,
            closedAtMs: startMs + wallMs
        )
    }

    private func evidence(_ meta: SegmentMeta, _ speech: [SpeechSpan]) -> SegmentSpeechEvidence {
        SegmentSpeechEvidence.of(meta, transcriptSpeech: speech)
    }

    @Test("a twenty-minute silence is still twenty minutes after the watch withholds half of it")
    func quietStretchSurvivesSuppression() throws {
        // 40 minutes: talk for 3, silent for 20, talk for the rest. The watch withholds 10
        // minutes of the middle — the acoustically-certain part of it — so the transcriber
        // hears 30 minutes and times the closing turn at 20 min instead of 30.
        let segment = meta(
            id: "seg-quiet", startMs: 1_700_000_000_000, wallMs: 2_400_000,
            runs: [(400_000, 600_000)])
        let speech = [
            SpeechSpan(startMs: 0, endMs: 180_000, wordCount: 400),
            // 23 min of wall time later, but only 13 min of stored audio later.
            SpeechSpan(startMs: 780_000, endMs: 1_800_000, wordCount: 2_000),
        ]

        let stretches = ConversationBoundaryDetector.quietStretches(
            members: [segment], evidence: [segment.segmentId: evidence(segment, speech)])

        let interior = try #require(stretches.first { !$0.isLeading && !$0.isTrailing })
        // The real silence, 3 min to 23 min.
        #expect(interior.durationMs == 1_200_000, "\(interior.durationMs)")
        // Read on the media clock it would have been 10 minutes — under `quietSplitMs` at the
        // 15-minute setting, so the conversation would simply not have ended here.
        #expect(interior.durationMs > 900_000)
    }

    @Test("every speech run keeps its true position, so nothing is placed in the withheld time")
    func runsLandOutsideTheSuppressedSpans() {
        let segment = meta(
            id: "seg-runs", startMs: 1_700_000_000_000, wallMs: 900_000,
            runs: [(120_000, 60_000), (400_000, 120_000)])
        let speech = [
            SpeechSpan(startMs: 60_000, endMs: 110_000, wordCount: 100),
            SpeechSpan(startMs: 200_000, endMs: 300_000, wordCount: 300),
            SpeechSpan(startMs: 400_000, endMs: 500_000, wordCount: 300),
        ]
        let runs = ConversationBoundaryDetector.spokenRuns(
            segment, evidence(segment, speech))
        let start = ConversationGrouper.segmentStartMs(segment)
        let withheld: [(Int64, Int64)] = [
            (start + 120_000, start + 180_000), (start + 400_000, start + 520_000),
        ]
        for run in runs {
            for hole in withheld {
                // A run may abut a withheld span but can never sit inside one: no audio was
                // stored there, so nothing could have been transcribed from it.
                #expect(!(run.startMs > hole.0 && run.startMs < hole.1), "\(run)")
            }
        }
        // The last turn really is 10 min 20 s in, not 8 min in.
        #expect(runs.last?.endMs == start + 680_000)
    }

    @Test("a segment whose records do not add up is left where it is, not stretched")
    func inexactMetadataIsNotGuessedAt() {
        // 15 minutes of claimed wall time around 15 seconds of audio and nothing recorded to
        // explain it — 23 of the 765 segments in the 2026-09-08 library look like this, and
        // spreading their transcripts proportionally moved 7,285 turns by over a minute (worst:
        // 14 h 44 m), putting three more conversations over four hours and re-creating the
        // phantom durations `displayExtent` exists to remove. A split is a structural decision
        // a person then sees, so it is never made on a guess.
        var segment = meta(id: "seg-odd", startMs: 1_700_000_000_000, wallMs: 900_000, runs: [])
        segment.frameCount = 750
        #expect(!SegmentMediaClock(segment).isExact)

        let speech = [SpeechSpan(startMs: 1_000, endMs: 14_000, wordCount: 30)]
        let runs = ConversationBoundaryDetector.spokenRuns(segment, evidence(segment, speech))
        let start = ConversationGrouper.segmentStartMs(segment)
        #expect(runs.map(\.startMs) == [start + 1_000])
        #expect(runs.map(\.endMs) == [start + 14_000])
    }
}
