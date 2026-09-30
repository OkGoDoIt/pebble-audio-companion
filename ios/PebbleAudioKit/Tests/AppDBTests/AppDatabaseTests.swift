import Foundation
import GRDB
import Testing
@testable import AppDB

@Suite struct AppDatabaseTests {
    @Test func migratesCleanlyAndTablesExist() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
        }
        let expected = [
            "tags", "conversation_tags", "follow_ups", "ask_history", "notes", "people",
            "speaker_assignments", "pause_intervals", "custom_templates", "conversations",
            "conversation_segments", "annotations", "recaps", "coverage_days",
            "transcription_tasks", "boundary_overrides", "boundary_reviews",
            "conversation_cuts", "conversation_cut_overrides",
        ]
        for table in expected {
            #expect(tables.contains(table), "missing table \(table)")
        }
    }

    @Test func ftsIndexAcceptsAndMatches() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO search_fts (entityId, kind, title, body, tags) VALUES (?,?,?,?,?)",
                arguments: ["c1", "conversation", "Coffee with Dana", "we talked about the trip to Lisbon", "travel"]
            )
        }
        let hits = try db.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT entityId FROM search_fts WHERE search_fts MATCH ?",
                arguments: ["lisbon"]
            )
        }
        #expect(hits == ["c1"])
    }

    @Test func foreignKeysCascade() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO tags (id, name) VALUES ('t1','travel')")
            try db.execute(
                sql: "INSERT INTO conversation_tags (conversationId, tagId, source) VALUES ('c1','t1','user')"
            )
            try db.execute(sql: "DELETE FROM tags WHERE id = 't1'")
        }
        let remaining = try db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_tags") ?? -1
        }
        #expect(remaining == 0)
    }
}

/// `v14-history-indexes`: the three indexes History's time-windowed reads need.
@Suite struct HistoryIndexMigrationTests {
    private static let indexes = ["conversations_start", "pause_intervals_start", "follow_ups_segment"]

    private static func indexes(_ db: AppDatabase) throws -> [String: String] {
        try db.reader.read { d in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                d, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
            {
                out[row["name"]] = row["sql"]
            }
            return out
        }
    }

    @Test func aFreshDatabaseHasTheIndexes() throws {
        let found = try Self.indexes(AppDatabase.inMemory())
        #expect(found["conversations_start"]?.contains("conversations(startMs)") == true)
        #expect(found["pause_intervals_start"]?.contains("pause_intervals(startMs)") == true)
        #expect(found["follow_ups_segment"]?.contains("follow_ups(sourceSegmentId)") == true)
    }

    @Test func aDatabaseAtV13UpgradesAndKeepsItsRows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion.sqlite")

        // A database exactly as v13 left it: every migration through v13, none of v14's
        // indexes, and rows in the three tables.
        do {
            let db = try AppDatabase.open(at: url)
            try db.writer.write { d in
                for name in Self.indexes { try d.execute(sql: "DROP INDEX \(name)") }
                try d.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-history-indexes'")
                try d.execute(
                    sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES ('c1', 10, 20, 'UTC', 'closed')")
                try d.execute(sql: "INSERT INTO pause_intervals (startMs, endMs, source) VALUES (5, 15, 'intent')")
                try d.execute(
                    sql: "INSERT INTO follow_ups (id, text, sourceSegmentId, createdAtMs) VALUES ('f1', 'x', 's1', 1)")
            }
            let identifiers = try db.reader.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
            #expect(identifiers.contains("v13-follow-up-model"))
            #expect(!identifiers.contains("v14-history-indexes"))
            #expect(Set(try Self.indexes(db).keys).isDisjoint(with: Self.indexes))
        }

        let upgraded = try AppDatabase.open(at: url)
        #expect(Set(try Self.indexes(upgraded).keys).isSuperset(of: Self.indexes))
        let counts = try upgraded.reader.read { d in
            try ["conversations", "pause_intervals", "follow_ups"].map {
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts == [1, 1, 1])
        let identifiers = try upgraded.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(identifiers.contains("v14-history-indexes"))
    }
}

/// `v15-follow-up-wall-times`: when a follow-up was said, on the wall clock, on both follow-up
/// tables, plus the two indexes that read it.
@Suite struct FollowUpWallTimeMigrationTests {
    private static let columns = ["sourceWallStartMs", "sourceWallEndMs", "sourceWallApproximate"]
    private static let tables = ["follow_ups", "follow_up_candidates"]
    private static let indexes = ["follow_ups_wall", "follow_ups_wall_unfilled"]

