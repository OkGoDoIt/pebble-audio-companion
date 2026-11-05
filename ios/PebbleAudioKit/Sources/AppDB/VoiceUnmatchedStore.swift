import Foundation
import GRDB

/// A voice crop recognition heard but could name as no one. Kept so voices that recur unnamed
/// across recordings can be grouped and offered for naming. Its embedding is sealed with the
/// device-bound voice key like every confirmed example.
public struct VoiceUnmatchedCrop: Equatable, Sendable {
    public var id: String
    public var segmentId: String
    public var startMediaMs: Int64
    public var endMediaMs: Int64
    public var sourceRevision: String
    public var recipeID: String
    public var embeddingJSON: Data
    public var speechConfidence: Double
    public var createdAtMs: Int64
    public init(id: String = UUID().uuidString.lowercased(), segmentId: String, startMediaMs: Int64,
                endMediaMs: Int64, sourceRevision: String, recipeID: String, embeddingJSON: Data,
                speechConfidence: Double, createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.segmentId = segmentId; self.startMediaMs = startMediaMs
        self.endMediaMs = endMediaMs; self.sourceRevision = sourceRevision; self.recipeID = recipeID
        self.embeddingJSON = embeddingJSON; self.speechConfidence = speechConfidence; self.createdAtMs = createdAtMs
    }
}

