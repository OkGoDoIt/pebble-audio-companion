import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The DISPLAYED extent of a conversation — first word to last word, never a container edge
// (`ConversationGrouper.unitExtent`, the rule `ConversationBoundaryDetector.displayExtent` had,
// over pieces instead of whole members). The synthetic half of the phantom-duration fix;
// `RealSegmentSplitDistributionTests` is the half that proves it on the real library.
//
// The bug: 41.4% of the library's displayed time did not exist. The watch's sample counter
// free-runs while the BLE link is down, so `lastSampleIndexExclusive − firstSampleIndex` turns
// a dropped connection into hours of "conversation" — one segment displayed 16 h 29 m and holds
// 32 seconds of audio.
//
// PORTED 2026-09-30. Every case runs with `policy: .quietOnly` (the extent is independent of the
// segmenter, and its numbers are still being tuned). The flanking-flow guard's case is gone with
// the guard; the cases at the bottom are new and cover what pieces added: a conversation that is
// a RANGE of a segment is placed and measured by that range.

@Suite struct ConversationExtentTests {
    let t0 = testEpochMs

    private func group(
        _ segments: [SegmentMeta], evidence: [String: SegmentSpeechEvidence] = [:],
        open: String? = nil, policy: BoundaryPolicy = .quietOnly,
        cutInputs: ConversationCutInputs = .none
    ) -> [GroupedConversation] {
        let conversations = ConversationGrouper.group(
            segments: segments, pauses: [], openSegmentId: open, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: policy, cutInputs: cutInputs)
        expectPiecesTile(conversations, segments: segments)
        return conversations
    }

    @Test func withNoEvidenceTheExtentIsExactlyTheContainer() {
        // The v1 contract: a caller with no transcripts must see what it always saw.
        let segments = rotations(2)
        for policy in [BoundaryPolicy.quietOnly, .structuralOnly] {
            let convos = group(segments, policy: policy)
            #expect(convos.count == 1)
            #expect(convos[0].startMs == t0)
            #expect(convos[0].endMs == t0 + minutesMs(40))
        }
    }

    @Test func theExtentIsTheFirstWordToTheLastWord() {
        // 30 minutes of container holding 4 minutes of talk in the middle. The silence either
        // side is under `quietSplitMs`, so this stays ONE conversation and the only thing that
        // changes is how long it says it is.
        let segments = rotations(3, minutesEach: 10)
        let evidence = [
            "s0": settledEvidence("s0", minutes: []),
            "s1": settledEvidence("s1", minutes: [(4, 8)]),
            "s2": settledEvidence("s2", minutes: []),
        ]
        let convos = group(segments, evidence: evidence)
        #expect(convos.count == 1)
        #expect(convos[0].startMs == t0 + minutesMs(14))
        #expect(convos[0].endMs == t0 + minutesMs(18))
        // The evidence trims the extent under the structural rules too: it is a display
        // correction, not a grouping rule.
        let structural = group(segments, evidence: evidence, policy: .structuralOnly)
        #expect(structural[0].startMs == t0 + minutesMs(14))
        #expect(structural[0].endMs == t0 + minutesMs(18))
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
        let inflated = group(
            [meta], evidence: ["a": SegmentSpeechEvidence.of(meta, transcriptSpeech: nil)])
        #expect(inflated[0].endMs == t0 + minutesMs(120))
    }

    @Test func anUnsettledMemberKeepsItsWholePlacement() {
        // Deferral applies to the extent exactly as it applies to the boundary: a member that
        // has not been transcribed yet cannot be claimed to be empty, so it is not trimmed. A
        // live conversation therefore keeps growing to the open member's edge.
        var segments = rotations(2)
        segments[1].closeReason = nil
        let evidence = [
            "s0": settledEvidence("s0", minutes: [(5, 8)]),
            "s1": unsettledEvidence("s1"),
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
            "s0": settledEvidence("s0", minutes: []),
            "s1": unsettledEvidence("s1"),
            "s2": settledEvidence("s2", minutes: [(2, 6)]),
        ]
        let convos = group(segments, evidence: evidence)
        #expect(convos.count == 1)
        #expect(convos[0].startMs == t0 + minutesMs(20))
        #expect(convos[0].endMs == t0 + minutesMs(46))
    }

    // MARK: - pieces