    private static func columns(_ db: AppDatabase, _ table: String) throws -> Set<String> {
        try db.reader.read { Set(try $0.columns(in: table).map(\.name)) }
    }

    private static func indexSQL(_ db: AppDatabase) throws -> [String: String] {
        try db.reader.read { d in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                d, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
            {
                out[row["name"]] = row["sql"]
            }
            return out
        }
    }

    @Test func aFreshDatabaseHasTheColumnsAndIndexes() throws {
        let db = try AppDatabase.inMemory()
        for table in Self.tables {
            #expect(try Self.columns(db, table).isSuperset(of: Self.columns), "\(table)")
        }
        let found = try Self.indexSQL(db)
        let wall = found["follow_ups_wall"] ?? ""
        #expect(wall.contains("follow_ups(sourceWallStartMs)"))
        #expect(wall.contains("WHERE sourceWallStartMs IS NOT NULL"))
        // Partial: only rows the one-time fill still has to visit.
        let unfilled = found["follow_ups_wall_unfilled"] ?? ""
        #expect(unfilled.contains("follow_ups(sourceSegmentId)"))
        #expect(unfilled.contains("WHERE sourceWallStartMs IS NULL"))
    }

    @Test func aDatabaseAtV14UpgradesAndKeepsItsRows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v15-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion.sqlite")

        // A database exactly as v14 left it: every migration through v14, none of v15's columns
        // or indexes, and a row in each table.
        do {
            let db = try AppDatabase.open(at: url)
            try db.writer.write { d in
                for name in Self.indexes { try d.execute(sql: "DROP INDEX \(name)") }
                for table in Self.tables {
                    for column in Self.columns {
                        try d.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column)")
                    }
                }
                try d.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = 'v15-follow-up-wall-times'")
                try d.execute(
                    sql: """
                        INSERT INTO follow_ups
                            (id, text, sourceSegmentId, createdAtMs, sourceStartMs, sourceEndMs)
                        VALUES ('f1', 'x', 's1', 1, 1000, 2000)
                        """)
                try d.execute(
                    sql: """
                        INSERT INTO follow_up_candidates (id, conversationId, task, createdAtMs)
                        VALUES ('c1', 'conv', 't', 1)
                        """)
            }
            for table in Self.tables {
                #expect(try Self.columns(db, table).isDisjoint(with: Self.columns))
            }
        }

        let upgraded = try AppDatabase.open(at: url)
        for table in Self.tables {
            #expect(try Self.columns(upgraded, table).isSuperset(of: Self.columns))
        }
        #expect(Set(try Self.indexSQL(upgraded).keys).isSuperset(of: Self.indexes))
        let rows = try upgraded.reader.read { d in
            try Self.tables.map { table in
                try Row.fetchAll(
                    d, sql: "SELECT sourceWallStartMs, sourceWallEndMs, sourceWallApproximate FROM \(table)"
                ).map { row in Self.columns.map { (row[$0] as Int64?) } }
            }
        }
        // Kept, and unknown until something computes them — never a made-up default.
        #expect(rows == [[[nil, nil, nil]], [[nil, nil, nil]]])
        let identifiers = try upgraded.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(identifiers.contains("v15-follow-up-wall-times"))
    }
}

/// `conversation-ranges-v1`: a conversation owns a RANGE of a segment's stored audio, so one
/// segment can belong to two conversations. `conversation_segments` is rebuilt in place — not
/// dropped — so the library does not read as empty between the upgrade and the first regroup.
@Suite struct ConversationRangesMigrationTests {
    private static let migration = "conversation-ranges-v1"

