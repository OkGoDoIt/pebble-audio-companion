import Foundation
import GRDB

public enum VoiceArchiveRevocationScope: String, Sendable, Codable {
    case all, person, run
}

public struct VoiceArchiveRevocation: Equatable, Sendable {
    public var id: String
    public var originID: String
    public var generation: Int64
    public var scope: VoiceArchiveRevocationScope
    public var targetID: String?
    public var createdAtMs: Int64
}

/// Durable privacy decisions outlive local audio and voice rows. Archive retries can deliver
/// these after retention/unlinking, and their monotonic generation rejects older uploads.
public struct VoiceArchiveRevocationStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func load(id: String) async throws -> VoiceArchiveRevocation? {
        try await db.reader.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM voice_archive_revocations WHERE id = ?",
                             arguments: [id]).map(Self.record)
        }
    }
    public func all() async throws -> [VoiceArchiveRevocation] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM voice_archive_revocations ORDER BY generation, id").map(Self.record)
        }
    }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_archive_state (
                id INTEGER PRIMARY KEY CHECK(id = 1), originID TEXT NOT NULL,
                generation INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE voice_archive_revocations (
                id TEXT PRIMARY KEY NOT NULL, originID TEXT NOT NULL, generation INTEGER NOT NULL,
                scope TEXT NOT NULL CHECK(scope IN ('all','person','run')), targetID TEXT,
                createdAtMs INTEGER NOT NULL,
                CHECK((scope = 'all' AND targetID IS NULL) OR (scope <> 'all' AND targetID IS NOT NULL))
            );
            ALTER TABLE voice_auto_attributions ADD COLUMN archiveGeneration INTEGER NOT NULL DEFAULT 0;
            """)
        try d.execute(sql: "INSERT INTO voice_archive_state(id,originID) VALUES (1,?)",
                      arguments: [UUID().uuidString.lowercased()])
        try d.execute(sql: """
            CREATE TRIGGER voice_archive_example_deleted AFTER DELETE ON voice_examples BEGIN
                \(revokeSQL(scope: "'person'", targetID: "OLD.personId"))
            END;
            """)
        // Partial migration fixtures may not contain the archive subsystem.
        if try d.tableExists("sync_outbox") {
            try d.execute(sql: """
                CREATE TRIGGER voice_archive_revocation_created AFTER INSERT ON voice_archive_revocations BEGIN
                    \(ArchiveOutbox.enqueueSQL(kind: "'voiceRevocation'", id: "NEW.id", op: "'upsert'"))
                END;
                """)
        }
    }

    /// Only trusted SQL expressions from our trigger definitions are interpolated here.
    private static func revokeSQL(scope: String, targetID: String) -> String {
        """
        UPDATE voice_archive_state SET generation = generation + 1 WHERE id = 1;
        INSERT INTO voice_archive_revocations(id,originID,generation,scope,targetID,createdAtMs)
            SELECT lower(hex(randomblob(16))),originID,generation,\(scope),\(targetID),\(ArchiveOutbox.nowMsSQL)
            FROM voice_archive_state WHERE id = 1;
        """
    }

    static func revoke(_ d: Database, scope: VoiceArchiveRevocationScope, targetID: String? = nil,
                       nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        guard scope == .all ? targetID == nil : targetID?.isEmpty == false else {
            throw VoiceIdentityError.invalidRecord
        }
        try d.execute(sql: "UPDATE voice_archive_state SET generation = generation + 1 WHERE id = 1")
        try d.execute(sql: """
            INSERT INTO voice_archive_revocations(id,originID,generation,scope,targetID,createdAtMs)
                SELECT ?,originID,generation,?,?,? FROM voice_archive_state WHERE id = 1
            """, arguments: [UUID().uuidString.lowercased(), scope.rawValue, targetID, nowMs])
    }

    /// An old backup cannot know the server's highest generation. Missing device-bound keys
    /// retire that origin permanently, then new explicit enrollment starts a fresh namespace.
    static func retireOrigin(_ d: Database) throws {
        try d.execute(sql: """
            INSERT INTO voice_archive_revocations(id,originID,generation,scope,targetID,createdAtMs)
                SELECT ?,originID,?,'all',NULL,? FROM voice_archive_state WHERE id = 1
            """, arguments: [UUID().uuidString.lowercased(), Int64.max,
                              Int64(Date().timeIntervalSince1970 * 1000)])
        try d.execute(sql: "UPDATE voice_archive_state SET originID = ?, generation = 0 WHERE id = 1",
                      arguments: [UUID().uuidString.lowercased()])
    }

    private static func record(_ r: Row) -> VoiceArchiveRevocation {
        VoiceArchiveRevocation(id: r["id"], originID: r["originID"], generation: r["generation"],
            scope: VoiceArchiveRevocationScope(rawValue: r["scope"])!, targetID: r["targetID"],
            createdAtMs: r["createdAtMs"])
    }
}
