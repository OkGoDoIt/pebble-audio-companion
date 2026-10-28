import Foundation
import GRDB

public struct VoiceHistoryPlan: Equatable, Sendable {
    public var runID: String
    public var fromMs: Int64
    public var toMs: Int64
    public var cursorStartMs: Int64
    public var cursorSegmentId: String
    public var discoveryComplete: Bool
    public var state: String
    public var queuedCount: Int
    public var createdAtMs: Int64
    public var corpusRevision: Int64
}

/// A finite explicit history request survives suspension without filling an unbounded job
/// queue. Discovery advances in the stable (recorded start, segment ID) order, independently
/// of the bounded inference queue. Cancelling/undoing a run also stops discovery.
public struct VoiceHistoryPlanStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_history_plans (
                runID TEXT PRIMARY KEY NOT NULL REFERENCES voice_runs(runID) ON DELETE CASCADE,
                fromMs INTEGER NOT NULL, toMs INTEGER NOT NULL,
                cursorStartMs INTEGER NOT NULL DEFAULT -9223372036854775808,
                cursorSegmentId TEXT NOT NULL DEFAULT '', discoveryComplete INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL DEFAULT 'active', queuedCount INTEGER NOT NULL DEFAULT 0,
                createdAtMs INTEGER NOT NULL, corpusRevision INTEGER NOT NULL
            );
            """)
    }

    public func create(runID: String, fromMs: Int64, toMs: Int64,
                       nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        guard !runID.isEmpty, fromMs < toMs else { throw VoiceIdentityError.invalidRecord }
        try await db.writer.write { d in
            let config = try VoiceIdentityStore.configuration(d)
            guard config.mode == .local else { throw VoiceIdentityError.disabled }
            guard try VoiceIdentityStore.activeRun(d, id: runID) else { throw VoiceIdentityError.invalidRecord }
            try d.execute(sql: """
                INSERT INTO voice_history_plans(runID,fromMs,toMs,createdAtMs,corpusRevision) VALUES (?,?,?,?,?)
                """, arguments: [runID, fromMs, toMs, nowMs, config.corpusRevision])
        }
    }

    public func plans() async throws -> [VoiceHistoryPlan] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM voice_history_plans ORDER BY createdAtMs DESC, runID DESC LIMIT 100").map(Self.plan)
        }
    }

    public func advance(runID: String, startMs: Int64, segmentId: String,
                        queued: Bool, complete: Bool = false) async throws {
        try await db.writer.write { d in
            try d.execute(sql: """
                UPDATE voice_history_plans SET cursorStartMs = ?, cursorSegmentId = ?,
                    queuedCount = queuedCount + ?, discoveryComplete = ?
                WHERE runID = ? AND state = 'active' AND discoveryComplete = 0
                    AND (cursorStartMs < ? OR (cursorStartMs = ? AND cursorSegmentId <= ?))
                    AND EXISTS(SELECT 1 FROM voice_runs WHERE runID = ? AND state = 'active')
                """, arguments: [startMs, segmentId, queued ? 1 : 0, complete, runID,
                    startMs, startMs, segmentId, runID])
        }
    }

    public func finishDiscovery(runID: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE voice_history_plans SET discoveryComplete = 1 WHERE runID = ? AND state = 'active'", arguments: [runID])
        }
    }

    public func cancel(runID: String, undo: Bool = false) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE voice_history_plans SET state = ? WHERE runID = ?",
                          arguments: [undo ? "undone" : "cancelled", runID])
        }
    }

    static func plan(_ row: Row) -> VoiceHistoryPlan {
        VoiceHistoryPlan(runID: row["runID"], fromMs: row["fromMs"], toMs: row["toMs"],
            cursorStartMs: row["cursorStartMs"], cursorSegmentId: row["cursorSegmentId"],
            discoveryComplete: row["discoveryComplete"], state: row["state"],
            queuedCount: row["queuedCount"], createdAtMs: row["createdAtMs"], corpusRevision: row["corpusRevision"])
    }
}
