import Foundation
import GRDB
import SegmentStore

// Follow-ups on the wall clock: the one-time fill for rows written before extraction stored
// when a quote was said (`v15-follow-up-wall-times`).

/// Fills `sourceWall` on rows that have a located quote (a segment and a media offset) but no
/// wall time yet, from the segment's own clock — the same `SegmentMediaClock.wallRange` the
/// extractor now uses when it writes a row, so a filled row and a new one cannot disagree.
///
/// Two tables. Follow-ups, because that is what History places. Pending candidates, because
/// curation carries a candidate's wall time onto the follow-up it keeps: a candidate proposed
/// before the upgrade and curated after it would otherwise become a follow-up with none.
/// Decided candidates are not touched — nothing reads their time again.
///
/// Cost is the rows that need it, not the tables: follow-ups are found through the partial
/// index `follow_ups_wall_unfilled` (only rows with a located quote and no wall time are in
/// it), pending candidates through `follow_up_candidates_state`. With nothing to fill it is two
/// indexed reads and no write. Idempotent: a filled row leaves the set, and every UPDATE is
/// guarded on the row still being unfilled at the location that was read, so a concurrent
/// extraction or curation that wrote its own value — or moved the quote — is never overwritten.
///
/// A row whose segment is gone is left as it is (placement then falls back to the day in the
/// segment id — see `FollowUpPlacement`) and is counted in `Outcome.segmentGone`.
public struct FollowUpWallTimeFill: Sendable {
    public struct Outcome: Equatable, Sendable {
        public var followUps: Int
        public var candidates: Int
        /// Rows that need a wall time but whose segment could not be read.
        public var segmentGone: Int

        public init(followUps: Int = 0, candidates: Int = 0, segmentGone: Int = 0) {
            self.followUps = followUps
            self.candidates = candidates
            self.segmentGone = segmentGone
        }

        public var filled: Int { followUps + candidates }
    }

    private enum Table: Sendable {
        case followUps
        case candidates

        var name: String { self == .followUps ? "follow_ups" : "follow_up_candidates" }
        /// The quote's location, which the two tables name differently.
        var segmentColumn: String { self == .followUps ? "sourceSegmentId" : "segmentId" }
        var startColumn: String { self == .followUps ? "sourceStartMs" : "startMs" }
        var endColumn: String { self == .followUps ? "sourceEndMs" : "endMs" }
    }

    /// One row that needs a wall time: where its quote is, and which table it is in.
    private struct Pending: Sendable {
        let table: Table
        let id: String
        let segmentId: String
        let startMs: Int64
        let endMs: Int64?
    }

    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// - Parameter metaOf: the segment's sidecar, or nil when the segment is gone. Called once per
    ///   distinct segment, outside any database transaction.
    @discardableResult
    public func run(metaOf: (String) async -> SegmentMeta?) async throws -> Outcome {
        let pending = try await db.reader.read { db in
            try Self.followUpsNeedingIt(db) + Self.candidatesNeedingIt(db)
        }
        guard !pending.isEmpty else { return Outcome() }

        var clocks: [String: SegmentMediaClock] = [:]
        var gone = Set<String>()
        var updates: [(Pending, SegmentWallRange)] = []
        var outcome = Outcome()
        for row in pending {
            if clocks[row.segmentId] == nil, !gone.contains(row.segmentId) {
                if let meta = await metaOf(row.segmentId) {
                    clocks[row.segmentId] = SegmentMediaClock(meta)
                } else {
                    gone.insert(row.segmentId)
                }
            }
            guard let clock = clocks[row.segmentId] else {
                outcome.segmentGone += 1
                continue
            }
            updates.append(
                (row, clock.wallRange(ofMediaStartMs: row.startMs, endMs: row.endMs ?? row.startMs)))
        }
        guard !updates.isEmpty else { return outcome }

        let computed = updates
        let written = try await db.writer.write { db in
            var followUps = 0
            var candidates = 0
            for (row, wall) in computed {
                let table = row.table
                try db.execute(
                    sql: """
                        UPDATE \(table.name)
                        SET sourceWallStartMs = ?, sourceWallEndMs = ?, sourceWallApproximate = ?
                        WHERE id = ? AND sourceWallStartMs IS NULL AND \(table.segmentColumn) = ?
                            AND \(table.startColumn) = ? AND \(table.endColumn) IS ?
                        """,
                    arguments: [
                        wall.startMs, wall.endMs, wall.isApproximate,
                        row.id, row.segmentId, row.startMs, row.endMs,
                    ])
                if table == .followUps {
                    followUps += db.changesCount
                } else {
                    candidates += db.changesCount
                }
            }
            return (followUps, candidates)
        }
        outcome.followUps = written.0
        outcome.candidates = written.1
        return outcome
    }

    /// Served by the partial index `follow_ups_wall_unfilled`, whose WHERE clause these terms
    /// repeat exactly (SQLite only uses a partial index when the query implies its condition).
    static let followUpsNeedingItSQL = """
        SELECT id, sourceSegmentId, sourceStartMs, sourceEndMs FROM follow_ups
        WHERE sourceWallStartMs IS NULL AND sourceStartMs IS NOT NULL
            AND sourceSegmentId IS NOT NULL
        """

    private static func followUpsNeedingIt(_ db: Database) throws -> [Pending] {
        try Row.fetchAll(db, sql: followUpsNeedingItSQL).map {
            Pending(
                table: .followUps, id: $0["id"], segmentId: $0["sourceSegmentId"],
                startMs: $0["sourceStartMs"], endMs: $0["sourceEndMs"])
        }
    }

    private static func candidatesNeedingIt(_ db: Database) throws -> [Pending] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, segmentId, startMs, endMs FROM follow_up_candidates
                WHERE state = 'pending' AND sourceWallStartMs IS NULL
                    AND startMs IS NOT NULL AND segmentId IS NOT NULL
                """
        ).map {
            Pending(
                table: .candidates, id: $0["id"], segmentId: $0["segmentId"],
                startMs: $0["startMs"], endMs: $0["endMs"])
        }
    }
}
