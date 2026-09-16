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
                    -- v1 creates fifteen tables; this fixture only ever recreated the one this
                    -- suite reads, while still CLAIMING v1..v4 in `grdb_migrations`. That held
                    -- for as long as every later migration happened to touch `follow_ups` —
                    -- and then broke the day two of them did not: `v9-recap-condensation`
                    -- (`ALTER TABLE recaps`) and `v10-conversation-boundaries`
                    -- (`ALTER TABLE conversations`) both failed with "no such table", in a
                    -- suite that is about follow-ups and says nothing about either.
                    --
                    -- So the fixture, not the migrations, is what was wrong. These two are
                    -- verbatim v1 (`AppDatabase.swift`); anything a future migration alters
                    -- has to be added here the same way.
                    CREATE TABLE conversations (
                        id TEXT PRIMARY KEY,
                        startMs INTEGER NOT NULL,
                        endMs INTEGER,
                        timezone TEXT NOT NULL,
                        state TEXT NOT NULL
                    );
                    CREATE TABLE recaps (
                        dateKey TEXT PRIMARY KEY,
                        text TEXT NOT NULL,
                        segmentIds TEXT NOT NULL,
                        provider TEXT,
                        model TEXT,
                        updatedAtMs INTEGER NOT NULL
                    );
                    -- Read and written by `v11-adopt-ai-tags`, which turns the tags every
                    -- annotation already carried into rows the Library can filter on.
                    CREATE TABLE tags (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE ON CONFLICT REPLACE
                    );
                    CREATE TABLE conversation_tags (
                        conversationId TEXT NOT NULL,
                        tagId TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                        source TEXT NOT NULL,
                        PRIMARY KEY (conversationId, tagId)
                    );
                    CREATE TABLE annotations (
                        conversationId TEXT PRIMARY KEY,
                        title TEXT,
                        summary TEXT,
                        tagsJson TEXT,
                        isFinal BOOLEAN NOT NULL DEFAULT 0,
                        sourceCharCount INTEGER NOT NULL DEFAULT 0,
                        finalAttempts INTEGER NOT NULL DEFAULT 0,
                        updatedAtMs INTEGER NOT NULL DEFAULT 0
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
            // Annotations as every previous release wrote them: tags generated, stored, and
            // adopted by nothing. Note "Work" and "work" — the model title-cases whatever it
            // reads as a proper noun, so the same topic arrives both ways.
            for (conversationId, tagsJson) in [
                ("conv-0", #"["work","budget"]"#),
                ("conv-1", #"["Work","Sarah"]"#),
                ("conv-2", #"[]"#),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO annotations (conversationId, title, summary, tagsJson)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [conversationId, "A talk", "About things", tagsJson])
            }
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
            // Decoded inside the read: a GRDB `Row` is not `Sendable`, and must not cross the
            // boundary out of the reader's closure.
            let byOrigin = try await db.reader.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT origin, COUNT(*) AS n FROM follow_ups GROUP BY origin"
                ).map { ($0["origin"] as String, $0["n"] as Int) }
            }
            let counts = Dictionary(uniqueKeysWithValues: byOrigin)
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

    /// v8 columns. `touchedAtMs` is what makes Restore mean something; the backfill has to
    /// claim the rows a person plainly owns so the age rule cannot take them retroactively.
    @Test func theBookkeepingColumnsArriveAndAreBackfilled() async throws {
        try await withUpgradedDatabase(rows: 3) { db in
            let store = FollowUpStore(db: db)
            let hand = try await store.list(scope: .open, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
            #expect(hand.count == 1)
            #expect(hand.first?.touchedAtMs != nil, "a hand-written row counts as touched")

            let extracted = try await store.list(scope: .archived)
            #expect(extracted.allSatisfy { $0.touchedAtMs == nil })

            let candidates = FollowUpCandidateStore(db: db)
            try await candidates.save(
                FollowUpCandidate(
                    id: "c1", conversationId: "conv-1", task: "t", quote: "q", why: "w",
                    createdAtMs: 1, recordedAtMs: 2))
            #expect(try await candidates.pending(limit: 5).first?.recordedAtMs == 2)
            #expect(try await candidates.pending(limit: 5).first?.attempts == 0)
            try await candidates.recordAttempt(ids: ["c1"])
            #expect(try await candidates.pending(limit: 5, maxAttempts: 1).isEmpty)
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

    /// The tags every annotation already carried become tags the Library can actually filter
    /// on. Before this migration `conversation_tags` was written by the Tag Editor alone, so a
    /// library with hundreds of generated tags showed no chip row at all.
    @Test func theTagsAlreadyGeneratedBecomeTagsTheLibraryCanFilterOn() async throws {
        try await withUpgradedDatabase(rows: 3) { db in
            let tags = TagStore(db: db)
            #expect(
                try await tags.tags(forConversation: "conv-0").map(\.name) == ["budget", "work"])
            // "Work" folds into the existing "work" rather than becoming a second chip.
            #expect(try await tags.tags(forConversation: "conv-1").map(\.name) == ["Sarah", "work"])
            #expect(try await tags.tags(forConversation: "conv-2").isEmpty)
            // Adopted, not authored: the person can still remove any of them.
            #expect(
                try await tags.tags(forConversation: "conv-0").allSatisfy {
                    $0.source == TagSource.ai
                })
            let all = try await tags.listTags()
            #expect(all.first(where: { $0.name == "work" })?.count == 2)
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
