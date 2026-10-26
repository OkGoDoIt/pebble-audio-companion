import Foundation
import GRDB

/// Where a deliberately recorded voice sample was made (a quiet room, somewhere noisy, …), so
/// setup can ask for the situations still missing. Keyed by the sample's confirmation; the row
/// goes when the last crop of that sample does.
public struct VoiceSampleSituationStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func set(_ situation: String, confirmationID: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO voice_sample_situations(confirmationID, situation) VALUES (?, ?)",
                          arguments: [confirmationID, situation])
        }
    }

    /// Situation by confirmation ID.
    public func all() async throws -> [String: String] {
        try await db.reader.read { d in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(d,
                sql: "SELECT confirmationID, situation FROM voice_sample_situations").map {
                    ($0["confirmationID"] as String, $0["situation"] as String)
                })
        }
    }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_sample_situations (
                confirmationID TEXT PRIMARY KEY NOT NULL, situation TEXT NOT NULL
            );
            CREATE TRIGGER voice_sample_situation_orphaned AFTER DELETE ON voice_examples
            WHEN NOT EXISTS (SELECT 1 FROM voice_examples WHERE confirmationID = OLD.confirmationID) BEGIN
                DELETE FROM voice_sample_situations WHERE confirmationID = OLD.confirmationID;
            END;
            """)
    }
}