    private func temporaryDatabaseURL() throws -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ranges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("companion.sqlite"))
    }

    /// A database exactly as the migration before this one left it: every earlier migration
    /// applied, `conversation_segments` in its v1+v2 shape (UNIQUE on `segmentId`, no range
    /// columns), neither of the new tables, and a grouping already stored.
    private func stageDatabaseJustBeforeTheMigration(at url: URL) throws {
        let db = try AppDatabase.open(at: url)
        try db.writer.write { d in
            try d.execute(sql: "DROP TABLE conversation_cuts")
            try d.execute(sql: "DROP TABLE conversation_cut_overrides")
            try d.execute(sql: "DROP TABLE conversation_segments")
            // Verbatim v1 (`AppDatabase.swift`) plus the column `v2` adds.
            try d.execute(
                sql: """
                    CREATE TABLE conversation_segments (
                        conversationId TEXT NOT NULL
                            REFERENCES conversations(id) ON DELETE CASCADE,
                        segmentId TEXT NOT NULL UNIQUE,
                        ordinal INTEGER NOT NULL,
                        transcriptionState TEXT,
                        PRIMARY KEY (conversationId, ordinal)
                    )
                    """)
            try d.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [Self.migration])
            try d.execute(
                sql: """
                    INSERT INTO conversations (id, startMs, endMs, timezone, state, startReason)
                    VALUES ('conv-a', 1000, 2000, 'UTC', 'closed', NULL),
                           ('conv-c', 5000, 6000, 'Asia/Tokyo', 'live', 'quiet')
                    """)
            try d.execute(
                sql: """
                    INSERT INTO conversation_segments
                        (conversationId, segmentId, ordinal, transcriptionState)
                    VALUES ('conv-a', 'a', 0, 'Complete'), ('conv-a', 'b', 1, NULL),
                           ('conv-c', 'c', 0, 'Pending')
                    """)
            // Things keyed on those conversations, which the upgrade must not disturb.
            try d.execute(
                sql: """
                    INSERT INTO annotations (conversationId, title, summary)
                    VALUES ('conv-a', 'Coffee with Dana', 'Trip planning.')
                    """)
            try d.execute(
                sql: "INSERT INTO boundary_overrides (segmentId, decision, createdAtMs) VALUES ('c', 'join', 7)")
        }
        // The fixture really is the old shape: one segment, one conversation.
        #expect(throws: (any Error).self) {
            try db.writer.write { d in
                try d.execute(
                    sql: """
                        INSERT INTO conversation_segments (conversationId, segmentId, ordinal)
                        VALUES ('conv-c', 'b', 1)
                        """)
            }
        }
        let identifiers = try db.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(identifiers.contains("audio-content-judgements-v1"))
        #expect(!identifiers.contains(Self.migration))
        let tables = try db.reader.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(!tables.contains("conversation_cuts"))
        #expect(!tables.contains("conversation_cut_overrides"))
        try (db.writer as? DatabasePool)?.close()
    }

    @Test func theUpgradeKeepsEveryRowAsAWholeSegment() throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)

        let upgraded = try AppDatabase.open(at: url)
        let identifiers = try upgraded.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(identifiers.contains(Self.migration))

        // Every row is still there, in order, with its state — and no range: NULL/NULL is the
        // whole segment, which is what every existing row means.
        let rows = try upgraded.reader.read { d in
            try Row.fetchAll(
                d, sql: "SELECT * FROM conversation_segments ORDER BY conversationId, ordinal"
            ).map { row -> [String?] in
                let ordinal: Int = row["ordinal"]
                let start: Int64? = row["startMediaMs"]
                let end: Int64? = row["endMediaMs"]
                return [
                    row["conversationId"], row["segmentId"], String(ordinal),
                    row["transcriptionState"], start.map { String($0) }, end.map { String($0) },
                ]
            }
        }
        #expect(
            rows == [
                ["conv-a", "a", "0", "Complete", nil, nil],
                ["conv-a", "b", "1", nil, nil, nil],
                ["conv-c", "c", "0", "Pending", nil, nil],
            ])
        // The library reads exactly as it did: the grouper sees whole-segment conversations.
        let stored = try upgraded.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(stored.map(\.id) == ["conv-a", "conv-c"])
        #expect(stored.map(\.brief) == [["a", "b"], ["c"]])
        #expect(stored.map(\.isLive) == [false, true])
        #expect(stored.map(\.startReason) == [nil, .quiet])
        // And nothing beside it moved.
        let kept = try upgraded.reader.read { d in
            [
                try String.fetchOne(d, sql: "SELECT title FROM annotations WHERE conversationId = 'conv-a'"),
                try String.fetchOne(d, sql: "SELECT decision FROM boundary_overrides WHERE segmentId = 'c'"),
            ]
        }
        #expect(kept == ["Coffee with Dana", "join"])
    }

    @Test func afterTheUpgradeOneSegmentCanBelongToTwoConversations() throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)
        let upgraded = try AppDatabase.open(at: url)

        // The same `segmentId` in a second conversation, with a range.
        try upgraded.writer.write { d in
            try d.execute(
                sql: """
                    UPDATE conversation_segments SET endMediaMs = 400000
                    WHERE conversationId = 'conv-a' AND segmentId = 'b'
                    """)
            try d.execute(
                sql: """
                    INSERT INTO conversation_segments
                        (conversationId, segmentId, ordinal, transcriptionState, startMediaMs, endMediaMs)
                    VALUES ('conv-c', 'b', 1, NULL, 400000, NULL)
                    """)
        }
        let owners = try upgraded.reader.read {
            try String.fetchAll(
                $0,
                sql: """
                    SELECT conversationId FROM conversation_segments WHERE segmentId = 'b'
                    ORDER BY COALESCE(startMediaMs, 0)
                    """)
        }
        #expect(owners == ["conv-a", "conv-c"])

        // What made a row a row is still enforced: one piece per ordinal of a conversation …
        #expect(throws: (any Error).self) {
            try upgraded.writer.write { d in
                try d.execute(
                    sql: "INSERT INTO conversation_segments (conversationId, segmentId, ordinal) VALUES ('conv-a', 'z', 0)")
            }
        }
        // … a piece belongs to a conversation that exists …
        #expect(throws: (any Error).self) {
            try upgraded.writer.write { d in
                try d.execute(
                    sql: "INSERT INTO conversation_segments (conversationId, segmentId, ordinal) VALUES ('conv-nope', 'z', 0)")
            }
        }
        // … and goes when its conversation does.
        try upgraded.writer.write { try $0.execute(sql: "DELETE FROM conversations WHERE id = 'conv-a'") }
        let left = try upgraded.reader.read {
            try String.fetchAll(
                $0, sql: "SELECT conversationId || '/' || segmentId FROM conversation_segments ORDER BY 1")
        }
        #expect(left == ["conv-c/b", "conv-c/c"])
    }

    @Test func theUpgradeCreatesTheTwoCutTablesAndTheSegmentIndex() throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)
        let upgraded = try AppDatabase.open(at: url)

        let schema = try upgraded.reader.read { d in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                d, sql: "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL")
            {
                out[row["name"]] = row["sql"]
            }
            return out
        }
        #expect(schema["conversation_cuts"] != nil)
        #expect(schema["conversation_cut_overrides"] != nil)
        #expect(schema["conversation_segments_segment"]?.contains("conversation_segments(segmentId)") == true)
        // The scratch table the rebuild went through is gone, and `segmentId` is no longer unique.
        #expect(schema["conversation_segments_v2"] == nil)
        #expect(schema["conversation_segments"]?.uppercased().contains("UNIQUE") == false)

        // Both new tables are keyed by position: one row per (segment, offset).
        try upgraded.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO conversation_cuts (segmentId, mediaMs, reason, algorithm, createdAtMs)
                    VALUES ('a', 5, 'lull', 1, 1), ('a', 6, 'lull', 1, 1)
                    """)
            try d.execute(
                sql: """
                    INSERT INTO conversation_cut_overrides (segmentId, mediaMs, decision, createdAtMs)
                    VALUES ('a', 5, 'split', 1), ('a', 6, 'join', 1)
                    """)
        }
        for table in ["conversation_cuts", "conversation_cut_overrides"] {
            #expect(throws: (any Error).self, "\(table)") {
                try upgraded.writer.write { d in
                    if table == "conversation_cuts" {
                        try d.execute(
                            sql: "INSERT INTO conversation_cuts (segmentId, mediaMs, reason, algorithm, createdAtMs) VALUES ('a', 5, 'lull', 1, 2)")
                    } else {
                        try d.execute(
                            sql: "INSERT INTO conversation_cut_overrides (segmentId, mediaMs, decision, createdAtMs) VALUES ('a', 5, 'join', 2)")
                    }
                }
            }
        }
        let counts = try upgraded.reader.read { d in
            [
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM conversation_cuts") ?? -1,
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM conversation_cut_overrides") ?? -1,
            ]
        }
        #expect(counts == [2, 2])
    }

    @Test func theFirstRegroupAfterTheUpgradeKeepsTheIdsTheLibraryHad() async throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)
        let upgraded = try AppDatabase.open(at: url)

        // The migrated grouping says `conv-a` is segments `a` and `b`. The first regroup cuts
        // inside `b`, twice — after the last word before its long silence and at the first word
        // after it: the part that holds the old start keeps the old id, so the title that was
        // written for `conv-a` still has a conversation to belong to.
        let t0 = testEpochMs
        let a = makeSegment(id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(15))
        let b = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, firstSample: minutesSamples(15),
            durationSamples: minutesSamples(60))
        let evidence = evidenceMap([
            settledEvidence("a", minutes: [(0, 15)]),
            settledEvidence("b", minutes: [(0, 5), (40, 60)]),
        ])
        let rebuilt = try await ConversationGrouper.rebuildDetailed(
            segments: [a, b], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly, db: upgraded)
        let after = minutesMs(5) + ConversationRunPlanner.postRollMs
        let at = minutesMs(40) - ConversationRunPlanner.preRollMs
        #expect(rebuilt.conversations.map(\.id) == ["conv-a", "conv-b-m\(after)", "conv-b-m\(at)"])
        #expect(
            rebuilt.conversations.map(\.brief)
                == [["a", "b[..\(after))"], ["b[\(after)..\(at))"], ["b[\(at)..)"]])
        // The caller is told what the library looked like before, to move records across.
        #expect(rebuilt.previous.map(\.id) == ["conv-a", "conv-c"])
        #expect(rebuilt.previous.map(\.brief) == [["a", "b"], ["c"]])
    }

    @Test func openingAnUpgradedDatabaseAgainChangesNothing() throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)
        do {
            let upgraded = try AppDatabase.open(at: url)
            try upgraded.writer.write { d in
                try d.execute(
                    sql: """
                        INSERT INTO conversation_cuts (segmentId, mediaMs, reason, algorithm, createdAtMs)
                        VALUES ('a', 5, 'lull', 1, 1)
                        """)
                try d.execute(
                    sql: "UPDATE conversation_segments SET startMediaMs = 7 WHERE segmentId = 'c'")
            }
            try (upgraded.writer as? DatabasePool)?.close()
        }
        let again = try AppDatabase.open(at: url)
        let (cuts, start, pieces) = try again.reader.read { d in
            (
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM conversation_cuts") ?? -1,
                try Int64.fetchOne(d, sql: "SELECT startMediaMs FROM conversation_segments WHERE segmentId = 'c'"),
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM conversation_segments") ?? -1
            )
        }
        #expect(cuts == 1)
        #expect(start == 7)
        #expect(pieces == 3)
    }

    @Test func aFreshDatabaseHasTheSameShapeAsAnUpgradedOne() throws {
        let (dir, url) = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try stageDatabaseJustBeforeTheMigration(at: url)
        let upgraded = try AppDatabase.open(at: url)
        let fresh = try AppDatabase.inMemory()
        func columns(_ db: AppDatabase, _ table: String) throws -> [String] {
            try db.reader.read { d in
                try Row.fetchAll(d, sql: "PRAGMA table_info(\(table))").map { row in
                    let name: String = row["name"]
                    let type: String = row["type"]
                    let notNull: Int = row["notnull"]
                    let pk: Int = row["pk"]
                    return "\(name) \(type) \(notNull) \(pk)"
                }
            }
        }
        for table in ["conversation_segments", "conversation_cuts", "conversation_cut_overrides"] {
            #expect(try columns(upgraded, table) == columns(fresh, table), "\(table)")
        }
        #expect(
            try columns(fresh, "conversation_segments") == [
                "conversationId TEXT 1 1", "segmentId TEXT 1 0", "ordinal INTEGER 1 2",
                "transcriptionState TEXT 0 0", "startMediaMs INTEGER 0 0", "endMediaMs INTEGER 0 0",
            ])
        #expect(
            try columns(fresh, "conversation_cuts") == [
                "segmentId TEXT 1 1", "mediaMs INTEGER 1 2", "reason TEXT 1 0",
                "algorithm INTEGER 1 0", "createdAtMs INTEGER 1 0",
            ])
        // A join carries the span it joined; all four columns are nullable (a split has none,
        // and a span with no end runs to the end of its run).
        #expect(
            try columns(fresh, "conversation_cut_overrides") == [
                "segmentId TEXT 1 1", "mediaMs INTEGER 1 2", "decision TEXT 1 0",
                "createdAtMs INTEGER 1 0", "spanFromSegmentId TEXT 0 0",
                "spanFromMediaMs INTEGER 0 0", "spanToSegmentId TEXT 0 0",
                "spanToMediaMs INTEGER 0 0",
            ])
    }
}

/// `v16-history-briefs`: a day's headline, line and the fingerprint they were written against on
/// `recaps`, and the week and month briefs in `period_briefs`.
@Suite struct HistoryBriefsMigrationTests {
    private static let recapColumns: Set<String> = ["headline", "lineSummary", "briefOfHash"]

    private static func columns(_ db: AppDatabase, _ table: String) throws -> Set<String> {
        try db.reader.read { Set(try $0.columns(in: table).map(\.name)) }
    }

    @Test func aFreshDatabaseHasTheColumnsAndTheTable() throws {
        let db = try AppDatabase.inMemory()
        #expect(try Self.columns(db, "recaps").isSuperset(of: Self.recapColumns))
        #expect(
            try Self.columns(db, "period_briefs") == [
                "periodKey", "kind", "text", "headline", "lineSummary", "sourceHash", "provider", "model",
                "updatedAtMs", "attempts", "nextAttemptAtMs", "lastError",
            ])
    }

    @Test func aDatabaseBeforeItUpgradesAndKeepsItsRecaps() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion.sqlite")

        // A database exactly as the previous release left it: no brief columns, no table, and a
        // recap with its condensed form.
        do {
            let db = try AppDatabase.open(at: url)
            try db.writer.write { d in
                try d.execute(sql: "DROP TABLE period_briefs")
                for column in Self.recapColumns {
                    try d.execute(sql: "ALTER TABLE recaps DROP COLUMN \(column)")
                }
                try d.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v16-history-briefs'")
                try d.execute(
                    sql: """
                        INSERT INTO recaps (dateKey, text, segmentIds, updatedAtMs, shortText, shortOfHash)
                        VALUES ('2026-09-27', 'A long day.', '["s1"]', 7, 'Short.', 'h')
                        """)
            }
            #expect(try Self.columns(db, "recaps").isDisjoint(with: Self.recapColumns))
        }

        let upgraded = try AppDatabase.open(at: url)
        #expect(try Self.columns(upgraded, "recaps").isSuperset(of: Self.recapColumns))
        let row = try upgraded.reader.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM recaps WHERE dateKey = '2026-09-27'")
        }
        // Kept whole, and owed its brief: nothing is made up for it.
        #expect(row?["text"] == "A long day.")
        #expect(row?["shortText"] == "Short.")
        #expect((row?["headline"] as String?) == nil && (row?["briefOfHash"] as String?) == nil)
        let briefs = try upgraded.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM period_briefs") }
        #expect(briefs == 0)
        let identifiers = try upgraded.reader.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(identifiers.contains("v16-history-briefs"))
    }
}
