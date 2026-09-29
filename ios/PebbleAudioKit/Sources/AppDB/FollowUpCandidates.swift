import Foundation
import GRDB

// The staging table between the two follow-up passes.
//
// Extraction reads ONE conversation and can only ever answer "what did this conversation
// propose". Everything that makes the list good — the same intent said twice on two days, a
// plan that was replaced a week later, which three of eleven proposals actually matter — is
// invisible from inside a single conversation. So extraction writes candidates here, and a
// curation pass reads across all of them at once and decides.
//
// DERIVED state: dropping this table costs a re-extraction and nothing the person has seen.

/// How sure the extractor was that this is a real, durable commitment.
public enum FollowUpConfidence: String, Equatable, Sendable, Codable, CaseIterable {
    case high
    case medium
    case low

    /// Sort key: high first. Used to spend the curation budget on the best proposals when a
    /// backlog is larger than one call can hold.
    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// What curation decided about a candidate. `pending` is "not looked at yet".
public enum FollowUpCandidateState: String, Equatable, Sendable, Codable {
    case pending
    case kept
    case dropped
    case merged
}

/// One thing a conversation proposed, before anything has decided whether it deserves to be
/// on a person's list.
public struct FollowUpCandidate: Equatable, Sendable, Identifiable {
    public var id: String
    public var conversationId: String
    public var segmentId: String?
    public var task: String
    /// Verbatim words from the transcript. A candidate without one is not grounded and the
    /// curator is told to treat it as suspect.
    public var quote: String?
    /// What the extractor said goes wrong if this never happens. A candidate that cannot
    /// name a cost is one curation should drop.
    public var why: String?
    public var confidence: FollowUpConfidence
    public var dueAtMs: Int64?
    /// Offsets inside `segmentId` where the quote was spoken.
    public var startMs: Int64?
    public var endMs: Int64?
    public var createdAtMs: Int64
    /// When the CONVERSATION happened. Not the same as `createdAtMs`, which is when extraction
    /// got round to reading it — days later for a backlog. Curation resolves "tomorrow" against
    /// this, and was previously told a Friday commitment had been recorded on Monday.
    public var recordedAtMs: Int64?
    public var state: FollowUpCandidateState
    /// Curation attempts that ended without a decision for this candidate. Without a budget a
    /// batch the provider could not answer stayed pending forever, and `pending(limit:)` is
    /// deterministic, so the identical twelve were re-sent on every pass.
    public var attempts: Int
    public var decidedAtMs: Int64?
    /// Why curation decided what it decided — the one thing that makes a dropped candidate
    /// auditable instead of a silent disappearance.
    public var reason: String?
    /// The model that proposed it (`RoutedAiResult.modelUsed`), carried onto the follow-up
    /// curation keeps, so its provenance can say which model found it.
    public var model: String?

    public init(
        id: String,
        conversationId: String,
        segmentId: String? = nil,
        task: String,
        quote: String? = nil,
        why: String? = nil,
        confidence: FollowUpConfidence = .medium,
        dueAtMs: Int64? = nil,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        createdAtMs: Int64,
        recordedAtMs: Int64? = nil,
        state: FollowUpCandidateState = .pending,
        attempts: Int = 0,
        decidedAtMs: Int64? = nil,
        reason: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.segmentId = segmentId
        self.task = task
        self.quote = quote
        self.why = why
        self.confidence = confidence
        self.dueAtMs = dueAtMs
        self.startMs = startMs
        self.endMs = endMs
        self.createdAtMs = createdAtMs
        self.recordedAtMs = recordedAtMs
        self.state = state
        self.attempts = attempts
        self.decidedAtMs = decidedAtMs
        self.reason = reason
        self.model = model
    }
}

public struct FollowUpCandidateStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func candidate(from row: Row) -> FollowUpCandidate {
        FollowUpCandidate(
            id: row["id"],
            conversationId: row["conversationId"],
            segmentId: row["segmentId"],
            task: row["task"],
            quote: row["quote"],
            why: row["why"],
            confidence: FollowUpConfidence(rawValue: row["confidence"] ?? "medium") ?? .medium,
            dueAtMs: row["dueAtMs"],
            startMs: row["startMs"],
            endMs: row["endMs"],
            createdAtMs: row["createdAtMs"],
            recordedAtMs: row["recordedAtMs"],
            state: FollowUpCandidateState(rawValue: row["state"] ?? "pending") ?? .pending,
            attempts: row["attempts"] ?? 0,
            decidedAtMs: row["decidedAtMs"],
            reason: row["reason"],
            model: row["model"])
    }