/// Unnamed voices follow the life of everything else derived from a recording: a source that is
/// deleted, expired, redacted or re-read loses them, and turning recognition off clears them all.
public struct VoiceUnmatchedStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Bounded: the oldest go first. Grouping looks at recent voices.
    public static let capacity = 2_000

    /// The most recent crops still unnamed: none inside a range a person has named by hand, or
    /// that recognition has since named.
    public func recent(limit: Int) async throws -> [VoiceUnmatchedCrop] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT u.* FROM voice_unmatched_crops u
                WHERE NOT EXISTS (SELECT 1 FROM voice_auto_attributions a WHERE a.segmentId = u.segmentId
                        AND a.startMediaMs < u.endMediaMs AND a.endMediaMs > u.startMediaMs)
                  AND NOT EXISTS (SELECT 1 FROM speaker_corrections c WHERE c.segmentId = u.segmentId
                        AND c.startMediaMs < u.endMediaMs AND c.endMediaMs > u.startMediaMs)
                ORDER BY u.createdAtMs DESC, u.id LIMIT ?
                """, arguments: [limit]).map(Self.crop)
        }
    }

    /// Changes whenever `recent` could: crops added or removed, or names set or recognized
    /// (the identity revision). One small read, so screens that reload often can ask it first.
    public func fingerprint() async throws -> String {
        try await db.reader.read { d in
            let row = try Row.fetchOne(d, sql: """
                SELECT (SELECT COUNT(*) FROM voice_unmatched_crops) AS crops,
                       (SELECT COALESCE(MAX(createdAtMs), 0) FROM voice_unmatched_crops) AS newest,
                       (SELECT COALESCE(MAX(revision), 0) FROM speaker_identity_state) AS identity
                """)
            return "\(row?["crops"] as Int64? ?? 0):\(row?["newest"] as Int64? ?? 0):\(row?["identity"] as Int64? ?? 0)"
        }
    }

    public func remove(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await db.writer.write { d in
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try d.execute(sql: "DELETE FROM voice_unmatched_crops WHERE id IN (\(marks))",
                              arguments: StatementArguments(chunk))
            }
        }
    }

    /// A human dismissal belongs to this audio range, never to an embedding or a person.
    /// Keep it across model changes, reanalysis, and recognition being toggled off and on.
    public func ignore(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws {
        guard !segmentId.isEmpty, startMediaMs >= 0, endMediaMs > startMediaMs else {
            throw VoiceIdentityError.invalidRecord
        }
        try await db.writer.write { d in
            try Self.ignore(d, segmentId: segmentId, start: startMediaMs, end: endMediaMs)
        }
    }

    public func ignore(_ crops: [VoiceUnmatchedCrop]) async throws {
        try await db.writer.write { d in
            for crop in crops {
                try Self.ignore(d, segmentId: crop.segmentId, start: crop.startMediaMs, end: crop.endMediaMs)
            }
        }
    }

    /// Also check saved decisions when naming a group captured before a dismissal.
    public func excludingIgnored(_ crops: [VoiceUnmatchedCrop]) async throws -> [VoiceUnmatchedCrop] {
        try await db.reader.read { d in
            try crops.filter { crop in
                try Bool.fetchOne(d, sql: """
                    SELECT EXISTS(SELECT 1 FROM voice_ignored_clips WHERE segmentId = ?
                        AND startMediaMs < ? AND endMediaMs > ?)
                    """, arguments: [crop.segmentId, crop.endMediaMs, crop.startMediaMs]) != true
            }
        }
    }

    private static func ignore(_ d: Database, segmentId: String, start: Int64, end: Int64) throws {
        // A stale sheet must not recreate metadata for a deleted recording.
        try d.execute(sql: """
            INSERT OR IGNORE INTO voice_ignored_clips(segmentId,startMediaMs,endMediaMs)
            SELECT ?,?,? WHERE EXISTS (SELECT 1 FROM voice_sources WHERE segmentId = ? AND state NOT IN ('deleted','expired'))
            """, arguments: [segmentId, start, end, segmentId])
        try d.execute(sql: """
            DELETE FROM voice_unmatched_crops WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?
            """, arguments: [segmentId, end, start])
    }

    static func installIgnoredClipsSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_ignored_clips (
                segmentId TEXT NOT NULL, startMediaMs INTEGER NOT NULL, endMediaMs INTEGER NOT NULL,
                PRIMARY KEY(segmentId,startMediaMs,endMediaMs),
                CHECK(startMediaMs >= 0 AND endMediaMs > startMediaMs)
            );
            CREATE TRIGGER voice_unmatched_skip_ignored BEFORE INSERT ON voice_unmatched_crops
            WHEN EXISTS (SELECT 1 FROM voice_ignored_clips i WHERE i.segmentId = NEW.segmentId
                AND i.startMediaMs < NEW.endMediaMs AND i.endMediaMs > NEW.startMediaMs)
            BEGIN SELECT RAISE(IGNORE); END;
            CREATE TRIGGER voice_ignored_source_deleted AFTER DELETE ON voice_sources BEGIN
                DELETE FROM voice_ignored_clips WHERE segmentId = OLD.segmentId;
            END;
            CREATE TRIGGER voice_ignored_source_retired AFTER UPDATE OF state ON voice_sources
            WHEN NEW.state IN ('deleted','expired') BEGIN
                DELETE FROM voice_ignored_clips WHERE segmentId = NEW.segmentId;
            END;
            """)
    }

    static func insert(_ d: Database, _ crops: [VoiceUnmatchedCrop]) throws {
        guard !crops.isEmpty else { return }
        for c in crops {
            try d.execute(sql: """
                INSERT OR IGNORE INTO voice_unmatched_crops(id,segmentId,startMediaMs,endMediaMs,sourceRevision,
                    recipeID,embeddingJSON,speechConfidence,createdAtMs) VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [c.id, c.segmentId, c.startMediaMs, c.endMediaMs, c.sourceRevision, c.recipeID,
                                 c.embeddingJSON, c.speechConfidence, c.createdAtMs])
        }
        try d.execute(sql: """
            DELETE FROM voice_unmatched_crops WHERE id IN (
                SELECT id FROM voice_unmatched_crops ORDER BY createdAtMs DESC, id LIMIT -1 OFFSET ?)
            """, arguments: [capacity])
    }

    private static func crop(_ row: Row) -> VoiceUnmatchedCrop {
        VoiceUnmatchedCrop(id: row["id"], segmentId: row["segmentId"], startMediaMs: row["startMediaMs"],
            endMediaMs: row["endMediaMs"], sourceRevision: row["sourceRevision"], recipeID: row["recipeID"],
            embeddingJSON: row["embeddingJSON"], speechConfidence: row["speechConfidence"], createdAtMs: row["createdAtMs"])
    }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_unmatched_crops (
                id TEXT PRIMARY KEY NOT NULL, segmentId TEXT NOT NULL,
                startMediaMs INTEGER NOT NULL, endMediaMs INTEGER NOT NULL,
                sourceRevision TEXT NOT NULL, recipeID TEXT NOT NULL, embeddingJSON BLOB NOT NULL,
                speechConfidence REAL NOT NULL, createdAtMs INTEGER NOT NULL
            );
            CREATE INDEX voice_unmatched_segment ON voice_unmatched_crops(segmentId, startMediaMs);
            CREATE INDEX voice_unmatched_recent ON voice_unmatched_crops(createdAtMs);
            CREATE TRIGGER voice_unmatched_source_changed AFTER UPDATE OF generation ON voice_sources
            WHEN NEW.generation <> OLD.generation BEGIN
                DELETE FROM voice_unmatched_crops WHERE segmentId = NEW.segmentId;
            END;
            CREATE TRIGGER voice_unmatched_source_deleted AFTER DELETE ON voice_sources BEGIN
                DELETE FROM voice_unmatched_crops WHERE segmentId = OLD.segmentId;
            END;
            CREATE TRIGGER voice_unmatched_recognition_off AFTER UPDATE OF mode ON voice_recognition_config
            WHEN NEW.mode = 'off' BEGIN
                DELETE FROM voice_unmatched_crops;
            END;
            """)
    }
}
