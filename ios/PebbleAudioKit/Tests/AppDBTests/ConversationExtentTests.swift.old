import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The DISPLAYED extent of a conversation — first word to last word, never a container edge.
// The synthetic half of the phantom-duration fix; `RealSegmentSplitDistributionTests` is the
// half that proves it on the real library.
//
// The bug: 41.4% of the library's displayed time did not exist. The watch's sample counter
// free-runs while the BLE link is down, so `lastSampleIndexExclusive − firstSampleIndex` turns
// a dropped connection into hours of "conversation" — one segment displayed 16 h 29 m and holds
// 32 seconds of audio.

private func settledEvidence(
    _ id: String, _ speech: [(Int64, Int64)], words: Int = 10
) -> SegmentSpeechEvidence {
    SegmentSpeechEvidence(
        segmentId: id, isSettled: true,
        speech: speech.map {
            SpeechSpan(startMs: minutesMs($0.0), endMs: minutesMs($0.1), wordCount: words)
        })
}

@Suite struct ConversationExtentTests {
    let t0 = testEpochMs

    private func rotations(_ count: Int, minutesEach: UInt64 = 20) -> [SegmentMeta] {
        (0..<count).map { index in
            makeSegment(
                id: "s\(index)", stream: 7, startTimeMs: t0,
                firstSample: minutesSamples(UInt64(index) * minutesEach),
                durationSamples: minutesSamples(minutesEach))
        }
    }

    private func group(
        _ segments: [SegmentMeta], evidence: [String: SegmentSpeechEvidence] = [:],
        open: String? = nil
    ) -> [GroupedConversation] {
        ConversationGrouper.group(
            segments: segments, pauses: [], openSegmentId: open, fallbackTimeZoneID: "UTC",
            evidence: evidence)
    }

    @Test func withNoEvidenceTheExtentIsExactlyTheContainer() {
        // The v1 contract: a caller with no transcripts must see what it always saw.
        let segments = rotations(2)
        let convos = group(segments)
        #expect(convos.count == 1)
        #expect(convos[0].startMs == t0)
        #expect(convos[0].endMs == t0 + minutesMs(40))
    }

    @Test func theExtentIsTheFirstWordToTheLastWord() {
        // 30 minutes of container holding 4 minutes of talk in the middle. The silence either
        // side is under `quietSplitMs`, so this stays ONE conversation and the only thing that
        // changes is how long it says it is.
        let segments = rotations(3, minutesEach: 10)
        let evidence = [
            "s0": settledEvidence("s0", []),
            "s1": settledEvidence("s1", [(4, 8)]),
            "s2": settledEvidence("s2", []),
        ]
        let convos = group(segments, evidence: evidence)
        #expect(convos.count == 1)
        #expect(convos[0].startMs == t0 + minutesMs(14))
        #expect(convos[0].endMs == t0 + minutesMs(18))
    }

    @Test func aConversationNobodySpokeInIsAsLongAsTheAudioItHolds() {
        // The 16 h 29 m / 32 s case in miniature: the sample counter claims two hours, the
        // frame count says 90 seconds arrived, and 90 seconds is what the library shows.
        var meta = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(120))
        meta.transcriptionState = .noSpeech
        meta.frameCount = 4_500  // 4,500 × 20 ms = 90 s
        let evidence = ["a": SegmentSpeechEvidence.of(meta, transcriptSpeech: nil)]
        #expect(evidence["a"]?.isSettled == true)
        let convos = group([meta], evidence: evidence)
        #expect(convos[0].startMs == t0)
        #expect(convos[0].endMs == t0 + 90_000)
        // …and never longer than the container, whatever the frame count claims.
        meta.frameCount = 10_000_000
        let inflated = group([meta], evidence: ["a": SegmentSpeechEvidence.of(meta, transcriptSpeech: nil)])
        #expect(inflated[0].endMs == t0 + minutesMs(120))
    }

    @Test func anUnsettledMemberKeepsItsWholePlacement() {
        // Deferral applies to the extent exactly as it applies to the boundary: a member that
        // has not been transcribed yet cannot be claimed to be empty, so it is not trimmed. A
        // live conversation therefore keeps growing to the open member's edge.
        let segments = rotations(2)
        let evidence = [
            "s0": settledEvidence("s0", [(5, 8)]),
            "s1": SegmentSpeechEvidence(segmentId: "s1", isSettled: false, speech: []),
        ]
        let convos = group(segments, evidence: evidence, open: "s1")
        #expect(convos.count == 1)
        #expect(convos[0].isLive)
        #expect(convos[0].startMs == t0 + minutesMs(5))
        #expect(convos[0].endMs == t0 + minutesMs(40))
    }

    @Test func settledSilentMembersAtTheFrontAreSkippedButAnUnsettledOneStopsTheWalk() {
        // s0 settled and silent → skipped; s1 not settled → the walk stops there and keeps s1's
        // placement rather than pretending the conversation starts at s2's first word.
        let segments = rotations(3)
        let evidence = [
            "s0": settledEvidence("s0", []),
            "s1": SegmentSpeechEvidence(segmentId: "s1", isSettled: false, speech: []),
            "s2": settledEvidence("s2", [(2, 6)]),
        ]
        let convos = group(segments, evidence: evidence)
        #expect(convos.count == 1)
        #expect(convos[0].startMs == t0 + minutesMs(20))
        #expect(convos[0].endMs == t0 + minutesMs(46))
    }

    /// The flanking-flow guard, synthetically: the same 20-minute silence splits or does not
    /// depending only on whether the wearer was still talking at pace on both sides of it.
    @Test func aSilenceBracketedByFullConversationIsWithheldAndOfferedToTheReviewer() {
        let segments = rotations(4, minutesEach: 10)
        // Talking hard right up to the silence and again straight after it: 600 words in the
        // 10 minutes before and 600 in the 10 after is 60 wpm on both flanks.
        func run(words: Int) -> (conversations: [GroupedConversation], candidates: [BoundaryCandidate]) {
            ConversationGrouper.groupWithCandidates(
                segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: [
                    "s0": settledEvidence("s0", [(0, 10)], words: words),
                    "s1": settledEvidence("s1", []),
                    "s2": settledEvidence("s2", []),
                    "s3": settledEvidence("s3", [(0, 10)], words: words),
                ])
        }
        let inFullFlow = run(words: 600)
        #expect(inFullFlow.conversations.count == 1)
        // Withheld, not discarded: the join nearest the middle of the silence is handed to the
        // reviewer, which can read what was said either side and confirm it.
        #expect(inFullFlow.candidates.map(\.newStartSegmentId) == ["s2"])

        // The same silence, but the talk either side was sparse: this is an occasion ending.
        let sparse = run(words: 20)
        #expect(sparse.conversations.map(\.memberSegmentIds) == [["s0", "s1"], ["s2", "s3"]])
        #expect(sparse.conversations[1].startReason == .quiet)

        // A LEADING or TRAILING silence is never guarded — it trims, it does not cut.
        let trailing = ConversationGrouper.group(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: [
                "s0": settledEvidence("s0", [(0, 10)], words: 600),
                "s1": settledEvidence("s1", [(0, 10)], words: 600),
                "s2": settledEvidence("s2", []),
                "s3": settledEvidence("s3", []),
            ])
        #expect(trailing.map(\.memberSegmentIds) == [["s0", "s1"], ["s2", "s3"]])
    }
}
