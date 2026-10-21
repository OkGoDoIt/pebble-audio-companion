import AppDB
import Foundation
import SearchKit
import SegmentStore
import Testing
import Transcription
import WireProtocol

@testable import CompanionRuntime

// The archive sync's export (`ArchiveExport`), pinned against one synthetic conversation in the shape of the
// phone's own files: `conv-seg-1791883701900-efc75fe3-42-m572910`, four and a half minutes that
// start partway through one recording and end partway through the next, with eleven stretches of
// spool-overflow loss inside them. The fixture is two sidecars in the phone's own format
// and the two transcripts with their word timings stripped (the export reads turns only).
//
// The expected times were computed from the raw sidecars independently of this code (sample
// indexes, unioned gap records, the stored-frame clock), and they agree with what the phone's own
// grouper stored for the conversation: its first word at 09:38:06.011 UTC and its last at
// 09:42:44.991.

@Suite("archive export")
struct ArchiveTranscriptExportTests {
    static let conversationId = "conv-seg-1791883701900-efc75fe3-42-m572910"
    static let first = "seg-1791883701900-efc75fe3-42"
    static let second = "seg-1791884606258-efc75fe3-43"
    static let startMs: Int64 = 1_791_884_286_011
    static let endMs: Int64 = 1_791_884_564_991

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ArchiveFixtures"))
        return try Data(contentsOf: url)
    }

    static func pieces(masked: [ArchiveExport.MaskedRange] = []) throws -> [ArchiveExport.Piece] {
        func meta(_ id: String) throws -> SegmentMeta {
            try JSONDecoder().decode(SegmentMeta.self, from: fixture("\(id).meta.json"))
        }
        func transcript(_ id: String) throws -> SegmentTranscript {
            try JSONDecoder().decode(SegmentTranscript.self, from: fixture("\(id).transcript.json"))
        }
        return [
            ArchiveExport.Piece(
                member: ConversationMember(segmentId: first, startMediaMs: 572_910),
                meta: try meta(first), transcript: try transcript(first), masked: masked),
            ArchiveExport.Piece(
                member: ConversationMember(segmentId: second, endMediaMs: 723_270),
                meta: try meta(second), transcript: try transcript(second)),
        ]
    }

    static var window: Range<Int64> { startMs..<endMs }

    @Test func theConversationIsPlacedOnTheWallClockWithItsLoss() throws {
        let pieces = try Self.pieces()
        // The two pieces meet where the first recording ends and the second begins.
        #expect(ArchiveExport.wallExtent(pieces[0]) == 1_791_884_284_511..<1_791_884_515_121)
        #expect(ArchiveExport.wallExtent(pieces[1]).lowerBound == 1_791_884_515_121)

        // Eleven stretches of the watch's spool overflowing inside the window, 12.36 s in all:
        // what History's card says is missing, and what a clip of the span is short of.
        let lost = ArchiveExport.lostSpans(pieces, window: Self.window)
        #expect(lost.count == 11)
        #expect(lost.allSatisfy { $0.kind == .lost && $0.origin == "watch" })
        #expect(ArchiveExport.missingMs(pieces, window: Self.window) == 12_360)
        #expect(lost.first.map { $0.startMs..<$0.endMs } == 1_791_884_289_721..<1_791_884_291_081)
        #expect(lost.allSatisfy { Self.window.contains($0.startMs) && $0.endMs <= Self.endMs })
        // What is left of the window is stored audio.
        #expect(ArchiveExport.recordedMs(pieces, window: Self.window) == (Self.endMs - Self.startMs) - 12_360)
    }

    /// The conversation's gaps are the rows the Conversation screen shows, from the screen's own
    /// rule — not one row per gap record. The fixture's eleven stretches of loss are three rows:
    /// one the transcript gives a line, two too brief for one that still count.
    @Test func theGapsAreTheRowsTheScreenShows() throws {
        let pieces = try Self.pieces()
        let gaps = ArchiveExport.gaps(pieces, window: Self.window)
        var screen: [ArchiveGap] = []
        for piece in pieces {
            let transcript = try #require(piece.transcript)
            let clock = SegmentMediaClock(piece.meta)
            let rows = pieceTimeline(
                meta: piece.meta, member: piece.member, clock: clock,
                segments: transcript.segments.map {
                    SearchKit.TranscriptSegment(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                },
                timebase: .media)
            screen += rows.pauses.map { ArchiveGap($0, segmentStartWallMs: clock.startWallMs) }
        }
        // The same rows, less the ones wholly after the last word (the second piece runs on to
        // where the next conversation is cut).
        #expect(gaps == screen.filter { $0.endMs > Self.startMs && $0.startMs < Self.endMs }.sorted { $0.startMs < $1.startMs })
        #expect(screen.count == gaps.count + 2)

        #expect(gaps.allSatisfy { $0.kind == .lost && $0.origin == "watch" })
        #expect(gaps.map(\.label) == ["audio interrupted for 9 sec", "audio interrupted for 1 sec", "audio briefly interrupted"])
        #expect(gaps.allSatisfy { $0.cause == "watch buffer filled while disconnected" })
        #expect(gaps.map(\.shown) == [true, false, false])
        #expect(gaps.compactMap(\.missingMs) == [9_840, 1_760, 760])
        // The rows' loss adds up to the conversation's missing total.
        #expect(gaps.compactMap(\.missingMs).reduce(0, +) == ArchiveExport.missingMs(pieces, window: Self.window))
        #expect(gaps.first.map { $0.startMs..<$0.endMs } == 1_791_884_289_721..<1_791_884_305_641)
        // No hole between the pieces is invented: they meet, and a hole no record explains is
        // not loss to the app.
        #expect(!gaps.contains { $0.origin == "unknown" })
    }

    /// A clip says what its audio leaves out, so the server's player can place it on the clock: the
    /// loss records as before, and the silence the watch skipped as `quiet` (with the loss cut out of
    /// it) — not the screen's rows, whose stretch includes audio the clip holds.
    @Test func aClipsHolesAreItsRecordsWithTheQuietNamed() throws {
        let start: Int64 = 1_792_000_000_000
        func record(_ ms: Int64, _ frames: UInt32, _ reason: GapReason) -> GapMeta {
            GapMeta(
                firstMissingSequence: UInt32(ms / 20), missingFrameCount: frames,
                firstMissingSampleIndex: UInt64(ms) * 16, origin: GapMeta.originWatch,
                reasonRaw: Int(reason.rawValue))
        }
        let gaps = [record(10_000, 50, .spoolOverflow), record(20_000, 1_500, .silenceSuppressed), record(40_000, 100, .spoolOverflow)]
        let meta = SegmentMeta(
            segmentId: "seg-holes", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(start), startMonotonicMs: 0, receivedAtMs: start + 60_000,
            firstSequence: 0, lastSequence: 2_999, firstSampleIndex: 0,
            lastSampleIndexExclusive: 60_000 * 16, frameCount: 1_450, gaps: gaps,
            closeReason: .rotated, transcriptionState: .complete)
        let pieces = [ArchiveExport.Piece(member: ConversationMember(segmentId: "seg-holes"), meta: meta)]
        let holes = ArchiveExport.holes(pieces, window: start..<(start + 60_000))
        #expect(holes.map { "\($0.kind.rawValue) \($0.startMs - start)-\($0.endMs - start)" } == [
            "lost 10000-11000", "quiet 20000-40000", "lost 40000-42000", "quiet 42000-50000",
        ])
        #expect(ArchiveExport.lostSpans(pieces, window: start..<(start + 60_000)).count == 2)
        let clip = ArchiveRequestHandler.Clip(
            file: URL(fileURLWithPath: "/dev/null"), startMs: start, endMs: start + 60_000, lost: Array(holes.prefix(2)))
        #expect(clip.gapsHeader == """
            [{"endedAt":"2026-10-14T17:46:51.000Z","startedAt":"2026-10-14T17:46:50.000Z"},{"endedAt":"2026-10-14T17:47:20.000Z","kind":"quiet","startedAt":"2026-10-14T17:47:00.000Z"}]
            """)
    }

    @Test func theTranscriptIsCutMaskedNamedAndInTimeOrder() throws {
        // A stretch of the first recording judged to be music: one turn is said inside it.
        let music = ArchiveExport.MaskedRange(range: 637_000..<664_000, descriptor: "music")
        let pieces = try Self.pieces(masked: [music])
        let gaps = ArchiveExport.gaps(pieces, window: Self.window)
        let export = ArchiveExport.transcript(
            conversationId: Self.conversationId, pieces: pieces, gaps: gaps,
            speakerNames: ["1": "Roger"], sourceHash: "h")

        let turns = export.items.compactMap { item -> (Int64, Int64, String?, String?, String)? in
            guard case .turn(let at, let end, let speaker, let name, let text, _) = item else { return nil }
            return (at, end, speaker, name, text)
        }
        // Twelve turns start in the first piece and two in the second; the one under the music
        // is withheld; nothing from before the cut at 572.91 s or after 723.27 s is here.
        #expect(turns.count == 13)
        #expect(!export.text.contains("Checking the plan"))
        let firstTurn = try #require(turns.first)
        #expect(firstTurn.0 == Self.startMs && firstTurn.1 == 1_791_884_289_431)
        #expect(firstTurn.2 == "1" && firstTurn.3 == "Roger")
        let lastTurn = try #require(turns.last)
        #expect(lastTurn.0 == 1_791_884_564_811 && lastTurn.1 == Self.endMs)
        #expect(lastTurn.2 == "2" && lastTurn.3 == nil && lastTurn.4 == "Yeah.")
        // The second recording's first word, after the join: its own clock, its own anchor.
        #expect(turns.contains { $0.0 == 1_791_884_563_491 && $0.4 == "I set a timer for 1 hour." })

        // The masked stretch, on the wall clock, named.
        let masked = export.items.filter { $0.kindName == "masked" }
        #expect(masked == [.masked(atMs: 1_791_884_360_201, endMs: 1_791_884_387_201, descriptor: "music")])
        // Every row the screen gives a line is an item of its own, and the items are in time
        // order.
        #expect(export.items.filter { $0.kindName != "turn" && $0.kindName != "masked" }.count
            == gaps.filter(\.shown).count)
        #expect(export.items.map(\.atMs) == export.items.map(\.atMs).sorted())

        // The plain form: one line per turn, the name where there is one, the label otherwise.
        let lines = export.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 13)
        #expect(lines.first == "Roger: Yeah, it's about twenty pages, but it's mostly charts and that stuff.")
        #expect(lines.last == "Speaker 2: Yeah.")
        #expect(export.charCount == export.text.count)
        #expect(export.provider == "soniox" && export.model == "stt-async-v5")
    }

    /// Labels are per recording: "1" in the second recording is not "1" in the first. A name
    /// given in the second names only its own "1"; one given before names were scoped (the bare
    /// label) still covers the label in both.
    @Test func aSpeakersNameReachesOnlyTheRecordingItWasGivenIn() throws {
        let pieces = try Self.pieces()
        let gaps = ArchiveExport.gaps(pieces, window: Self.window)
        let secondStarts: Int64 = 1_791_884_515_121
        func named(_ names: [String: String]) -> [(inSecond: Bool, speaker: String?, name: String?)] {
            ArchiveExport.transcript(
                conversationId: Self.conversationId, pieces: pieces, gaps: gaps,
                speakerNames: names, sourceHash: "h"
            ).items.compactMap { item in
                guard case .turn(let at, _, let speaker, let name, _, _) = item else { return nil }
                return (at >= secondStarts, speaker, name)
            }
        }
        let scoped = named([SpeakerKey(segmentId: Self.second, label: "1").stored: "Sam"])
        let ones = scoped.filter { $0.speaker == "1" }
        #expect(ones.contains { $0.inSecond } && ones.contains { !$0.inSecond })
        #expect(ones.allSatisfy { $0.name == ($0.inSecond ? "Sam" : nil) })

        for legacy in ["1", "Speaker 1"] {
            #expect(named([legacy: "Sam"]).filter { $0.speaker == "1" }.allSatisfy { $0.name == "Sam" })
        }
    }

    /// The conversation's `people` stay the contract's shape: a plain label, never the stored
    /// `seg-…#1` key, and one entry per person however many recordings they were named in.
    @Test func peopleAreOnePerPersonUnderAPlainLabel() {
        typealias Speaker = ArchiveConversationPayload.Speaker
        let first = SpeakerKey(segmentId: Self.first, label: "1").stored
        let secondOne = SpeakerKey(segmentId: Self.second, label: "1").stored
        let secondThree = SpeakerKey(segmentId: Self.second, label: "3").stored
        // As `conversationRecord` reads them: ordered by stored label, an unscoped row first.
        let stored = [
            Speaker(label: "Speaker 2", personId: "p-dana", name: "Dana"),
            Speaker(label: first, personId: "p-sam", name: "Sam"),
            Speaker(label: secondOne, personId: "p-alex", name: "Alex"),
            Speaker(label: secondThree, personId: "p-sam", name: "Sam"),
        ]
        #expect(
            ArchivePayloadBuilder.people(stored) == [
                Speaker(label: "Speaker 2", personId: "p-dana", name: "Dana"),
                Speaker(label: "1", personId: "p-sam", name: "Sam"),
                Speaker(label: "1", personId: "p-alex", name: "Alex"),
            ])
    }

    @Test func theJSONIsTheContractsShape() throws {
        let pieces = try Self.pieces()
        let export = ArchiveExport.transcript(
            conversationId: Self.conversationId, pieces: pieces,
            gaps: ArchiveExport.gaps(pieces, window: Self.window), speakerNames: [:], sourceHash: "abc")
        let data = try ArchivePayloadBuilder.encode(export)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == [
            "conversationId", "sourceHash", "provider", "model", "language", "charCount", "text", "items",
        ])
        #expect(json["language"] is NSNull)
        let items = try #require(json["items"] as? [[String: Any]])
        let turn = try #require(items.first { $0["kind"] as? String == "turn" })
        #expect(turn["at"] as? String == "2026-10-13T09:38:06.011Z")
        #expect(Set(turn.keys) == ["kind", "at", "endAt", "speaker", "name", "text", "confidence"])
        #expect(turn["name"] is NSNull)
        let lost = try #require(items.first { $0["kind"] as? String == "lost" })
        #expect(Set(lost.keys) == ["kind", "at", "endAt", "origin", "label", "missingMs", "cause"])
        #expect((lost["label"] as? String)?.hasPrefix("audio interrupted for ") == true)
        #expect(lost["cause"] as? String == "watch buffer filled while disconnected")
        // Same input, same bytes: the hash that skips an unchanged payload means what it says.
        #expect(try ArchivePayloadBuilder.encode(export) == data)
    }

    /// A clip request across the join: the end of the first recording and the start of the
    /// second, frame-aligned outward, and trimmed to the maximum asked for.
    @Test func aClipSpanResolvesToMediaRangesAcrossBothPieces() throws {
        let pieces = try Self.pieces()
        let ranges = ArchiveClipPlan.resolve(
            pieces: pieces, startMs: 1_791_884_500_000, endMs: 1_791_884_570_000)
        #expect(ranges == [
            ArchiveClipPlan.Range(
                segmentId: Self.first, mediaRange: 776_780..<791_920,
                wallRange: 1_791_884_499_981..<1_791_884_515_121),
            ArchiveClipPlan.Range(
                segmentId: Self.second, mediaRange: 0..<54_120,
                wallRange: 1_791_884_515_121..<1_791_884_570_001),
        ])

        // A cap shorter than the span keeps its start.
        let capped = ArchiveClipPlan.resolve(
            pieces: pieces, startMs: 1_791_884_500_000, endMs: 1_791_884_570_000, maxMs: 20_000)
        #expect(capped.map(\.segmentId) == [Self.first, Self.second])
        #expect(capped.reduce(0) { $0 + $1.mediaRange.count } <= 20_020)

        // A span the conversation does not hold, and one wholly inside a loss, hold no audio.
        #expect(ArchiveClipPlan.resolve(pieces: pieces, startMs: 1_791_000_000_000, endMs: 1_791_000_060_000).isEmpty)
        #expect(ArchiveClipPlan.resolve(pieces: pieces, startMs: 1_791_884_289_800, endMs: 1_791_884_291_000).isEmpty)

        // The frames of a range are the stored frames at its media offsets: 20 ms each.
        let records = (0..<100).map { FrameRecord(sequence: UInt32($0), sampleIndex: UInt64($0) * 320, payload: [UInt8($0)]) }
        let slice = ArchiveClipPlan.frames(
            ArchiveClipPlan.Range(segmentId: Self.first, mediaRange: 200..<400, wallRange: 0..<1),
            from: records, frameDurationMs: 20)
        #expect(slice == (10..<20).map { Data([UInt8($0)]) })
    }
}
