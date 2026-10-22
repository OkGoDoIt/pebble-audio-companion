import Foundation
import GRDB

// A moment the person marked as important, from the watch's Mark Moment action.
//
// Only the time is kept. What was said around it is the recording's: the transcript shows the
// mark where it falls, and follow-up extraction reads the minute before it the way it reads a
// spoken "remind me" (`FollowUpRequestDetector`).

public enum MomentOrigin: String, Sendable, Equatable {
    case watch
}

public struct Moment: Sendable, Equatable, Identifiable {
    public var id: String
    /// When it was marked, epoch ms.
    public var wallMs: Int64
    /// Placed on the recording's own clock (the stream's sample count), which is the clock its
    /// transcript is on. False when it is the watch's clock, e.g. marked with nothing recording.
    public var onAudioClock: Bool
    public var origin: MomentOrigin
    public var createdAtMs: Int64

    public init(
        id: String, wallMs: Int64, onAudioClock: Bool, origin: MomentOrigin = .watch,
        createdAtMs: Int64
    ) {
        self.id = id
        self.wallMs = wallMs
        self.onAudioClock = onAudioClock
        self.origin = origin
        self.createdAtMs = createdAtMs
    }
}

public struct MomentStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Adds a moment; the same mark arriving twice (the watch resends after a reconnect) is kept
    /// once. True when it was new.
    @discardableResult
    public func add(_ moment: Moment) async throws -> Bool {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moments (id, wallMs, onAudioClock, origin, createdAtMs)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    moment.id, moment.wallMs, moment.onAudioClock, moment.origin.rawValue,
                    moment.createdAtMs,
                ])
            return db.changesCount > 0
        }
    }

    /// Moments with `startMs <= wallMs < endMs`, oldest first.
    public func moments(fromWallMs startMs: Int64, to endMs: Int64) async throws -> [Moment] {
        try await db.reader.read { db in
            try Self.moments(db, fromWallMs: startMs, to: endMs)
        }
    }

    public static func moments(_ db: Database, fromWallMs startMs: Int64, to endMs: Int64) throws
        -> [Moment]
    {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM moments WHERE wallMs >= ? AND wallMs < ? ORDER BY wallMs, id",
            arguments: [startMs, endMs]
        ).map(Self.moment(from:))
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM moments WHERE id = ?", arguments: [id])
        }
    }

    static func moment(from row: Row) -> Moment {
        Moment(
            id: row["id"],
            wallMs: row["wallMs"],
            onAudioClock: row["onAudioClock"] ?? false,
            origin: MomentOrigin(rawValue: row["origin"] ?? "watch") ?? .watch,
            createdAtMs: row["createdAtMs"])
    }
}