    /// Upsert by id. Ids are content-addressed by the extractor, so re-reading a conversation
    /// lands on the same rows — and a candidate curation already DECIDED keeps its decision
    /// rather than quietly returning to the queue and being judged again forever.
    public func save(_ candidate: FollowUpCandidate) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO follow_up_candidates
                        (id, conversationId, segmentId, task, quote, why, confidence,
                         dueAtMs, startMs, endMs, createdAtMs, recordedAtMs, state, attempts,
                         decidedAtMs, reason, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        task = excluded.task, quote = excluded.quote, why = excluded.why,
                        confidence = excluded.confidence, dueAtMs = excluded.dueAtMs,
                        segmentId = excluded.segmentId, recordedAtMs = excluded.recordedAtMs,
                        startMs = excluded.startMs, endMs = excluded.endMs,
                        model = COALESCE(excluded.model, follow_up_candidates.model)
                    """,
                arguments: [
                    candidate.id, candidate.conversationId, candidate.segmentId, candidate.task,
                    candidate.quote, candidate.why, candidate.confidence.rawValue,
                    candidate.dueAtMs, candidate.startMs, candidate.endMs, candidate.createdAtMs,
                    candidate.recordedAtMs, candidate.state.rawValue, candidate.attempts,
                    candidate.decidedAtMs, candidate.reason, candidate.model,
                ])
        }
    }

    /// The curation queue: undecided candidates, best-grounded and newest first, bounded, and
    /// skipping any that curation has already failed on `maxAttempts` times — until
    /// `retryAfterMs` has passed since the last of them, when a spent candidate is tried again
    /// rather than left `pending` forever. `retryAfterMs` nil keeps a spent budget spent.
    public func pending(
        limit: Int, maxAttempts: Int = Int.max, retryAfterMs: Int64? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> [FollowUpCandidate] {
        // A candidate spent before the attempt time was recorded (NULL) is due at once, once.
        let restedBefore = retryAfterMs.map { nowMs - $0 } ?? Int64.min
        return try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_up_candidates
                    WHERE state = 'pending'
                        AND (attempts < ?
                            OR (? AND (lastAttemptAtMs IS NULL OR lastAttemptAtMs <= ?)))
                    ORDER BY
                        CASE confidence WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
                        createdAtMs DESC, id
                    LIMIT ?
                    """,
                arguments: [maxAttempts, retryAfterMs != nil, restedBefore, limit]
            ).map(Self.candidate(from:))
        }
    }

    public func pendingCount() async throws -> Int {
        try await db.reader.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM follow_up_candidates WHERE state = 'pending'") ?? 0
        }
    }

    /// Records that a curation call was made for these candidates and did not decide them.
    public func recordAttempt(
        ids: [String], nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        guard !ids.isEmpty else { return }
        try await db.writer.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: """
                    UPDATE follow_up_candidates
                    SET attempts = attempts + 1, lastAttemptAtMs = ?
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments([nowMs] as [any DatabaseValueConvertible])
                    + StatementArguments(ids))
        }
    }

    /// Every undecided candidate's curation budget starts over — the AI configuration changed,
    /// so a batch the old one could not decide may now be decided.
    public func resetAttempts() async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_up_candidates SET attempts = 0, lastAttemptAtMs = NULL
                    WHERE state = 'pending' AND (attempts > 0 OR lastAttemptAtMs IS NOT NULL)
                    """)
        }
    }

    public func decide(
        id: String, state: FollowUpCandidateState, reason: String?, nowMs: Int64
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_up_candidates
                    SET state = ?, reason = ?, decidedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [state.rawValue, reason, nowMs, id])
        }
    }

    public func list(conversationId: String) async throws -> [FollowUpCandidate] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_up_candidates WHERE conversationId = ?
                    ORDER BY createdAtMs DESC, id
                    """,
                arguments: [conversationId]
            ).map(Self.candidate(from:))
        }
    }

    /// Delete-cascade support: a segment that no longer exists proposes nothing.
    public func deleteForSegment(segmentId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM follow_up_candidates WHERE segmentId = ?",
                arguments: [segmentId])
        }
    }

    public func deleteForConversation(conversationId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM follow_up_candidates WHERE conversationId = ?",
                arguments: [conversationId])
        }
    }
}
