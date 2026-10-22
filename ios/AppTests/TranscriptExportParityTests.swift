import AppDB
import CompanionRuntime
import Foundation
import SearchKit
import SegmentStore
import Testing
import Transcription
import WireProtocol

// The archive sync sends the server the quiet and interrupted rows THIS screen shows, so the web
// viewer and every assistant read a conversation the way the phone does. Both read one rule
// (`SearchKit.pieceTimeline`); this pins that they still agree, row for row, on the shape that
// once made them disagree by a factor of a thousand: a fraction of a second lost every two
// seconds (synthetic numbers).

@Suite("the export sends the rows the transcript shows")
struct TranscriptExportParityTests {
    private static let startWallMs: Int64 = 1_792_000_000_000
    private static let spanMs: Int64 = 900_000

    private static func meta() -> SegmentMeta {
        let gaps = stride(from: Int64(1_500), to: 898_000, by: 2_000).enumerated().map { index, ms in
            GapMeta(
                firstMissingSequence: 1_000 + UInt32(ms / 20),
                missingFrameCount: [10, 25, 40, 15][index % 4],
                firstMissingSampleIndex: UInt64(ms) * 16, origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.spoolOverflow.rawValue))
        }
        let lostFrames = gaps.reduce(Int64(0)) { $0 + Int64($1.missingFrameCount) }
        return SegmentMeta(
            segmentId: "seg-choppy", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(startWallMs), startMonotonicMs: 0, receivedAtMs: startWallMs + spanMs,
            firstSequence: 1_000, lastSequence: 1_000 + UInt32(spanMs / 20) - 1,
            firstSampleIndex: 0, lastSampleIndexExclusive: UInt64(spanMs) * 16,
            frameCount: spanMs / 20 - lostFrames, gaps: gaps, closeReason: .rotated,
            closedAtMs: startWallMs + spanMs, transcriptionState: .complete)
    }

    /// Five-second turns every eight seconds, none starting in the three silences, on the
    /// media clock as a durable transcript is timed.
    private static func turns(_ meta: SegmentMeta) -> [Transcription.TranscriptSegment] {
        let clock = SegmentMediaClock(meta)
        let silences: [Range<Int64>] = [200_000..<250_000, 400_000..<590_000, 700_000..<735_000]
        return stride(from: Int64(4_000), to: spanMs - 5_000, by: 8_000).enumerated().compactMap {
            index, start in
            guard !silences.contains(where: { $0.contains(start) }) else { return nil }
            return Transcription.TranscriptSegment(
                text: "Turn \(index) of the talk.", startMs: clock.media(fromWall: start),
                endMs: clock.media(fromWall: start + 5_000), speaker: index.isMultiple(of: 2) ? "1" : "2")
        }
    }

    @Test func theExportedRowsAreTheTranscriptScreensMarkers() throws {
        let meta = Self.meta()
        let segments = Self.turns(meta)
        // The piece starts a little into the recording, as a conversation that began mid-way.
        let member = ConversationMember(segmentId: meta.segmentId, startMediaMs: 60_000)

        let screen = TranscriptItems.member(
            segmentId: meta.segmentId, meta: meta,
            segments: segments.map {
                SearchKit.TranscriptSegment(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
            },
            assignments: [], timebase: .media, piece: member)
        let markers: [(text: String, at: Date?, missing: Bool)] = screen.items.compactMap { item in
            switch item {
            case .turn, .moment: return nil
            case .quiet(let marker): return (marker.text, marker.startedAt, false)
            case .missing(let marker): return (marker.text, marker.startedAt, true)
            case .moment: return nil
            }
        }

        let piece = ArchiveExport.Piece(
            member: member, meta: meta,
            transcript: SegmentTranscript(
                segmentId: meta.segmentId, text: segments.map(\.text).joined(separator: " "),
                modeUsed: .remoteOnly, providerId: "soniox", createdAtMs: 0, segments: segments))
        let window = (Self.startWallMs + 60_000)..<(Self.startWallMs + Self.spanMs)
        let gaps = ArchiveExport.gaps([piece], window: window)
        let exported = ArchiveExport.transcript(
            conversationId: "conv-seg-choppy-m60000", pieces: [piece], gaps: gaps, speakerNames: [:],
            sourceHash: "h"
        ).items.compactMap { item -> ArchiveGap? in
            if case .gap(let gap) = item { return gap }
            return nil
        }

        // One interruption and three quiet rows, on both sides, in the same order.
        try #require(markers.count == 4)
        #expect(markers.filter(\.missing).count == 1)
        #expect(exported.count == markers.count)
        for (gap, marker) in zip(exported, markers) {
            let label = try #require(gap.label)
            #expect((gap.cause.map { "\(label) (\($0))" } ?? label) == marker.text)
            #expect((gap.kind == .lost) == marker.missing)
            let at = try #require(marker.at)
            #expect(gap.startMs == Int64((at.timeIntervalSince1970 * 1000).rounded()))
        }
        // Said as what it lost over how long — never the stretch as if all of it were missing.
        #expect(markers[0].text.hasPrefix("audio interrupted for 3 min over 13 min"))

        // The conversation's gaps hold the same rows (none too brief for a line here).
        #expect(gaps.filter(\.shown) == exported)
    }
}