    @Test func aPieceIsPlacedAndMeasuredByItsOwnRange() {
        // One 60-minute segment the person has split at minute 30, with talk either side. Each
        // half shows its own first word to its own last word — not the segment's.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(60))
        let evidence = ["a": settledEvidence("a", minutes: [(2, 10), (20, 25), (36, 50)])]
        let convos = group(
            [segment], evidence: evidence,
            cutInputs: ConversationCutInputs(splits: ["a": [minutesMs(30)]]))
        #expect(convos.map(\.brief) == [["a[..1800000)"], ["a[1800000..)"]])
        #expect(convos[0].startMs == t0 + minutesMs(2))
        #expect(convos[0].endMs == t0 + minutesMs(25))
        #expect(convos[1].startMs == t0 + minutesMs(36))
        #expect(convos[1].endMs == t0 + minutesMs(50))
    }

    @Test func anUnsettledPieceKeepsItsRangeNotItsWholeSegment() {
        // The same split on a segment with no transcript yet: nothing can be trimmed, so each
        // half is exactly its range of the container — and neither claims the other's.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(60))
        let convos = group(
            [segment], cutInputs: ConversationCutInputs(splits: ["a": [minutesMs(30)]]))
        #expect(convos.count == 2)
        #expect(convos[0].startMs == t0)
        #expect(convos[0].endMs == t0 + minutesMs(30))
        #expect(convos[1].startMs == t0 + minutesMs(30))
        #expect(convos[1].endMs == t0 + minutesMs(60))
    }

    @Test func aSilentPieceIsAsLongAsTheAudioInItsRange() {
        // Talk for four minutes, then nothing until the recording ends 56 minutes later. The
        // silent tail is its own conversation, and with nothing said in it its honest length is
        // the audio its range holds — here all of it, since nothing was lost.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(60))
        let evidence = ["a": settledEvidence("a", minutes: [(0, 4)])]
        let convos = group([segment], evidence: evidence)
        let at = minutesMs(4) + ConversationRunPlanner.postRollMs
        #expect(convos.map(\.brief) == [["a[..\(at))"], ["a[\(at)..)"]])
        #expect(convos[0].startMs == t0)
        #expect(convos[0].endMs == t0 + minutesMs(4))
        #expect(convos[1].startMs == t0 + at)
        #expect(convos[1].endMs == t0 + minutesMs(60))
    }

    @Test func aTurnBelongsToTheConversationItStartsIn() {
        // A turn that straddles a cut is counted once, where it starts, so the conversation
        // after the cut does not open on the tail of a sentence from the one before.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(60))
        let evidence = ["a": settledEvidence("a", minutes: [(0, 10), (20, 32), (40, 50)])]
        let convos = group(
            [segment], evidence: evidence,
            cutInputs: ConversationCutInputs(splits: ["a": [minutesMs(30)]]))
        #expect(convos.count == 2)
        #expect(convos[0].startMs == t0)
        // The extent never leaves the piece it belongs to.
        #expect(convos[0].endMs == t0 + minutesMs(30))
        #expect(convos[1].startMs == t0 + minutesMs(40))
        #expect(convos[1].endMs == t0 + minutesMs(50))
    }

    @Test func everyExtentSitsInsideItsOwnPiecesAndNoTwoOverlap() {
        // Conversations in one run share segments, so their extents must not claim the same
        // wall time twice: each ends at or before the next begins.
        let segments = rotations(4, minutesEach: 30)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(1, 9)]),
            settledEvidence("s1", minutes: [(0, 4), (24, 30)]),
            settledEvidence("s2", minutes: []),
            settledEvidence("s3", minutes: [(20, 22)]),
        ])
        let convos = group(segments, evidence: evidence)
        #expect(convos.map(\.memberSegmentIds) == [["s0"], ["s1"], ["s1", "s2", "s3"], ["s3"]])
        #expect(
            convos.map { [($0.startMs - t0) / 60_000, ($0.endMs - t0) / 60_000] }
                == [[1, 9], [30, 34], [54, 60], [110, 112]])
        for convo in convos {
            #expect(convo.endMs >= convo.startMs)
            #expect(convo.startMs >= t0)
            #expect(convo.endMs <= t0 + minutesMs(120))
        }
        for (before, after) in zip(convos, convos.dropFirst()) {
            #expect(before.endMs <= after.startMs, "\(before.id) runs into \(after.id)")
        }
    }
}
