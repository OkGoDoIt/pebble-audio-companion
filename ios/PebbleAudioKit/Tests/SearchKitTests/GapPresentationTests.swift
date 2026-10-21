import AppDB
import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import SearchKit

// The quiet and interrupted rows a conversation's transcript shows, as one rule
// (`pieceTimeline` over `transcriptTimelineItems`) that the Conversation screen and the archive
// sync's export both read. These cases pin what the rule DOES with the shape that made the web
// viewer unreadable on 2026-10-21 — a fraction of a second lost every two seconds — so neither
// reader can drift from the other.

/// A synthetic 15-minute recording in the shape of Roger's of 2026-10-20 (none of its numbers):
/// the watch's buffer overflowing for 0.2-0.8 s every 2 s, start to end, while two people talk,
/// with three stretches nobody speaks in.
enum ChoppyRecording {
    static let startWallMs: Int64 = 1_792_000_000_000
    static let spanMs: Int64 = 900_000
    /// Drop lengths in 20 ms frames, cycled: 0.2, 0.5, 0.8 and 0.3 s.
    static let dropFrames: [UInt32] = [10, 25, 40, 15]
    /// Stretches of wall time (ms into the recording) in which no turn starts.
    static let silences: [Range<Int64>] = [200_000..<250_000, 400_000..<590_000, 700_000..<735_000]

    static var gaps: [GapMeta] {
        stride(from: Int64(1_500), to: 898_000, by: 2_000).enumerated().map { index, ms in
            GapMeta(
                firstMissingSequence: 1_000 + UInt32(ms / 20),
                missingFrameCount: dropFrames[index % dropFrames.count],
                firstMissingSampleIndex: UInt64(ms) * 16,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.spoolOverflow.rawValue))
        }
    }

    /// Everything the drops took, in ms: 449 of them, 201.8 s.
    static var lostMs: Int64 { gaps.reduce(0) { $0 + Int64($1.missingFrameCount) * 20 } }

    static var meta: SegmentMeta {
        let frames = spanMs / 20
        return SegmentMeta(
            segmentId: "seg-choppy", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(startWallMs), startMonotonicMs: 0,
            receivedAtMs: startWallMs + spanMs, firstSequence: 1_000,
            lastSequence: 1_000 + UInt32(frames) - 1, firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(spanMs) * 16, frameCount: frames - lostMs / 20,
            gaps: gaps, closeReason: .rotated, closedAtMs: startWallMs + spanMs,
            transcriptionState: .complete)
    }

    /// Five-second turns every eight seconds, alternating speakers, none starting in a silence —
    /// on the WALL clock, as offsets into the recording.
    static var wallTurns: [(startMs: Int64, endMs: Int64, speaker: String)] {
        stride(from: Int64(4_000), to: spanMs - 5_000, by: 8_000).enumerated().compactMap {
            index, start in
            silences.contains { $0.contains(start) }
                ? nil : (start, start + 5_000, index.isMultiple(of: 2) ? "1" : "2")
        }
    }

    /// The same turns on the MEDIA clock, as a durable transcript is timed (stored audio only).
    static var mediaSegments: [TranscriptSegment] {
        let clock = SegmentMediaClock(meta)
        return wallTurns.enumerated().map { index, turn in
            TranscriptSegment(
                text: "Turn number \(index) of the talk.",
                startMs: clock.media(fromWall: turn.startMs),
                endMs: clock.media(fromWall: turn.endMs), speaker: turn.speaker)
        }
    }
}

@Suite("gap presentation")
struct GapPresentationTests {
    private func rows(_ meta: SegmentMeta, _ segments: [TranscriptSegment], member: ConversationMember? = nil)
        -> [TranscriptTimelineItem.Pause]
    {
        pieceTimeline(
            meta: meta, member: member ?? ConversationMember(segmentId: meta.segmentId),
            clock: SegmentMediaClock(meta), segments: segments, timebase: .media
        ).pauses
    }

