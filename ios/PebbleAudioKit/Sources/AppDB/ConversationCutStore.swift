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

    /// A span that runs to the end of a segment, whatever its length: past every real offset.
    static let endOfSegment = Int64.max

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
        for row in try Row.fetchAll(db, sql: "SELECT * FROM conversation_cut_overrides") {
            guard let decision = BoundaryDecision(rawValue: row["decision"]) else { continue }
            let segmentId: String = row["segmentId"]
            let mediaMs: Int64 = row["mediaMs"]
            var hasSpan = false
            if decision == .join, let from: String = row["spanFromSegmentId"] {
                hasSpan = true
                let toSegment: String? = row["spanToSegmentId"]
                inputs.joinSpans.append(
                    ConversationCutInputs.JoinSpan(
                        from: ConversationCut(
                            segmentId: from, mediaMs: row["spanFromMediaMs"] ?? 0),
                        to: toSegment.map {
                            ConversationCut(segmentId: $0, mediaMs: row["spanToMediaMs"] ?? 0)
                        }))
            }
            if mediaMs <= 0 {
                overrides[segmentId] = decision
                continue
            }
            switch decision {
            case .split: inputs.splits[segmentId, default: []].insert(mediaMs)
            // A join that recorded its span is protected by the span — exactly the two
            // conversations it joined — and must not also push away the cut that starts the
            // conversation after them, which a two-minute reach around the point would do
            // whenever the joined conversation was short.
            case .join: if !hasSpan { inputs.joins[segmentId, default: []].insert(mediaMs) }
            }
        }
        return inputs
    }

    /// "This conversation and the one before it are one conversation."
    ///
    /// Written from the grouping as it is stored right now: the decision is about those two
    /// conversations, so what it records is the point between them AND their whole extent —
    /// the start of the earlier one to the start of whatever follows the later one. Inside
    /// that span no rule cuts again. Returns the position the join was written at, or nil when
    /// the conversation does not exist or nothing comes before it.
    ///
    /// Undo with `setOverride(at:decision: nil)` at the returned position.
    @discardableResult
    public func joinWithPrevious(
        conversationId: String, atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> ConversationCut? {
        try await db.writer.write { db in
            let grouping = try ConversationGrouper.fetchAll(db)
            guard let index = grouping.firstIndex(where: { $0.id == conversationId }),
                index > 0, let first = grouping[index].members.first,
                let earlier = grouping[index - 1].members.first
            else { return nil }
            let at = ConversationCut(segmentId: first.segmentId, mediaMs: first.startMediaMs ?? 0)
            let from = ConversationCut(
                segmentId: earlier.segmentId, mediaMs: earlier.startMediaMs ?? 0)
            // Where the joined pair ends: where the next conversation starts, or — when this
            // is the latest one — the end of the piece it ends on. Never "whatever comes
            // after": a join is about the two conversations that exist, and what is recorded
            // later must still be divided like any other talk.
            var to: ConversationCut?
            if index + 1 < grouping.count, let next = grouping[index + 1].members.first {
                to = ConversationCut(segmentId: next.segmentId, mediaMs: next.startMediaMs ?? 0)
            } else if let last = grouping[index].members.last {
                to = ConversationCut(
                    segmentId: last.segmentId, mediaMs: last.endMediaMs ?? Self.endOfSegment)
            }
            try db.execute(
                sql: """
                    INSERT INTO conversation_cut_overrides
                        (segmentId, mediaMs, decision, createdAtMs, spanFromSegmentId,
                         spanFromMediaMs, spanToSegmentId, spanToMediaMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(segmentId, mediaMs) DO UPDATE SET
                        decision = excluded.decision, createdAtMs = excluded.createdAtMs,
                        spanFromSegmentId = excluded.spanFromSegmentId,
                        spanFromMediaMs = excluded.spanFromMediaMs,
                        spanToSegmentId = excluded.spanToSegmentId,
                        spanToMediaMs = excluded.spanToMediaMs
                    """,
                arguments: [
                    at.segmentId, at.mediaMs, BoundaryDecision.join.rawValue, atMs,
                    from.segmentId, from.mediaMs, to?.segmentId, to?.mediaMs,
                ])
            return at
        }
    }

    /// Writes newly settled cuts. Existing rows are left exactly as they are: a settled cut is
    /// never re-dated or re-explained.
    static func commit(
        _ cuts: [ConversationCut: ConversationStartReason], atMs: Int64, in db: Database
    ) throws {
        for (cut, reason) in cuts {
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
                        decision = excluded.decision, createdAtMs = excluded.createdAtMs,
                        spanFromSegmentId = NULL, spanFromMediaMs = NULL,
                        spanToSegmentId = NULL, spanToMediaMs = NULL
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
    /// is silence, and the planner gives silence to a neighbour or makes a quiet unit of it.
    /// Left in the table, the deleted conversation would hand its ID to whichever of those now
    /// starts inside its old range — an id whose title, notes and tags the cascade has just
    /// destroyed. So its place goes: a stored piece lying inside a deleted range is removed,
    /// one that runs into a range is cut back to where the range starts, one that starts
    /// inside a range and runs on is cut back to where it ends, and a stored conversation left
    /// with no piece is removed.
    ///
    /// Written against the ranges rather than against the deleted conversation's own rows,
    /// because the pipeline's rebuild can run while a delete is in progress and rewrite them.
    ///
    /// This deliberately does NOT give the deleted range to the conversation that follows it.
    /// That would be right when the planner lets that conversation begin earlier, and wrong
    /// when it makes the silence a unit of its own: the silent unit starts first, would adopt
    /// the follower's id, and the follower would come out renamed. Which of the two happens is
    /// the planner's decision, so the cascade looks at the rebuild and then calls
    /// `renameStoredConversation` if the follower needs its id back.
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
                    } else if start >= lower, start < upper {
                        try db.execute(
                            sql: """
                                UPDATE conversation_segments SET startMediaMs = ?
                                WHERE conversationId = ? AND ordinal = ?
                                """,
                            arguments: [upper] + key)
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

    /// Delete-cascade support: gives a stored conversation another id — the one it had before
    /// a delete beside it moved where it starts.
    ///
    /// A conversation's id is the position it starts at, held stable across rebuilds by
    /// adoption from the stored grouping. When the conversation BEFORE it in a shared segment
    /// is deleted and the planner lets this one begin earlier (over the silence), its start
    /// is somewhere no stored piece of its own covers, so the rebuild issues it a new id — and
    /// its title, notes, tags and follow-ups are all keyed by the old one. Renaming the stored
    /// row puts the old id back; every later rebuild then adopts it like any other.
    ///
    /// Returns false, and changes nothing, when `from` is not stored or `to` already is.
    @discardableResult
    public func renameStoredConversation(from: String, to: String) async throws -> Bool {
        guard from != to else { return false }
        return try await db.writer.write { db in
            let exists = { (id: String) in
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM conversations WHERE id = ?)",
                    arguments: [id]) ?? false
            }
            guard try exists(from), try !exists(to) else { return false }
            // The member rows reference the conversation row; both move inside this one
            // transaction, and the check waits for its end.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(
                sql: "UPDATE conversations SET id = ? WHERE id = ?", arguments: [to, from])
            try db.execute(
                sql: "UPDATE conversation_segments SET conversationId = ? WHERE conversationId = ?",
                arguments: [to, from])
            return true
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
