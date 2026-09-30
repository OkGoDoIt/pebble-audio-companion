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

// MARK: - Placement

/// Where a follow-up sits on History's clock (plan 7.5), strongest evidence first. A follow-up
/// belongs to the chapter containing the moment it was said; when that moment is unknown it
/// belongs to the day only, and is never attached to a chapter by guess.
public enum FollowUpPlacement: Equatable, Sendable {
    /// When the quote was said (wall ms). Approximate when the segment's clock was not exact.
    case moment(Int64, isApproximate: Bool)
    /// The source segment's wall span: the recording is known, the moment inside it is not.
    case span(Range<Int64>)
    /// Only the day is known: the segment is gone (its receive time, from the id) or the item
    /// was written by hand (when it was written).
    case dayOnly(approximateMs: Int64)

    /// Whether the time shown for it can only be approximate — anything short of an exact moment.
    public var isApproximate: Bool {
        switch self {
        case .moment(_, let isApproximate): return isApproximate
        case .span, .dayOnly: return true
        }
    }
}

/// What placement reads from a row.
public protocol FollowUpPlacementSource {
    var origin: FollowUpOrigin { get }
    var sourceSegmentId: String? { get }
    var sourceWall: SegmentWallRange? { get }
    var createdAtMs: Int64 { get }
}

extension FollowUp: FollowUpPlacementSource {}

extension FollowUpPlacement {
    /// In order: a stored wall time → `.moment`; else the segment still exists → `.span`; else
    /// its id carries a receive time → `.dayOnly` at that; else, for an item written by hand
    /// with no segment at all → `.dayOnly` at its creation.
    ///
    /// Nil when none of that holds — an extracted row whose segment is gone and whose id is not
    /// the store's shape, or a hand-written one attached to such a segment. `createdAtMs` is
    /// never used for an extracted row: it is when extraction ran, days later for a backlog, and
    /// placing by it would put the item on a day nothing was said. For a hand-written row
    /// attached to a recording, the recording is what it is about, so its creation is not used
    /// either once the recording cannot be found.
    ///
    /// - Parameter segmentSpan: the segment's wall span, or nil when it no longer exists.
    public static func placement(
        of followUp: some FollowUpPlacementSource,
        segmentSpan: (String) -> Range<Int64>?
    ) -> FollowUpPlacement? {
        if let wall = followUp.sourceWall {
            return .moment(wall.startMs, isApproximate: wall.isApproximate)
        }
        guard let segmentId = followUp.sourceSegmentId else {
            return followUp.origin == .user ? .dayOnly(approximateMs: followUp.createdAtMs) : nil
        }
        if let span = segmentSpan(segmentId) { return .span(span) }
        return receivedAtMs(ofSegmentId: segmentId).map { .dayOnly(approximateMs: $0) }
    }

    /// The receive time a segment id embeds: `seg-<receivedAtMs>-<streamId>-<counter>`
    /// (`SegmentStore.openSegmentInternal`, and the KMP store before it). When the phone
    /// received the first frame, so it is at or after the recording's start — a day, not a
    /// moment.
    ///
    /// Strict on purpose: exactly thirteen digits (every epoch-ms time from 2001-09-09 to
    /// 2286-11-20) followed by `-`. A test id like `seg-1` or anything else that merely starts
    /// with `seg-` is not a time, and reading it as one would put an item in 1970.
    public static func receivedAtMs(ofSegmentId segmentId: String) -> Int64? {
        let prefix = "seg-"
        guard segmentId.hasPrefix(prefix) else { return nil }
        let rest = segmentId.utf8.dropFirst(prefix.utf8.count)
        let digits = rest.prefix(13)
        let isDigit = { (byte: UInt8) in byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        guard digits.count == 13, digits.allSatisfy(isDigit),
            rest.dropFirst(13).first == UInt8(ascii: "-")
        else { return nil }
        return Int64(String(decoding: digits, as: UTF8.self))
    }
}
