import Foundation
import GRDB
import SegmentStore
import Testing

@testable import AppDB

// The content gate's digest (plan 7.10): what moves it and what does not. The regroup stage
// rewrites every conversation row each pass; for a window whose facts did not change that must
// leave the digest exactly as it was.

private let window: Range<Int64> = 1_000_000..<2_000_000

private func seed(_ database: AppDatabase) async throws {
    try await database.writer.write { db in
        for (id, start, end) in [("c1", 1_100_000, 1_200_000), ("c2", 1_300_000, 1_400_000), ("out", 3_000_000, 3_100_000)] {
            try db.execute(
                sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, 'UTC', 'closed')",
                arguments: [id, start, end])
            try db.execute(
                sql: """
                    INSERT INTO conversation_segments (conversationId, segmentId, ordinal, transcriptionState)
                    VALUES (?, ?, 0, 'Complete')
                    """,
                arguments: [id, "seg-\(id)"])
        }
        try db.execute(sql: "INSERT INTO annotations (conversationId, title) VALUES ('c1', 'Coffee')")
    }
}

/// The regroup's shape (`ConversationGrouper.apply`): every conversation and member row deleted
/// and written back, identically.
private func rewriteIdentically(_ database: AppDatabase) async throws {
    try await database.writer.write { db in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM conversations")
        let members = try Row.fetchAll(db, sql: "SELECT * FROM conversation_segments")
        try db.execute(sql: "DELETE FROM conversation_segments")
        try db.execute(sql: "DELETE FROM conversations")
        for row in rows {
            try db.execute(
                sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, ?, ?)",
                arguments: [row["id"], row["startMs"], row["endMs"], row["timezone"], row["state"]])
        }
        for row in members {
            try db.execute(
                sql: """
                    INSERT INTO conversation_segments (conversationId, segmentId, ordinal, transcriptionState)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [row["conversationId"], row["segmentId"], row["ordinal"], row["transcriptionState"]])
        }
    }
}

private let scope = HistoryDigestScope(
    window: window, segmentIds: ["seg-c1", "seg-c2"], recapDateKeys: ["2026-09-22"], includeTags: false)

@Suite struct HistoryDigestTests {
    @Test("an identical rewrite of every conversation leaves the digest unchanged")
    func identicalRewrite() async throws {
        let database = try AppDatabase.inMemory()
        try await seed(database)
        let before = try await HistoryDigest.read(database, scope: scope)
        try await rewriteIdentically(database)
        #expect(try await HistoryDigest.read(database, scope: scope) == before)
        #expect(before.conversationIds == ["c1", "c2"])
    }

    @Test("each fact the page is built from moves it")
    func factsMoveIt() async throws {
        let database = try AppDatabase.inMemory()
        try await seed(database)
        var last = try await HistoryDigest.read(database, scope: scope)
        let writes: [(String, String)] = [
            ("title", "UPDATE annotations SET title = 'Coffee and designs' WHERE conversationId = 'c1'"),
            ("end", "UPDATE conversations SET endMs = 1250000 WHERE id = 'c1'"),
            ("member state", "UPDATE conversation_segments SET transcriptionState = 'Failed' WHERE segmentId = 'seg-c2'"),
            ("task", "INSERT INTO transcription_tasks (segmentId, state, createdAtMs, updatedAtMs) VALUES ('seg-c1', 'Running', 0, 0)"),
            ("pause", "INSERT INTO pause_intervals (startMs, endMs, source) VALUES (1500000, 1600000, 'statusCard')"),
            ("follow-up", """
                INSERT INTO follow_ups (id, text, done, sourceSegmentId, createdAtMs, origin)
                VALUES ('f1', 'Call Simon', 0, 'seg-c1', 5, 'ai')
                """),
            ("follow-up done", "UPDATE follow_ups SET done = 1 WHERE id = 'f1'"),
            ("recap", "INSERT INTO recaps (dateKey, text, segmentIds, updatedAtMs) VALUES ('2026-09-22', 'Day', '[]', 7)"),
        ]
        for (name, sql) in writes {
            try await database.writer.write { try $0.execute(sql: sql) }
            let next = try await HistoryDigest.read(database, scope: scope)
            #expect(next != last, "\(name) did not move the digest")
            last = next
        }
        // Outside the window, or not drawn by a day: nothing.
        let quiet: [String] = [
            "UPDATE conversations SET endMs = 3200000 WHERE id = 'out'",
            "INSERT INTO recaps (dateKey, text, segmentIds, updatedAtMs) VALUES ('2026-09-23', 'Other day', '[]', 7)",
            "INSERT INTO tags (id, name) VALUES ('t1', 'work')",
            "INSERT INTO conversation_tags (conversationId, tagId, source) VALUES ('c1', 't1', 'ai')",
            "UPDATE follow_ups SET archivedAtMs = NULL WHERE id = 'nothing'",
        ]
        for sql in quiet {
            try await database.writer.write { try $0.execute(sql: sql) }
            #expect(try await HistoryDigest.read(database, scope: scope) == last, "\(sql) moved the digest")
        }
        // A week reads tags; the same tag write moves its digest.
        var tagged = scope
        tagged.includeTags = true
        let withTag = try await HistoryDigest.read(database, scope: tagged)
        try await database.writer.write { try $0.execute(sql: "UPDATE conversation_tags SET source = 'removed'") }
        #expect(try await HistoryDigest.read(database, scope: tagged) != withTag)
    }

    @Test("the observation drops duplicates at the source")
    func observationDropsDuplicates() async throws {
        let database = try AppDatabase.inMemory()
        try await seed(database)
        let fetches = Counter()
        let stream = HistoryDigest.observe(database, scope: scope, onFetch: { fetches.bump() })
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        try await rewriteIdentically(database)
        try await database.writer.write {
            try $0.execute(sql: "UPDATE annotations SET title = 'Changed' WHERE conversationId = 'c1'")
        }
        let second = await iterator.next()
        #expect(second != nil && second != first)
        // The identical rewrite was fetched (the observation cannot know in advance) but not
        // delivered.
        #expect(fetches.value >= 3)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct HistoryLibraryInputTests {
    @Test("only real content descriptors reach the day; fewWords is plain no conversation")
    func descriptors() {
        let fewWords = AudioContentSpan(
            startMs: 0, endMs: 10, kind: .noConversation, descriptor: AudioContentDescriptor.fewWords,
            confidence: 0.96, decidedBy: AudioContentDecider.wordRate, version: 1)
        #expect(HistoryContentSpanInput(span: fewWords).descriptor == nil)
        #expect(HistoryContentSpanInput(span: fewWords).kind == .noConversation)
        var music = fewWords
        music.descriptor = "music"
        #expect(HistoryContentSpanInput(span: music).descriptor == "music")
        var unknown = fewWords
        unknown.descriptor = "loop"
        #expect(HistoryContentSpanInput(span: unknown).descriptor == nil)
    }

    @Test("state: a finished recording wins over its queue row; complete without a file waits")
    func states() {
        typealias S = HistoryTranscriptionStates
        #expect(S.resolve(segment: .complete, task: .pending, hasTranscriptFile: true) == .complete)
        #expect(S.resolve(segment: .complete, task: nil, hasTranscriptFile: false) == .pending)
        #expect(S.resolve(segment: .pending, task: .failed, hasTranscriptFile: false) == .failed)
        #expect(S.resolve(segment: .pending, task: nil, hasTranscriptFile: false) == .pending)
        #expect(S.resolve(segment: .noSpeech, task: .running, hasTranscriptFile: false) == .noSpeech)
        #expect(S.resolve(segment: .running, task: .complete, hasTranscriptFile: true) == .complete)
        #expect(!S.isWaiting(.failed) && S.isWaiting(.disabled) && S.isTranscribed(.noSpeech))
    }

    @Test("follow-ups are filed under the day of their moment; hidden recordings take theirs away")
    func placing() {
        let zone = "UTC"
        let timeline = ZoneTimeline(segments: [], currentZoneID: zone)
        let day = LogicalDay.bounds(ofDateKey: "2026-09-22", timeZoneID: zone)!
        let records = [
            HistoryFollowUpRecord(
                id: "said", text: "a", done: false, sourceSegmentId: "s1",
                sourceWall: SegmentWallRange(startMs: day.startMs + 10, endMs: day.startMs + 20, isApproximate: false),
                createdAtMs: 0),
            HistoryFollowUpRecord(id: "span", text: "b", done: true, sourceSegmentId: "s2", createdAtMs: 0),
            HistoryFollowUpRecord(id: "hidden", text: "c", done: false, sourceSegmentId: "s3", createdAtMs: 0),
            HistoryFollowUpRecord(id: "by-hand", text: "d", done: false, origin: .user, createdAtMs: day.endMs + 5),
        ]
        let spans: [String: Range<Int64>] = [
            "s2": (day.startMs - 100)..<(day.startMs + 100), "s3": (day.startMs + 50)..<(day.startMs + 60),
        ]
        let placed = HistoryPlacedRecord.place(
            records, segmentSpan: { spans[$0] }, hiddenSegmentIds: ["s3"], dayKey: { timeline.dayKey(forMs: $0) })
        #expect(placed.map(\.record.id) == ["said", "span", "by-hand"])
        #expect(placed.map(\.dayKey) == ["2026-09-22", "2026-09-21", "2026-09-23"])
        #expect(placed[1].placement.isApproximate)
        let input = HistoryFollowUpInput(record: placed[1].record, placement: placed[1].placement, nowMs: 0)
        #expect(input.placement == .span(startMs: day.startMs - 100, endMs: day.startMs + 100))
    }
}
