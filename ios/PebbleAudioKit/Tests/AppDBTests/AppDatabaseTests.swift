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
            "transcription_tasks",
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
