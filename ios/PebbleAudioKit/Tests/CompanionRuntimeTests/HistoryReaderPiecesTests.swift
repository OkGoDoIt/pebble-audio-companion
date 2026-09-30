import AppDB
import Foundation
import GRDB
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

// History over topic-sized conversations: a conversation is an ordered list of PIECES (a range
// of one recording's stored audio), so one recording holds the end of one conversation and the
// start of the next. Everything History used to read by "the conversation's recordings" is
// pinned here against one small library, written as the grouper writes it:
//
//     seg-a (10:00–10:30)  |-- c1 --------|-- silence ---|-- c2 ---------|
//     seg-b (10:30–11:00)  |-- c2 (cont.) ---------|-- c3 --------------|
//
// c1 and c2 carry the tag "food"; the silence between c1 and c2 is a unit of its own with
// nothing said in it (its piece stored as NoSpeech).

private let t0: Int64 = 1_790_071_200_000  // 2026-09-22 10:00 UTC
private let minute: Int64 = 60_000
private let day = "2026-09-22"

private func meta(_ id: String, index: Int) -> SegmentMeta {
    let first = UInt64(index) * UInt64(30 * minute) * 16
    return SegmentMeta(
        segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
        frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
        startTimeMs: UInt64(t0), startMonotonicMs: 0,
        receivedAtMs: t0 + Int64(index + 1) * 30 * minute,
        firstSampleIndex: first, lastSampleIndexExclusive: first + UInt64(30 * minute) * 16,
        frameCount: 30 * minute / 20, gaps: [], closeReason: .rotated,
        transcriptionState: .complete)
}

private let metas = [meta("seg-a", index: 0), meta("seg-b", index: 1)]

/// The library above, in a scratch database and transcript folder.
private struct PieceWorld {
    let database: AppDatabase
    let root: URL
    let reader: HistoryReader

    init(hidden: Set<String> = []) throws {
        database = try AppDatabase.inMemory()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-pieces-\(UUID().uuidString)", isDirectory: true)
        let transcripts = FileTranscriptStore(root: root, nowMs: { t0 })
        for id in ["seg-a", "seg-b"] {
            try transcripts.save(
                id,
                result: RoutedTranscription(
                    text: "words", modeUsed: .localOnly, providerId: "fake", modelUsed: nil,
                    segments: [TranscriptSegment(text: "words", startMs: 60_000, endMs: 61_000, speaker: "1")],
                    words: []))
        }
        try database.writer.write { db in
            // (id, start, end, title, summary, pieces: (segment, from, to, state))
            let conversations: [(String, Int64, Int64, String?, String?, [(String, Int64?, Int64?, String)])] = [
                ("c1", 1, 9, "Coffee", "Beans.", [("seg-a", nil, 10 * minute, "Complete")]),
                ("conv-silence", 10, 20, nil, nil, [("seg-a", 10 * minute, 20 * minute, "NoSpeech")]),
                ("c2", 21, 44, nil, "Lunch plans.",
                 [("seg-a", 20 * minute, nil, "Complete"), ("seg-b", nil, 15 * minute, "Complete")]),
                ("c3", 46, 59, "Plans", nil, [("seg-b", 15 * minute, nil, "Complete")]),
            ]
            for (id, start, end, title, summary, pieces) in conversations {
                try db.execute(
                    sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, 'UTC', 'closed')",
                    arguments: [id, t0 + start * minute, t0 + end * minute])
                for (ordinal, piece) in pieces.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO conversation_segments
                                (conversationId, segmentId, ordinal, transcriptionState, startMediaMs, endMediaMs)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [id, piece.0, ordinal, piece.3, piece.1, piece.2])
                }
                if title != nil || summary != nil {
                    try db.execute(
                        sql: "INSERT INTO annotations (conversationId, title, summary) VALUES (?, ?, ?)",
                        arguments: [id, title, summary])
                }
            }
            try db.execute(sql: "INSERT INTO tags (id, name) VALUES ('t-food', 'food')")
            for id in ["c1", "c2"] {
                try db.execute(
                    sql: "INSERT INTO conversation_tags (conversationId, tagId, source) VALUES (?, 't-food', 'ai')",
                    arguments: [id])
            }
        }
        reader = HistoryReader(
            sources: HistoryReader.Sources(
                database: database, recaps: DailyRecapStore(db: database),
                audioContent: AudioContentStore(db: database),
                speechRuns: HistorySpeechRunCache(transcripts: transcripts), transcripts: transcripts,
                segments: { metas }, hiddenConversationIds: { hidden }, currentZoneID: { "UTC" }))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("History over conversation pieces")
