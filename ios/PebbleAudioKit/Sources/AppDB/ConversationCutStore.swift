import Foundation
import GRDB

// Positions inside segments where a conversation starts (migration `conversation-ranges-v1`).
//
// Two tables with opposite lifetimes, like `boundary_overrides` / `boundary_reviews`:
//  - `conversation_cuts`: the segmenter's SETTLED decisions. Derived — dropping a row costs one
//    re-decision — but held once written, so a conversation's id, title and notes do not move
//    each time the day grows.
//  - `conversation_cut_overrides`: the person's own "start a new conversation here" and "these
//    are one conversation". Authoritative, never dropped except with the recording itself.

public struct ConversationCutStore: Sendable {
    /// Bumped when the segmenter changes in a way that should re-decide the whole library.
    /// Rows written by another version are ignored and replaced.
    public static let algorithm = 1

    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Everything the grouper needs about positions inside segments. Overrides at a segment's
    /// own start (`mediaMs == 0`) are folded into `overrides`, which is where decisions about
    /// a segment's start have always lived.
    public static func fetchInputs(
        _ db: Database, into overrides: inout [String: BoundaryDecision]
    ) throws -> ConversationCutInputs {
        var inputs = ConversationCutInputs()
        for row in try Row.fetchAll(
            db,
            sql: "SELECT segmentId, mediaMs, reason FROM conversation_cuts WHERE algorithm = ?",
            arguments: [algorithm])
        {
            let reason =
                ConversationStartReason(rawValue: row["reason"]) ?? .topicChange
            inputs.committed[row["segmentId"], default: [:]][row["mediaMs"]] = reason
        }
        for row in try Row.fetchAll(
            db, sql: "SELECT segmentId, mediaMs, decision FROM conversation_cut_overrides")
        {
            guard let decision = BoundaryDecision(rawValue: row["decision"]) else { continue }
            let segmentId: String = row["segmentId"]
            let mediaMs: Int64 = row["mediaMs"]
            if mediaMs <= 0 {
                overrides[segmentId] = decision
                continue
            }
            switch decision {
            case .split: inputs.splits[segmentId, default: []].insert(mediaMs)
            case .join: inputs.joins[segmentId, default: []].insert(mediaMs)
            }
        }
        return inputs
    }

    /// Writes newly settled cuts. Existing rows are left exactly as they are: a settled cut is
    /// never re-dated or re-explained.
    static func commit(
        _ cuts: [ConversationCut: ConversationStartReason], atMs: Int64, in db: Database
    ) throws {
        for (cut, reason) in cuts where cut.mediaMs > 0 {
            try db.execute(
                sql: """
                    INSERT INTO conversation_cuts
                        (segmentId, mediaMs, reason, algorithm, createdAtMs)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(segmentId, mediaMs) DO UPDATE SET
                        reason = excluded.reason, algorithm = excluded.algorithm,
                        createdAtMs = excluded.createdAtMs
                    WHERE conversation_cuts.algorithm <> excluded.algorithm
                    """,
                arguments: [cut.segmentId, cut.mediaMs, reason.rawValue, algorithm, atMs])
        }
    }

    /// The settled cuts, for tests and diagnostics.
    public func committed() async throws -> [ConversationCut] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT segmentId, mediaMs FROM conversation_cuts WHERE algorithm = ?
                    ORDER BY segmentId, mediaMs
                    """,
                arguments: [Self.algorithm]
            ).map { ConversationCut(segmentId: $0["segmentId"], mediaMs: $0["mediaMs"]) }
        }
    }

    /// The person's decision at a position. `nil` clears it and hands the place back to the
    /// rules, which is what makes every manual split and join undoable.
    public func setOverride(
        at cut: ConversationCut, decision: BoundaryDecision?,
        atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            guard let decision else {
                try db.execute(
                    sql: """
                        DELETE FROM conversation_cut_overrides
                        WHERE segmentId = ? AND mediaMs = ?
                        """,
                    arguments: [cut.segmentId, cut.mediaMs])
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO conversation_cut_overrides
                        (segmentId, mediaMs, decision, createdAtMs)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(segmentId, mediaMs) DO UPDATE SET
                        decision = excluded.decision, createdAtMs = excluded.createdAtMs
                    """,
                arguments: [cut.segmentId, cut.mediaMs, decision.rawValue, atMs])
        }
    }

    /// The person's decisions inside segments: position → decision.
    public func overrides() async throws -> [ConversationCut: BoundaryDecision] {
        try await db.reader.read { db in
            var out: [ConversationCut: BoundaryDecision] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT segmentId, mediaMs, decision FROM conversation_cut_overrides")
            {
                guard let decision = BoundaryDecision(rawValue: row["decision"]) else { continue }
                out[ConversationCut(segmentId: row["segmentId"], mediaMs: row["mediaMs"])] =
                    decision
            }
            return out
        }
    }

    /// Delete-cascade support: a segment that no longer exists keeps no cut and no decision.
    public func forget(segmentIds: [String]) async throws {
        guard !segmentIds.isEmpty else { return }
        try await db.writer.write { db in
            let marks = databaseQuestionMarks(count: segmentIds.count)
            try db.execute(
                sql: "DELETE FROM conversation_cuts WHERE segmentId IN (\(marks))",
                arguments: StatementArguments(segmentIds))
            try db.execute(
                sql: "DELETE FROM conversation_cut_overrides WHERE segmentId IN (\(marks))",
                arguments: StatementArguments(segmentIds))
        }
    }
}
