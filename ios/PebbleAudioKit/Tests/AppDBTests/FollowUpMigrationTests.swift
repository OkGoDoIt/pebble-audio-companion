import Foundation
import GRDB
import Testing

@testable import AppDB

// The upgrade this release performs on a database that already exists.
//
// Every other test in this suite starts from `AppDatabase.inMemory()`, which runs every
// migration at once against an empty schema — it can never catch a migration that is wrong
// about the rows already there. This one builds a v1-era database by hand, fills it with the
// shape the phone actually holds (dozens of extracted rows, a couple already ticked off), and
// then opens it the way the app does.

@Suite struct FollowUpMigrationTests {
    /// A database as the previous release left it: v1..v4 applied, the original six-column
    /// `follow_ups`, and rows written by the old extractor.
    private func legacyDatabase(at url: URL, rows: Int) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                    INSERT INTO grdb_migrations VALUES
                        ('v1'), ('v2-segment-transcription-state'),
                        ('v3-ask-history-threads'), ('v4-ask-history-coverage');
                    CREATE TABLE follow_ups (
                        id TEXT PRIMARY KEY,
                        text TEXT NOT NULL,
                        done BOOLEAN NOT NULL DEFAULT 0,
                        sourceConversationId TEXT,
                        sourceSegmentId TEXT,
                        createdAtMs INTEGER NOT NULL
                    );
                    """)
            for index in 0..<rows {
                try db.execute(
                    sql: """
                        INSERT INTO follow_ups
                            (id, text, done, sourceConversationId, sourceSegmentId, createdAtMs)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "conv-\(index)-action-\(index)",
                        "Improve transcription UI formatting. Owner: Roger",
                        index % 10 == 0, "conv-\(index)", "seg-\(index)",
                        1_780_000_000_000 + Int64(index),
                    ])
            }
            // One the person typed themselves: a UUID id, no `-action-` in it.
            try db.execute(
                sql: """
                    INSERT INTO follow_ups
                        (id, text, done, sourceConversationId, sourceSegmentId, createdAtMs)
                    VALUES (?, ?, 0, NULL, NULL, ?)
                    """,
                arguments: [UUID().uuidString.lowercased(), "Mine", 1_780_000_000_000])
        }
        try queue.close()
    }

    private func withUpgradedDatabase(
        rows: Int = 55, _ body: (AppDatabase) async throws -> Void
    ) async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("followups-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try legacyDatabase(at: url, rows: rows)
        let db = try AppDatabase.open(at: url)
        try await body(db)
    }

    @Test func theUpgradeRunsAndKeepsEveryRow() async throws {
        try await withUpgradedDatabase { db in
            let total = try await db.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM follow_ups") ?? 0
            }
            #expect(total == 56, "nothing is deleted by the upgrade")

            let applied = try await db.reader.read { db in
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            }
            #expect(applied.contains("v5-follow-up-detail"))
            #expect(applied.contains("v6-follow-up-candidates"))
            #expect(applied.contains("v7-refresh-follow-ups"))
        }
    }

    /// `origin` replaces the old "does the id contain -action-" sniffing, and the backfill has
    /// to get it right or a person's own follow-ups start being curated and aged out.
    @Test func originIsBackfilledFromTheIdShape() async throws {
        try await withUpgradedDatabase { db in
            let byOrigin = try await db.reader.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT origin, COUNT(*) AS n FROM follow_ups GROUP BY origin")
            }
            let counts = Dictionary(
                uniqueKeysWithValues: byOrigin.map { ($0["origin"] as String, $0["n"] as Int) })
            #expect(counts["ai"] == 55)
            #expect(counts["user"] == 1)
        }
    }

    /// The whole point of v7: the list starts from the new extractor's work, not the old one's.
    /// Filed away, never deleted — and a tick the person already made survives untouched.
    @Test func theOldSuggestionsAreFiledAwayAndTicksAreKept() async throws {
        try await withUpgradedDatabase { db in
            let store = FollowUpStore(db: db)
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            let open = try await store.list(scope: .open, nowMs: now)
            #expect(open.count == 1, "only the hand-written one is still on the list")
            #expect(open.first?.text == "Mine")
            #expect(open.first?.origin == .user)

            let archived = try await store.list(scope: .archived)
            // 55 extracted rows, six of them already ticked: the 49 still open are filed away.
            #expect(archived.count == 49, "the open AI suggestions are filed away, not deleted")
            #expect(archived.allSatisfy { $0.origin == .ai })

            // Ticked rows keep their tick, and gain the completion time the old schema had
            // nowhere to put — otherwise every already-done item would vanish from Completed.
            let completed = try await store.list(scope: .completed)
            #expect(completed.count == 6)
            #expect(completed.allSatisfy { $0.done && $0.completedAtMs != nil })
        }
    }

    /// Extraction bookkeeping is dropped so recent conversations are read again by the new
    /// pass. It is created outside the migrator, so the migration has to tolerate its absence.
    @Test func theExtractionBookkeepingIsClearedAndRebuilds() async throws {
        try await withUpgradedDatabase(rows: 3) { db in
            let store = try FollowUpExtractionStoreProbe(db: db)
            #expect(try store.settledCount() == 0)
        }
    }

    @Test func theCandidateTableIsReadyToWrite() async throws {
        try await withUpgradedDatabase(rows: 3) { db in
            let candidates = FollowUpCandidateStore(db: db)
            try await candidates.save(
                FollowUpCandidate(
                    id: "c1", conversationId: "conv-1", task: "Take Theo at 7:00",
                    quote: "I got to take Theo at 7:00.", why: "Theo misses his ride",
                    createdAtMs: 1))
            #expect(try await candidates.pendingCount() == 1)
        }
    }
}

/// The extraction table lives in the Intelligence module, which AppDB tests cannot import.
/// This is the same `CREATE TABLE IF NOT EXISTS` it performs, so the assertion is that v7 left
/// nothing behind for it to inherit.
private struct FollowUpExtractionStoreProbe {
    let db: AppDatabase

    init(db: AppDatabase) throws {
        self.db = db
        try db.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS follow_up_extractions (
                        conversationId TEXT PRIMARY KEY,
                        sourceCharCount INTEGER NOT NULL DEFAULT 0,
                        settled BOOLEAN NOT NULL DEFAULT 0,
                        itemCount INTEGER NOT NULL DEFAULT 0,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        lastError TEXT,
                        updatedAtMs INTEGER NOT NULL DEFAULT 0
                    )
                    """)
        }
    }

    func settledCount() throws -> Int {
        try db.reader.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM follow_up_extractions WHERE settled = 1") ?? 0
        }
    }
}
