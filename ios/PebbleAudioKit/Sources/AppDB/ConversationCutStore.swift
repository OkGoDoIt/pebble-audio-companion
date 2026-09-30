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

    /// Delete-cascade support for PART of a segment: a stretch of stored audio that has been
    /// deleted keeps no cut and no decision inside it. Start-inclusive and end-exclusive, like
    /// the piece it is called for (`ConversationMember.contains`): the cut AT the range's
    /// start is the one that began the deleted conversation and goes with it; the cut at its
    /// end begins the conversation that follows, and stays.
    ///
    /// Without this the rows are about words that no longer exist. A settled cut would be
    /// dropped by the planner each time it plans the run (`droppingEmptyUnits`) and sit in the
    /// table for ever; a person's split would do the same; a person's "these are one
    /// conversation" would go on holding automatic cuts away from a place nothing is said.
    public func forget(segmentId: String, mediaRangeMs: Range<Int64>) async throws {
        guard !mediaRangeMs.isEmpty else { return }
        try await db.writer.write { db in
            for table in ["conversation_cuts", "conversation_cut_overrides"] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE segmentId = ? AND mediaMs >= ? AND mediaMs < ?",
                    arguments: [segmentId, mediaRangeMs.lowerBound, mediaRangeMs.upperBound])
            }
        }
    }

    /// Delete-cascade support: takes audio that has just been deleted out of the STORED
    /// grouping. `pieces` are the pieces of the deleted conversation that were destroyed — a
    /// whole segment each, or a range of one.
    ///
    /// The stored grouping is what the next rebuild adopts ids from
    /// (`ConversationGrouper.adoptStableIds`): a conversation takes the id of whichever stored
    /// conversation contained the moment it now starts at. A deleted range of a shared segment
    /// is silence, and the planner gives silence to a neighbour. So, left in the table, the
    /// deleted conversation hands its ID to that neighbour: when the deleted one opened its
    /// run, the conversation after it comes back under the id whose title, notes and tags the
    /// cascade has just destroyed, and its own are left under an id nothing answers to.
    /// Deleting a conversation must not rename the one next to it.
    ///
    /// For each deleted range, then:
    ///  - a stored piece lying inside it is removed (that is the deleted conversation's, and
    ///    any fragment a rebuild made of it while the delete was in progress);
    ///  - a stored piece that starts in it or at its end and runs on past it — the
    ///    conversation that FOLLOWS — is extended back to the range's start;
    ///  - a stored piece that runs into it from before is cut back to the range's start.
    /// and a stored conversation left with no piece is removed. Whatever the planner then does
    /// with the silence — leaves it with the conversation before, or lets the one after begin
    /// earlier — each surviving conversation starts inside a stored piece of its own, and
    /// keeps its id.
    ///
    /// Idempotent, and written against the ranges rather than against the deleted
    /// conversation's rows, because the pipeline's own rebuild can run while a delete is in
    /// progress and rewrite those rows; the cascade calls this again after such a window.
    ///
    /// Derived state, rewritten by the rebuild that follows; this only decides what that
    /// rebuild sees as "before".
    public func releaseStoredPlace(of pieces: [ConversationMember]) async throws {
        guard !pieces.isEmpty else { return }
        try await db.writer.write { db in
            for piece in pieces {
                if piece.isWhole {
                    try db.execute(
                        sql: "DELETE FROM conversation_segments WHERE segmentId = ?",
                        arguments: [piece.segmentId])
                    continue
                }
                let lower = piece.startMediaMs ?? 0
                let upper = piece.endMediaMs ?? Int64.max
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT conversationId, ordinal, startMediaMs, endMediaMs
                        FROM conversation_segments WHERE segmentId = ?
                        """,
                    arguments: [piece.segmentId])
                for row in rows {
                    let key: StatementArguments = [row["conversationId"] as String, row["ordinal"] as Int]
                    let start = (row["startMediaMs"] as Int64?) ?? 0
                    let end = (row["endMediaMs"] as Int64?) ?? Int64.max
                    if start >= lower, end <= upper {
                        try db.execute(
                            sql: """
                                DELETE FROM conversation_segments
                                WHERE conversationId = ? AND ordinal = ?
                                """,
                            arguments: key)
                    } else if start >= lower, start <= upper {
                        try db.execute(
                            sql: """
                                UPDATE conversation_segments SET startMediaMs = ?
                                WHERE conversationId = ? AND ordinal = ?
                                """,
                            arguments: [lower > 0 ? lower : nil] + key)
                    } else if start < lower, end > lower, end <= upper {
                        try db.execute(
                            sql: """
                                UPDATE conversation_segments SET endMediaMs = ?
                                WHERE conversationId = ? AND ordinal = ?
                                """,
                            arguments: [lower] + key)
                    }
                }
            }
            try db.execute(
                sql: """
                    DELETE FROM conversations
                    WHERE id NOT IN (SELECT conversationId FROM conversation_segments)
                    """)
        }
    }
}

// MARK: - Range-delete support for the follow-up staging table

extension FollowUpCandidateStore {
    /// Delete-cascade support for PART of a segment: the candidates proposed from words that
    /// were spoken in `mediaRangeMs` of `segmentId`. `deleteForSegment` would take the
    /// neighbouring conversation's proposals with them — one segment routinely holds the end
    /// of one conversation and the start of the next.
    ///
    /// A candidate with no position inside its segment cannot be placed, so it goes only when
    /// it names the conversation being deleted.
    public func deleteForRange(
        segmentId: String, mediaRangeMs: Range<Int64>, conversationId: String?
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM follow_up_candidates
                    WHERE segmentId = ?
                        AND ((startMs IS NOT NULL AND startMs >= ? AND startMs < ?)
                            OR (startMs IS NULL AND conversationId = ?))
                    """,
                arguments: [
                    segmentId, mediaRangeMs.lowerBound, mediaRangeMs.upperBound, conversationId,
                ])
        }
    }
}