    /// 449 drops of under a second, 2 s apart, around continuous speech: ONE interruption row
    /// at the top, saying how much was lost and over how long — never a row per drop, and never
    /// "audio interrupted for 14 min" over fourteen minutes of words that are all there.
    @Test func manyBriefWatchDropsAroundSpeechAreOneCalmRow() throws {
        let meta = ChoppyRecording.meta
        #expect(SegmentMediaClock(meta).isExact)
        let pauses = rows(meta, ChoppyRecording.mediaSegments)

        let lost = pauses.filter(\.missing)
        try #require(lost.count == 1)
        let row = lost[0]
        #expect(row.startMs == 1_500)
        #expect(row.endMs == 897_700)
        #expect(row.interruptedMs == ChoppyRecording.lostMs)
        #expect(row.missingMs == ChoppyRecording.lostMs)
        #expect(row.isSpread)
        #expect(row.isShownInTranscript)
        #expect(row.label == "audio interrupted for 3 min over 14 min (watch buffer filled while disconnected)")
        #expect(row.summaryText == "audio interrupted for 3 min over 14 min")
        #expect(row.cause == "watch buffer filled while disconnected")
        #expect(row.reasons.map(\.code) == ["spoolOverflow"])
        #expect(row.reasons[0].count == 449)
        #expect(!row.hasReasonBreakdown)

        // The three stretches nobody spoke in are calm quiet rows, measured from the last word
        // before to the first word after — the drops inside them do not make them loss.
        let quiet = pauses.filter { !$0.missing }
        #expect(quiet.map(\.label) == ["quiet for 51 sec", "quiet for 3 min", "quiet for 43 sec"])
        #expect(quiet.map(\.startMs) == [201_000, 401_000, 697_000])
        #expect(quiet.allSatisfy { $0.missingMs == 0 && $0.interruptedMs == 0 })
    }

    /// One real hole reads as it always did: its length, its cause, nothing about a stretch.
    @Test func oneContiguousHoleSaysOnlyItsLength() throws {
        var meta = ChoppyRecording.meta
        meta.gaps = [
            GapMeta(
                firstMissingSequence: 1_000 + 5_000, missingFrameCount: 2_000,  // 40 s
                firstMissingSampleIndex: 100_000 * 16, origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.transportReset.rawValue))
        ]
        meta.frameCount = 45_000 - 2_000
        let clock = SegmentMediaClock(meta)
        let segments = [
            TranscriptSegment(text: "Before.", startMs: clock.media(fromWall: 90_000), endMs: clock.media(fromWall: 95_000), speaker: "1"),
            TranscriptSegment(text: "After.", startMs: clock.media(fromWall: 141_000), endMs: clock.media(fromWall: 146_000), speaker: "2"),
        ]
        let row = try #require(rows(meta, segments).first { $0.missing })
        #expect(!row.isSpread)
        #expect(row.label == "audio interrupted for 40 sec (connection was interrupted)")
        #expect(row.missingMs == 40_000)
    }

    /// The watch's power-save pause is heard as an interruption but is not loss: the row says
    /// how long nothing was heard, and its missing share is zero.
    @Test func aPowerSavePauseIsAnInterruptionThatIsNotLoss() throws {
        var meta = ChoppyRecording.meta
        meta.gaps = [
            GapMeta(
                firstMissingSequence: 1_000 + 5_000, missingFrameCount: 3_000,  // 60 s
                firstMissingSampleIndex: 100_000 * 16, origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.powerSave.rawValue))
        ]
        meta.frameCount = 45_000 - 3_000
        let clock = SegmentMediaClock(meta)
        let segments = [
            TranscriptSegment(text: "Back again.", startMs: clock.media(fromWall: 170_000), endMs: clock.media(fromWall: 175_000), speaker: "1")
        ]
        let row = try #require(rows(meta, segments).first { $0.missing })
        #expect(row.label == "audio interrupted for 1 min (watch was saving power)")
        #expect(row.interruptedMs == 60_000)
        #expect(row.missingMs == 0)
        #expect(row.reasons.allSatisfy { !$0.isLoss })
    }

    /// A piece of the recording shows only its own rows: the drops before the cut belong to the
    /// conversation before it.
    @Test func aPieceShowsOnlyTheRowsThatStartInIt() throws {
        let meta = ChoppyRecording.meta
        let clock = SegmentMediaClock(meta)
        let cut = clock.media(fromWall: 600_000)
        let pauses = rows(
            meta, ChoppyRecording.mediaSegments,
            member: ConversationMember(segmentId: meta.segmentId, startMediaMs: cut))
        let lost = pauses.filter(\.missing)
        try #require(lost.count == 1)
        #expect(lost[0].startMs >= 600_000)
        #expect(lost[0].interruptedMs < ChoppyRecording.lostMs / 2)
        #expect(pauses.filter { !$0.missing }.map(\.label) == ["quiet for 43 sec"])
    }
}