struct HistoryReaderPiecesTests {
    @Test("a piece's wall range is its media bounds through the recording's clock, inside its extent")
    func pieceWallRanges() {
        let a = metas[0]
        let extent = t0..<(t0 + 30 * minute)
        #expect(HistoryPieces.wallRange(of: ConversationMember(segmentId: "seg-a"), meta: a, extent: extent) == extent)
        #expect(
            HistoryPieces.wallRange(
                of: ConversationMember(segmentId: "seg-a", startMediaMs: 20 * minute), meta: a, extent: extent)
                == (t0 + 20 * minute)..<(t0 + 30 * minute))
        #expect(
            HistoryPieces.wallRange(
                of: ConversationMember(segmentId: "seg-a", startMediaMs: 10 * minute, endMediaMs: 20 * minute),
                meta: a, extent: extent)
                == (t0 + 10 * minute)..<(t0 + 20 * minute))
        // A stale bound past the recording clamps to it.
        #expect(
            HistoryPieces.wallRange(
                of: ConversationMember(segmentId: "seg-a", endMediaMs: 90 * minute), meta: a, extent: extent)
                == extent)
    }

    @Test("a hidden conversation hides its pieces, and a recording only when it holds all of it")
    func hiddenPieces() {
        let extents = ["seg-a": t0..<(t0 + 30 * minute), "seg-b": (t0 + 30 * minute)..<(t0 + 60 * minute)]
        let pieces = [
            "c2": [
                ConversationMember(segmentId: "seg-a", startMediaMs: 20 * minute),
                ConversationMember(segmentId: "seg-b", endMediaMs: 15 * minute),
            ],
            "c9": [ConversationMember(segmentId: "seg-z")],
        ]
        let held = HistoryPieces.hidden(
            ["c2", "c9"], pieces: pieces,
            owners: ["seg-a": ["c1", "conv-silence", "c2"], "seg-b": ["c2", "c3"], "seg-z": ["c9"]],
            metas: Dictionary(uniqueKeysWithValues: metas.map { ($0.segmentId, $0) }), extents: extents)
        #expect(held.wallRanges == [(t0 + 20 * minute)..<(t0 + 30 * minute), (t0 + 30 * minute)..<(t0 + 45 * minute)])
        #expect(held.wholeSegments == ["seg-z"])
    }

    @Test("a follow-up is hidden by where it was said, not by the recording it was said in")
    func hiddenFollowUps() {
        let spans = ["seg-a": t0..<(t0 + 30 * minute)]
        func record(_ id: String, atMin: Int64?) -> HistoryFollowUpRecord {
            HistoryFollowUpRecord(
                id: id, text: id, done: false, sourceSegmentId: "seg-a",
                sourceWall: atMin.map {
                    SegmentWallRange(startMs: t0 + $0 * minute, endMs: t0 + $0 * minute + 5_000, isApproximate: false)
                },
                createdAtMs: t0)
        }
        let hiddenRange = (t0 + 20 * minute)..<(t0 + 30 * minute)
        let placed = HistoryPlacedRecord.place(
            [record("before", atMin: 5), record("inside", atMin: 25), record("unlocated", atMin: nil)],
            segmentSpan: { spans[$0] }, hiddenWallRanges: [hiddenRange], dayKey: { _ in day })
        // The one said inside the hidden piece goes; one with no located moment stays, because
        // the recording is shared and most of it is not hidden.
        #expect(placed.map(\.record.id) == ["before", "unlocated"])
        let wholly = HistoryPlacedRecord.place(
            [record("before", atMin: 5), record("unlocated", atMin: nil)],
            segmentSpan: { spans[$0] }, hiddenSegmentIds: ["seg-a"], dayKey: { _ in day })
        #expect(wholly.isEmpty)
    }

    @Test("the day's cards are its conversations with speech; a silent unit is not a card")
    func dayCards() async throws {
        let world = try PieceWorld()
        defer { world.remove() }
        let library = await world.reader.library()
        let inputs = try await world.reader.dayInput(day, library, nowMs: t0 + 120 * minute, isToday: false, isLive: false)
        #expect(inputs.builder.chapters.map(\.id) == ["c1", "c2", "c3"])
        #expect(inputs.builder.chapters.map(\.title) == ["Coffee", nil, "Plans"])
        #expect(inputs.builder.deletedSpans.isEmpty)
    }

    @Test("a conversation in its undo window is drawn as deleted over its own pieces only")
    func hiddenConversationOnTheDay() async throws {
        let world = try PieceWorld(hidden: ["c2"])
        defer { world.remove() }
        let library = await world.reader.library()
        let inputs = try await world.reader.dayInput(day, library, nowMs: t0 + 120 * minute, isToday: false, isLive: false)
        #expect(inputs.builder.chapters.map(\.id) == ["c1", "c3"])
        #expect(
            inputs.builder.deletedSpans.map { $0.startMs..<$0.endMs }
                == [(t0 + 20 * minute)..<(t0 + 30 * minute), (t0 + 30 * minute)..<(t0 + 45 * minute)])
    }

    @Test("a day's talk is counted per piece, and a silent unit adds none")
    func dayFactsPerPiece() async throws {
        let world = try PieceWorld()
        defer { world.remove() }
        let library = await world.reader.library()
        let facts = try await world.reader.dayFacts(
            [day], library, nowMs: t0 + 120 * minute, todayKey: "2026-09-23", isLive: false)
        let conversations = try #require(facts[day]).conversations
        #expect(conversations.map(\.id).sorted() == ["c1", "c2", "c3"])
        let talk = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.transcribedMs) })
        // Each conversation's own share of the shared recordings — never the whole of them.
        #expect(talk == ["c1": 10 * minute, "c2": 25 * minute, "c3": 15 * minute])
        #expect(try #require(facts[day]).recordings == 2)
    }

    @Test("a tag's results are its conversations, one each, with their own start, title and summary")
    func tagResults() async throws {
        let world = try PieceWorld()
        defer { world.remove() }
        let library = await world.reader.library()
        let hits = try await world.reader.tagHits(tag: "Food", library)
        #expect(hits.map(\.conversationId) == ["c2", "c1"])
        #expect(hits.map(\.startMs) == [t0 + 21 * minute, t0 + minute])
        #expect(hits.map(\.endMs) == [t0 + 44 * minute, t0 + 9 * minute])
        #expect(hits.map(\.title) == [nil, "Coffee"])
        #expect(hits.map(\.summary) == ["Lunch plans.", "Beans."])
        #expect(hits.allSatisfy { $0.dateKey == day && $0.zoneID == "UTC" })

        let hiding = try PieceWorld(hidden: ["c2"])
        defer { hiding.remove() }
        let hidden = try await hiding.reader.tagHits(tag: "food", await hiding.reader.library())
        #expect(hidden.map(\.conversationId) == ["c1"])
    }
}
