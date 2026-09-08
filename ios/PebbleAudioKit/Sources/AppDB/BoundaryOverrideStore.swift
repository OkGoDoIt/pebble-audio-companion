import Foundation
import GRDB

// The user's own boundary decisions, and the cache of the optional semantic layer's verdicts.
// Two tables with opposite lifetimes on purpose (migration `v10-conversation-boundaries`):
// overrides are AUTHORITATIVE and never dropped; reviews are DERIVED and cost one AI call to
// rebuild.

public struct BoundaryOverride: Equatable, Sendable {
    /// The segment that FOLLOWS the join this decision is about.
    public var segmentId: String
    public var decision: BoundaryDecision
    public var createdAtMs: Int64

    public init(segmentId: String, decision: BoundaryDecision, createdAtMs: Int64) {
        self.segmentId = segmentId
        self.decision = decision
        self.createdAtMs = createdAtMs
    }
}

/// The user's standing answers to "is this one conversation or two?".
///
/// Deliberately tiny. The alternative designs — a smarter automatic rule for stop-then-resume,
/// or a per-conversation "aggressiveness" setting — both ask the person to reason about the
/// algorithm. One reversible tap on the boundary in front of them does not.
public struct BoundaryOverrideStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func row(_ row: Row) -> BoundaryOverride? {
        guard let decision = BoundaryDecision(rawValue: row["decision"]) else { return nil }
        return BoundaryOverride(
            segmentId: row["segmentId"], decision: decision, createdAtMs: row["createdAtMs"])
    }

    public static func fetchAll(_ db: Database) throws -> [String: BoundaryDecision] {
        var out: [String: BoundaryDecision] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM boundary_overrides") {
            if let override = Self.row(row) { out[override.segmentId] = override.decision }
        }
        return out
    }

    public func all() async throws -> [String: BoundaryDecision] {
        try await db.reader.read { try Self.fetchAll($0) }
    }

    public func decision(forSegment segmentId: String) async throws -> BoundaryDecision? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM boundary_overrides WHERE segmentId = ?",
                arguments: [segmentId]
            ).flatMap(Self.row)?.decision
        }
    }

    /// Records a decision (upsert). `nil` clears it and hands the join back to the rules —
    /// which is what makes every manual split and merge undoable.
    public func set(
        segmentId: String, decision: BoundaryDecision?,
        atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            guard let decision else {
                try db.execute(
                    sql: "DELETE FROM boundary_overrides WHERE segmentId = ?",
                    arguments: [segmentId])
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO boundary_overrides (segmentId, decision, createdAtMs)
                    VALUES (?, ?, ?)
                    ON CONFLICT(segmentId) DO UPDATE SET
                        decision = excluded.decision, createdAtMs = excluded.createdAtMs
                    """,
                arguments: [segmentId, decision.rawValue, atMs]
            )
        }
    }

    /// Delete-cascade support: a segment that no longer exists keeps no decision.
    public func forget(segmentIds: [String]) async throws {
        guard !segmentIds.isEmpty else { return }
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM boundary_overrides
                    WHERE segmentId IN (\(databaseQuestionMarks(count: segmentIds.count)))
                    """,
                arguments: StatementArguments(segmentIds)
            )
        }
    }
}

/// One cached verdict from the semantic layer.
public struct BoundaryReview: Equatable, Sendable {
    public var segmentId: String
    /// True when the reviewer judged the candidate to be a real change of subject or people.
    public var isBoundary: Bool
    /// The quiet the verdict was given for. A later rebuild that measures a materially
    /// different quiet at the same join re-asks rather than trusting a stale answer.
    public var quietMs: Int64
    public var reason: String?
    public var provider: String?
    public var model: String?
    public var createdAtMs: Int64

    public init(
        segmentId: String, isBoundary: Bool, quietMs: Int64, reason: String? = nil,
        provider: String? = nil, model: String? = nil, createdAtMs: Int64
    ) {
        self.segmentId = segmentId
        self.isBoundary = isBoundary
        self.quietMs = quietMs
        self.reason = reason
        self.provider = provider
        self.model = model
        self.createdAtMs = createdAtMs
    }
}

public struct BoundaryReviewStore: Sendable {
    /// A verdict stands while the measured quiet is within this much of what was reviewed.
    /// Transcripts do shift by a few seconds when a segment is re-transcribed; re-asking for
    /// that would spend a call to get the same answer.
    public static let quietDriftToleranceMs: Int64 = 60_000

    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func review(_ row: Row) -> BoundaryReview {
        BoundaryReview(
            segmentId: row["segmentId"],
            isBoundary: row["isBoundary"],
            quietMs: row["quietMs"],
            reason: row["reason"],
            provider: row["provider"],
            model: row["model"],
            createdAtMs: row["createdAtMs"]
        )
    }

    public static func fetchAll(_ db: Database) throws -> [String: BoundaryReview] {
        var out: [String: BoundaryReview] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM boundary_reviews") {
            let review = Self.review(row)
            out[review.segmentId] = review
        }
        return out
    }

    public func all() async throws -> [String: BoundaryReview] {
        try await db.reader.read { try Self.fetchAll($0) }
    }

    /// Segment ids the reviewer has ruled DO start a new conversation, for the quiet actually
    /// measured now. A verdict given for a materially different quiet is ignored (and the
    /// candidate is re-offered) rather than silently reused.
    public func splits(matching candidates: [BoundaryCandidate]) async throws -> Set<String> {
        let reviews = try await all()
        var out: Set<String> = []
        for candidate in candidates {
            guard let review = reviews[candidate.newStartSegmentId], review.isBoundary else {
                continue
            }
            if abs(review.quietMs - candidate.quietMs) <= Self.quietDriftToleranceMs {
                out.insert(candidate.newStartSegmentId)
            }
        }
        return out
    }

    /// Candidates with no usable verdict yet — what the worker should actually spend a call on.
    public func unreviewed(_ candidates: [BoundaryCandidate]) async throws -> [BoundaryCandidate] {
        let reviews = try await all()
        return candidates.filter { candidate in
            guard let review = reviews[candidate.newStartSegmentId] else { return true }
            return abs(review.quietMs - candidate.quietMs) > Self.quietDriftToleranceMs
        }
    }

    public func save(_ reviews: [BoundaryReview]) async throws {
        guard !reviews.isEmpty else { return }
        try await db.writer.write { db in
            for review in reviews {
                try db.execute(
                    sql: """
                        INSERT INTO boundary_reviews
                            (segmentId, isBoundary, quietMs, reason, provider, model, createdAtMs)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(segmentId) DO UPDATE SET
                            isBoundary = excluded.isBoundary, quietMs = excluded.quietMs,
                            reason = excluded.reason, provider = excluded.provider,
                            model = excluded.model, createdAtMs = excluded.createdAtMs
                        """,
                    arguments: [
                        review.segmentId, review.isBoundary, review.quietMs, review.reason,
                        review.provider, review.model, review.createdAtMs,
                    ]
                )
            }
        }
    }
}
