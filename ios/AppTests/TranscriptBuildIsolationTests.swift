import AppDB
import Foundation
import SearchKit
import SegmentStore
import Testing

// Where the conversation screen's work happens, which is a performance contract and therefore a
// correctness one: the screen rebuilds its ENTIRE display every time the database ticks under it
// — a transcript landing, an annotation, a tag, a follow-up — and this loop is the expensive
// half of that rebuild.
//
// Measured against the largest real transcript in the 2026-09-09 device backup (24,854 words,
// 1,894 provider segments), `TranscriptItems.member` is 136 ms for ONE member on a Mac. A phone
// is slower and a long conversation has several members. While that ran on the main actor, a
// pipeline pass writing an annotation froze the screen someone was reading — reported as "the
// app gets unresponsive in a longer conversation page".
//
// This suite is NOT `@MainActor`. That is the whole test: if `TranscriptItems` is ever given
// back its `@MainActor`, this file stops compiling.

@Suite("transcript building stays off the main actor")
struct TranscriptBuildIsolationTests {

    private func meta(_ segmentId: String) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: 1_788_000_000_000, startMonotonicMs: 0, receivedAtMs: 1_788_000_000_000,
            closeReason: .rotated, transcriptionState: .complete)
    }

    @Test func aMemberCanBeBuiltWithoutTheMainActor() {
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta("seg-1"),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "We agreed on the plan.", startMs: 0, endMs: 2_000, speaker: "A")
            ],
            words: [
                SearchKit.TranscriptWord(text: "We", startMs: 0, endMs: 300),
                SearchKit.TranscriptWord(text: "agreed", startMs: 300, endMs: 900),
            ],
            assignments: [],
            timebase: .media
        )
        #expect(built.items.contains { if case .turn = $0 { return true } else { return false } })
    }

    /// The walk the conversation screen actually performs, likewise off the main actor.
    @Test func theWholeMemberWalkIsOffTheMainActor() async {
        let walked = await LiveWorld.walkMembers(
            [ConversationMember(segmentId: "seg-1")],
            metas: ["seg-1": meta("seg-1")],
            transcripts: [:],
            assignments: []
        )
        #expect(walked.mediaMs >= 0)
    }
}
