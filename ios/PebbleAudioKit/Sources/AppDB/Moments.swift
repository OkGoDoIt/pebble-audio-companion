import Foundation
import GRDB

// A moment the person marked as important, from the watch's Mark Moment action.
//
// The mark and optional note are user data. Surrounding words remain the recording's, and a
// mark survives regrouping or audio retention. Marking is not a request to create a reminder.

public enum MomentOrigin: String, Sendable, Equatable {
    case watch
    /// Muse was asked, from the watch, to mark the moment.
    case muse
}

public struct MomentSuggestion: Codable, Sendable, Equatable {
    public var kind: String
    public var text: String
    public init(kind: String, text: String) { self.kind = kind; self.text = text }
}

public struct MomentReview: Codable, Sendable, Equatable {
    public var summary: String
    public var suggestions: [MomentSuggestion]
    public init(summary: String, suggestions: [MomentSuggestion]) {
        self.summary = summary; self.suggestions = suggestions
    }
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
    public var note: String
    /// nil for marks saved before this field existed. A wall-clock fallback alone does not
    /// mean recording was off (the mark may have arrived after its stream closed).
    public var wasRecording: Bool?
    public var review: MomentReview?
    public var reviewState: String = "pending"

    public init(
        id: String, wallMs: Int64, onAudioClock: Bool, origin: MomentOrigin = .watch,
        createdAtMs: Int64, note: String = "", wasRecording: Bool? = nil
    ) {
        self.id = id
        self.wallMs = wallMs
        self.onAudioClock = onAudioClock
        self.origin = origin
        self.createdAtMs = createdAtMs
        self.note = note
        self.wasRecording = wasRecording
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
                    INSERT INTO moments (id, wallMs, onAudioClock, origin, createdAtMs, note, wasRecording)
                    SELECT ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM moment_tombstones WHERE id = ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    moment.id, moment.wallMs, moment.onAudioClock, moment.origin.rawValue,
                    moment.createdAtMs, moment.note, moment.wasRecording, moment.id,
                ])
            return db.changesCount > 0
        }
    }

    public func observe() -> AsyncValueObservation<[Moment]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: "SELECT * FROM moments ORDER BY wallMs DESC, id DESC")
                .map(Self.moment(from:))
        }.removeDuplicates().values(in: db.reader)
    }

    public func setNote(id: String, note: String) async throws {
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE moments SET note = ? WHERE id = ? AND note != ?",
                           arguments: [text, id, text])
        }
    }

    public func deleteAll() async throws {
        try await db.writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO moment_tombstones SELECT id FROM moments")
            try db.execute(sql: "DELETE FROM moments")
        }
    }

    public func pendingReviews(nowMs: Int64) async throws -> [Moment] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM moments WHERE reviewState IN ('pending', 'retry') AND nextReviewMs <= ?
                AND wallMs <= ? ORDER BY wallMs DESC
                """, arguments: [nowMs, nowMs - 30_000]).map(Self.moment(from:))
        }
    }

    /// Updates an existing mark only: a model finishing after deletion cannot resurrect it.
    public func saveReview(id: String, review: MomentReview?, state: String, nextMs: Int64 = 0) async throws {
        let json = try review.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE moments SET reviewJSON = ?, reviewState = ?, nextReviewMs = ? WHERE id = ? AND reviewState != 'unavailable'",
                           arguments: [json, state, nextMs, id])
        }
    }

    /// The review read [-45s, +15s], so invalidate every mark whose context intersects the
    /// deleted range. An in-flight AI result is refused by `saveReview` afterwards.
    public func forgetRecordingContext(from startMs: Int64, to endMs: Int64) async throws {
        try await db.writer.write { db in
            try db.execute(sql: """
                UPDATE moments SET reviewJSON = NULL, reviewState = 'unavailable'
                WHERE wallMs > ? AND wallMs < ? AND reviewState != 'unavailable'
                """, arguments: [startMs - 15_000, endMs + 45_000])
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
            // A lost receipt can cause a retry after deletion. Keep only the wire identity so
            // a retry is acknowledged without bringing the person's deleted mark back.
            try db.execute(sql: "INSERT OR IGNORE INTO moment_tombstones (id) VALUES (?)", arguments: [id])
            try db.execute(sql: "DELETE FROM moments WHERE id = ?", arguments: [id])
        }
    }

    static func moment(from row: Row) -> Moment {
        var moment = Moment(
            id: row["id"],
            wallMs: row["wallMs"],
            onAudioClock: row["onAudioClock"] ?? false,
            origin: MomentOrigin(rawValue: row["origin"] ?? "watch") ?? .watch,
            createdAtMs: row["createdAtMs"], note: row["note"] ?? "",
            wasRecording: row["wasRecording"])
        moment.reviewState = row["reviewState"] ?? "pending"
        if let json: String = row["reviewJSON"] {
            moment.review = try? JSONDecoder().decode(MomentReview.self, from: Data(json.utf8))
        }
        return moment
    }
}
