import Foundation
import SegmentStore
import Testing

@testable import AppDB

// A recording nobody has transcribed yet says nothing about where the talk was. It must still
// never become a day-long unit: that is how the 24-hour "conversations" were made.

@Suite struct UnheardRecordingTests {
    private let t0: Int64 = 1_790_000_000_000
    private let rate: UInt64 = 16_000

    /// Fifteen minutes of audio with `gapMinutes` of missing audio after the first five.
    private func recording(gapMinutes: UInt64, accounted: Bool) -> SegmentMeta {
        let audioSamples = 15 * 60 * rate
        let gapSamples = gapMinutes * 60 * rate
        var meta = makeSegment(
            id: "s0", stream: 1, startTimeMs: t0, durationSamples: audioSamples + gapSamples,
            gaps: accounted
                ? [
                    GapMeta(
                        firstMissingSequence: UInt32(5 * 60 * 50),
                        missingFrameCount: UInt32(gapMinutes * 60 * 50),
                        firstMissingSampleIndex: 5 * 60 * rate, origin: GapMeta.originWatch,
                        reasonRaw: 6)
                ] : [])
        meta.frameCount = Int64(audioSamples / 320)
        meta.closedAtMs = t0 + Int64((audioSamples + gapSamples) * 1000 / rate)
        return meta
    }

    private func group(_ meta: SegmentMeta) -> [GroupedConversation] {
        ConversationGrouper.group(
            segments: [meta], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: [
                meta.segmentId: SegmentSpeechEvidence(
                    segmentId: meta.segmentId, isSettled: false, speech: [])
            ])
    }

    @Test func anUnheardRecordingIsCutAtALongHoleInItsAudio() {
        // Eight hours missing in the middle, every minute of it in the gap records.
        let units = group(recording(gapMinutes: 480, accounted: true))
        #expect(units.count == 2)
        #expect(units.map(\.startReason) == [nil, .interrupted])
        // Five minutes before the hole, ten after it — not eight hours and a quarter.
        #expect(units.map { ($0.endMs - $0.startMs) / 60_000 } == [5, 10])
        #expect(units[1].startMs == t0 + (5 + 480) * 60_000)
        #expect(units[0].members == [ConversationMember(segmentId: "s0", endMediaMs: 300_000)])
        #expect(units[1].members == [ConversationMember(segmentId: "s0", startMediaMs: 300_000)])
    }

    @Test func aShortHoleDoesNotCutAnUnheardRecording() {
        // Twenty minutes missing: under the half hour a hole has to be to end anything.
        let units = group(recording(gapMinutes: 20, accounted: true))
        #expect(units.count == 1)
        #expect((units[0].endMs - units[0].startMs) / 60_000 == 35)
    }

    @Test func anUnheardRecordingWhoseRecordsDoNotAddUpIsAsLongAsItsAudio() {
        // The counter ran on for eight hours and nothing recorded why: a phantom span.
        let units = group(recording(gapMinutes: 480, accounted: false))
        #expect(units.count == 1)
        #expect((units[0].endMs - units[0].startMs) / 60_000 == 15)
    }
}
