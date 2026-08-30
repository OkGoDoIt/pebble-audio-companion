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
