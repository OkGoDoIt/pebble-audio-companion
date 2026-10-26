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
///
/// It also re-places, once, the rows listed in `follow_up_wall_replace`: every wall time stored
/// before recordings were placed by their arrival (`SegmentMeta.sampleClockAnchorMs`), which
/// could be 15 minutes early. Each is recomputed from its segment's clock and taken off the
/// list; one whose segment is gone keeps the time it has.
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
        /// On the `follow_up_wall_replace` list: it has a wall time, from the old placement.
        var replacing = false
    }

    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// - Parameter metaOf: the segment's sidecar, or nil when the segment is gone. Called once per
    ///   distinct segment, outside any database transaction.
    @discardableResult
    public func run(metaOf: (String) async -> SegmentMeta?) async throws -> Outcome {
        let pending = try await db.reader.read { db in
            try Self.followUpsNeedingIt(db) + Self.candidatesNeedingIt(db) + Self.replacing(db)
        }
        guard !pending.isEmpty else { return Outcome() }

        var clocks: [String: SegmentMediaClock] = [:]
        var gone = Set<String>()
        var updates: [(Pending, SegmentWallRange)] = []
        var replaceDone: [Pending] = []
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
                if row.replacing {
                    replaceDone.append(row)
                } else {
                    outcome.segmentGone += 1
                }
                continue
            }
            let wall = clock.wallRange(ofMediaStartMs: row.startMs, endMs: row.endMs ?? row.startMs)
            updates.append((row, wall))
        }
        guard !updates.isEmpty || !replaceDone.isEmpty else { return outcome }

        let computed = updates
        let unplaced = replaceDone
        let written = try await db.writer.write { db in
            var followUps = 0
            var candidates = 0
            for row in unplaced {
                try Self.takeOffReplaceList(row, db)
            }
            if !unplaced.isEmpty || computed.contains(where: \.0.replacing) {
                // Listed rows that are gone or lost their quote have nothing to re-place.
                try db.execute(
                    sql: """
                        DELETE FROM follow_up_wall_replace WHERE
                            (tableName = 'follow_ups' AND id NOT IN (SELECT id FROM follow_ups
                                WHERE sourceStartMs IS NOT NULL AND sourceSegmentId IS NOT NULL))
                            OR (tableName = 'follow_up_candidates' AND id NOT IN (
                                SELECT id FROM follow_up_candidates
                                WHERE startMs IS NOT NULL AND segmentId IS NOT NULL))
                        """)
            }
            for (row, wall) in computed {
                let table = row.table
                try db.execute(
                    sql: """
                        UPDATE \(table.name)
                        SET sourceWallStartMs = ?, sourceWallEndMs = ?, sourceWallApproximate = ?
                        WHERE id = ? \(row.replacing ? "" : "AND sourceWallStartMs IS NULL")
                            AND \(table.segmentColumn) = ?
                            AND \(table.startColumn) = ? AND \(table.endColumn) IS ?
                        """,
                    arguments: [
                        wall.startMs, wall.endMs, wall.isApproximate,
                        row.id, row.segmentId, row.startMs, row.endMs,
                    ])
                if row.replacing {
                    try Self.takeOffReplaceList(row, db)
                    continue
                }
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

    /// The rows `follow-ups-wall-replace-v1` listed, where their quotes are now. One deleted or
    /// unlocated since is taken off the list by the write that re-places the others.
    private static func replacing(_ db: Database) throws -> [Pending] {
        guard try db.tableExists("follow_up_wall_replace") else { return [] }
        let followUps = try Row.fetchAll(
            db,
            sql: """
                SELECT f.id, f.sourceSegmentId, f.sourceStartMs, f.sourceEndMs
                FROM follow_up_wall_replace r JOIN follow_ups f ON f.id = r.id
                WHERE r.tableName = 'follow_ups'
                    AND f.sourceStartMs IS NOT NULL AND f.sourceSegmentId IS NOT NULL
                """
        ).map {
            Pending(
                table: .followUps, id: $0["id"], segmentId: $0["sourceSegmentId"],
                startMs: $0["sourceStartMs"], endMs: $0["sourceEndMs"], replacing: true)
        }
        let candidates = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id, c.segmentId, c.startMs, c.endMs
                FROM follow_up_wall_replace r JOIN follow_up_candidates c ON c.id = r.id
                WHERE r.tableName = 'follow_up_candidates'
                    AND c.startMs IS NOT NULL AND c.segmentId IS NOT NULL
                """
        ).map {
            Pending(
                table: .candidates, id: $0["id"], segmentId: $0["segmentId"],
                startMs: $0["startMs"], endMs: $0["endMs"], replacing: true)
        }
        return followUps + candidates
    }

    private static func takeOffReplaceList(_ row: Pending, _ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM follow_up_wall_replace WHERE tableName = ? AND id = ?",
            arguments: [row.table.name, row.id])
    }

    /// Lists every follow-up and pending candidate that already has a wall time for one
    /// re-placement (`follow-ups-wall-replace-v1`).
    static func listForReplacement(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS follow_up_wall_replace (
                    tableName TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (tableName, id))
                """)
        if try db.tableExists("follow_ups") {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO follow_up_wall_replace SELECT 'follow_ups', id FROM follow_ups
                    WHERE sourceWallStartMs IS NOT NULL AND sourceStartMs IS NOT NULL
                        AND sourceSegmentId IS NOT NULL
                    """)
        }
        if try db.tableExists("follow_up_candidates") {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO follow_up_wall_replace
                    SELECT 'follow_up_candidates', id FROM follow_up_candidates
                    WHERE state = 'pending' AND sourceWallStartMs IS NOT NULL
                        AND startMs IS NOT NULL AND segmentId IS NOT NULL
                    """)
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

/// What placement reads from a row. `FollowUp` and `HistoryFollowUpRecord` both carry it.
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

// MARK: - History's read

/// One follow-up as History reads it for a window: what its line shows, and what placement
/// needs (`FollowUpPlacement.placement(of:segmentSpan:)`).
public struct HistoryFollowUpRecord: Equatable, Sendable, Identifiable, FollowUpPlacementSource {
    public let id: String
    public var text: String
    public var done: Bool
    public var snoozedUntilMs: Int64?
    public var origin: FollowUpOrigin
    public var sourceSegmentId: String?
    public var sourceWall: SegmentWallRange?
    public var createdAtMs: Int64

    public init(
        id: String, text: String, done: Bool, snoozedUntilMs: Int64? = nil,
        origin: FollowUpOrigin = .ai, sourceSegmentId: String? = nil,
        sourceWall: SegmentWallRange? = nil, createdAtMs: Int64
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.snoozedUntilMs = snoozedUntilMs
        self.origin = origin
        self.sourceSegmentId = sourceSegmentId
        self.sourceWall = sourceWall
        self.createdAtMs = createdAtMs
    }

    /// Put off past `nowMs`. History counts a snoozed item as open (plan 7.5).
    public func isSnoozed(at nowMs: Int64) -> Bool {
        guard let snoozedUntilMs else { return false }
        return snoozedUntilMs > nowMs
    }

    /// The line History draws for it, once it has been placed.
    public func line(placement: FollowUpPlacement, nowMs: Int64) -> HistoryFollowUpLine {
        HistoryFollowUpLine(
            id: id, text: text, done: done, isSnoozed: isSnoozed(at: nowMs),
            isApproximate: placement.isApproximate)
    }
}

extension FollowUpStore {
    /// The follow-ups that may belong to a wall-clock window, for History: open, done and
    /// snoozed alike; never archived (plan 7.5 — 481 of 511 rows in the backup are archived
    /// legacy rows with no quote). Four ways in, one indexed read each:
    ///
    /// 1. a wall time inside the window (`follow_ups_wall`);
    /// 2. no wall time, and the source segment is one of `segmentIds` — the window's recordings,
    ///    which the caller knows and SQL does not (`follow_ups_segment`, the ids bound as one
    ///    JSON array through `json_each`, so any number of them is one parameter);
    /// 3. no wall time, and the receive time in the segment id is inside the window
    ///    (`follow_ups_segment`, as a string range: thirteen-digit times sort as numbers). This
    ///    is how a row whose segment is gone is found at all — rule 3 of the placement, the day
    ///    its id carries — and it is the same id rule as `FollowUpPlacement.receivedAtMs`;
    /// 4. written by hand with no segment, and created inside the window (`follow_ups_open`,
    ///    through `done IN (0, 1)`, which lets its leading column be probed rather than
    ///    scanned).
    ///
    /// A SUPERSET of what the window shows: the caller places every record and keeps those its
    /// placement puts in the window. (A segment in `segmentIds` can straddle the window's edge,
    /// and one found by its id's receive time can still exist and span an earlier stretch —
    /// spooled audio arrives after it was recorded.) Ordered open first, then by wall time,
    /// then id; the final order by placed time is the builder's, which knows the spans.
    public func history(
        inWallWindow window: Range<Int64>, segmentIds: [String]
    ) async throws -> [HistoryFollowUpRecord] {
        let ids = String(decoding: try JSONEncoder().encode(segmentIds), as: UTF8.self)
        let idRange = Self.segmentIdRange(receivedIn: window)
        let records = try await db.reader.read { db in
            try Row.fetchAll(
                db, sql: Self.historySQL,
                arguments: [
                    "start": window.lowerBound, "end": window.upperBound, "ids": ids,
                    "idFrom": idRange.lowerBound, "idTo": idRange.upperBound,
                ]
            ).map(Self.historyRecord(from:))
        }
        return records.sorted {
            ($0.done ? 1 : 0, $0.sourceWall?.startMs ?? .max, $0.id)
                < ($1.done ? 1 : 0, $1.sourceWall?.startMs ?? .max, $1.id)
        }
    }

    static let historySQL: String = {
        let columns = """
            id, text, done, snoozedUntilMs, origin, sourceSegmentId, createdAtMs,
            sourceWallStartMs, sourceWallEndMs, sourceWallApproximate
            """
        // `seg-` and exactly thirteen digits, then `-`: `FollowUpPlacement.receivedAtMs`'s rule.
        let idShape = "seg-" + String(repeating: "[0-9]", count: 13) + "-*"
        return """
            SELECT \(columns) FROM follow_ups
            WHERE archivedAtMs IS NULL
                AND sourceWallStartMs >= :start AND sourceWallStartMs < :end
            UNION
            SELECT \(columns) FROM follow_ups
            WHERE archivedAtMs IS NULL AND sourceWallStartMs IS NULL
                AND sourceSegmentId IN (SELECT value FROM json_each(:ids))
            UNION
            SELECT \(columns) FROM follow_ups
            WHERE archivedAtMs IS NULL AND sourceWallStartMs IS NULL
                AND sourceSegmentId >= :idFrom AND sourceSegmentId < :idTo
                AND sourceSegmentId GLOB '\(idShape)'
            UNION
            SELECT \(columns) FROM follow_ups
            WHERE done IN (0, 1) AND archivedAtMs IS NULL
                AND createdAtMs >= :start AND createdAtMs < :end
                AND origin = 'user' AND sourceSegmentId IS NULL
            """
    }()

    /// The segment ids whose embedded receive time is in `window`, as a string range over
    /// `seg-<13 digits>-…`. Clamped to what thirteen digits can hold; `seg-:` sorts after every
    /// `seg-<digit>` and stands for the end of that domain.
    static func segmentIdRange(receivedIn window: Range<Int64>) -> Range<String> {
        let domainEnd: Int64 = 10_000_000_000_000
        func key(_ ms: Int64) -> String {
            let clamped = min(max(ms, 0), domainEnd)
            guard clamped < domainEnd else { return "seg-:" }
            let digits = String(clamped)
            return "seg-" + String(repeating: "0", count: 13 - digits.count) + digits
        }
        return key(window.lowerBound)..<key(window.upperBound)
    }

    private static func historyRecord(from row: Row) -> HistoryFollowUpRecord {
        HistoryFollowUpRecord(
            id: row["id"], text: row["text"], done: row["done"],
            snoozedUntilMs: row["snoozedUntilMs"],
            origin: FollowUpOrigin(rawValue: row["origin"] ?? "ai") ?? .ai,
            sourceSegmentId: row["sourceSegmentId"],
            sourceWall: SegmentWallRange.sourceWall(from: row),
            createdAtMs: row["createdAtMs"])
    }
}
