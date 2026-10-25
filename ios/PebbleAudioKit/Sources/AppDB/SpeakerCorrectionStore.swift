import Foundation
import GRDB

/// A human decision about stored audio, independent of transcription labels and grouping.
/// A nil person is an explicit unnamed lock, not absence of a decision. Ranges are half-open.
public struct SpeakerCorrection: Equatable, Sendable {
    public var id: String
    public var segmentId: String
    public var startMediaMs: Int64
    public var endMediaMs: Int64
    public var person: Person?
    public var createdAtMs: Int64

    public init(
        id: String, segmentId: String, startMediaMs: Int64, endMediaMs: Int64,
        person: Person?, createdAtMs: Int64
    ) {
        self.id = id
        self.segmentId = segmentId
        self.startMediaMs = startMediaMs
        self.endMediaMs = endMediaMs
        self.person = person
        self.createdAtMs = createdAtMs
    }
}

public enum SpeakerCorrectionResolution: Equatable, Sendable {
    case named(Person)
    case unnamed
    /// A correction intersects the query but does not consistently cover all of it. Do not
    /// fall back to a provider-wide name: that would undo the user's narrower correction.
    case partial
}

/// Read once for a displayed/exported group of segments, then resolve turns without DB reads.
public struct SpeakerIdentitySnapshot: Equatable, Sendable {
    public var revision: Int64
    public var currentUserPersonId: String?
    public var corrections: [SpeakerCorrection]

    public init(
        revision: Int64 = 0, currentUserPersonId: String? = nil,
        corrections: [SpeakerCorrection] = []
    ) {
        self.revision = revision
        self.currentUserPersonId = currentUserPersonId
        self.corrections = corrections
    }

    /// Nil means no manual evidence intersects this interval, so legacy naming may be used.
    /// Exact coverage is intentional: a newly expanded ASR turn cannot inherit a name from a
    /// short corrected passage. Adjacent decisions for the same person can cover it together.
    public func resolve(
        segmentId: String, startMediaMs: Int64, endMediaMs: Int64
    ) -> SpeakerCorrectionResolution? {
        guard startMediaMs >= 0, endMediaMs > startMediaMs else { return nil }
        let intersecting = corrections.filter {
            $0.segmentId == segmentId && $0.startMediaMs < endMediaMs && $0.endMediaMs > startMediaMs
        }.sorted { $0.startMediaMs < $1.startMediaMs }
        guard let first = intersecting.first else { return nil }
        var coveredThrough = startMediaMs
        for correction in intersecting {
            guard correction.startMediaMs <= coveredThrough,
                correction.person?.id == first.person?.id
            else { return .partial }
            coveredThrough = max(coveredThrough, correction.endMediaMs)
        }
        guard coveredThrough >= endMediaMs else { return .partial }
        guard var person = first.person else { return .unnamed }
        person.isCurrentUser = person.id == currentUserPersonId
        return .named(person)
    }
}

public enum SpeakerCorrectionError: Error, Equatable, Sendable {
    case invalidRange
    case missingCurrentUser
}

public struct SpeakerCorrectionStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Replaces just the selected audio, preserving the parts of older decisions outside it.
    /// This is a manual naming operation, not voice enrollment. `makeCurrentUser` and the
    /// correction commit together, so a failed assignment cannot change who "You" means.
    public func set(
        segmentId: String, startMediaMs: Int64, endMediaMs: Int64, personId: String?,
        makeCurrentUser: Bool = false,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try Self.validate(segmentId: segmentId, start: startMediaMs, end: endMediaMs)
        if makeCurrentUser && personId == nil { throw SpeakerCorrectionError.missingCurrentUser }
        try await db.writer.write { d in
            if makeCurrentUser { try Self.setCurrentUser(d, personId: personId) }
            let current = try Self.fetchSnapshot(d, segmentIds: [segmentId])
            switch current.resolve(segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs) {
            case .named(let person) where person.id == personId: return
            case .unnamed where personId == nil: return
            default: break
            }
            try Self.removeRange(d, segmentId: segmentId, start: startMediaMs, end: endMediaMs)
            try Self.insert(d, id: UUID().uuidString.lowercased(), segmentId: segmentId,
                            start: startMediaMs, end: endMediaMs, personId: personId, createdAtMs: nowMs)
        }
    }

    /// Removes evidence for deleted/redacted audio. For a user choosing "leave unnamed", use
    /// `set(personId: nil)` instead, so legacy or later automatic naming cannot restore it.
    public func removeRange(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws {
        try Self.validate(segmentId: segmentId, start: startMediaMs, end: endMediaMs)
        try await db.writer.write { d in
            try Self.removeRange(d, segmentId: segmentId, start: startMediaMs, end: endMediaMs)
        }
    }

    public func delete(segmentId: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "DELETE FROM speaker_corrections WHERE segmentId = ?", arguments: [segmentId])
        }
    }

    public func deleteAll() async throws {
        try await db.writer.write { d in try d.execute(sql: "DELETE FROM speaker_corrections") }
    }

    public func snapshot(segmentIds: [String]) async throws -> SpeakerIdentitySnapshot {
        try await db.reader.read { d in try Self.fetchSnapshot(d, segmentIds: segmentIds) }
    }

    public func snapshot(conversationId: String) async throws -> SpeakerIdentitySnapshot {
        try await db.reader.read { d in
            let segments = try String.fetchAll(d, sql: """
                SELECT DISTINCT segmentId FROM conversation_segments WHERE conversationId = ?
                """, arguments: [conversationId])
            return try Self.fetchSnapshot(d, segmentIds: segments)
        }
    }

    public func observe(conversationId: String) -> AsyncValueObservation<SpeakerIdentitySnapshot> {
        ValueObservation.tracking { d in
            let segments = try String.fetchAll(d, sql: """
                SELECT DISTINCT segmentId FROM conversation_segments WHERE conversationId = ?
                """, arguments: [conversationId])
            return try Self.fetchSnapshot(d, segmentIds: segments)
        }.values(in: db.reader)
    }

    public func affectedConversationIds(
        segmentId: String, startMediaMs: Int64, endMediaMs: Int64
    ) async throws -> [String] {
        try Self.validate(segmentId: segmentId, start: startMediaMs, end: endMediaMs)
        return try await db.reader.read { d in
            try String.fetchAll(d, sql: """
                SELECT DISTINCT conversationId FROM conversation_segments
                WHERE segmentId = ? AND COALESCE(startMediaMs, 0) < ?
                    AND (endMediaMs IS NULL OR endMediaMs > ?)
                ORDER BY conversationId
                """, arguments: [segmentId, endMediaMs, startMediaMs])
        }
    }

    static func setCurrentUser(_ d: Database, personId: String?) throws {
        try d.execute(sql: """
            UPDATE speaker_identity_state SET currentUserPersonId = ?
            WHERE id = 1 AND currentUserPersonId IS NOT ?
            """, arguments: [personId, personId])
    }

    private static func validate(segmentId: String, start: Int64, end: Int64) throws {
        guard !segmentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              start >= 0, end > start else { throw SpeakerCorrectionError.invalidRange }
    }

    private static func insert(
        _ d: Database, id: String, segmentId: String, start: Int64, end: Int64,
        personId: String?, createdAtMs: Int64
    ) throws {
        try d.execute(sql: """
            INSERT INTO speaker_corrections (id, segmentId, startMediaMs, endMediaMs, personId, createdAtMs)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, segmentId, start, end, personId, createdAtMs])
    }

    private static func removeRange(_ d: Database, segmentId: String, start: Int64, end: Int64) throws {
        let old = try Row.fetchAll(d, sql: """
            SELECT * FROM speaker_corrections
            WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?
            """, arguments: [segmentId, end, start])
        for row in old {
            let id: String = row["id"]
            let lower: Int64 = row["startMediaMs"]
            let upper: Int64 = row["endMediaMs"]
            let personId: String? = row["personId"]
            let created: Int64 = row["createdAtMs"]
            try d.execute(sql: "DELETE FROM speaker_corrections WHERE id = ?", arguments: [id])
            if lower < start {
                try insert(d, id: id, segmentId: segmentId, start: lower, end: start,
                           personId: personId, createdAtMs: created)
            }
            if upper > end {
                try insert(d, id: UUID().uuidString.lowercased(), segmentId: segmentId,
                           start: end, end: upper, personId: personId, createdAtMs: created)
            }
        }
    }

    static func fetchSnapshot(_ d: Database, segmentIds: [String]) throws -> SpeakerIdentitySnapshot {
        let state = try Row.fetchOne(d, sql: "SELECT * FROM speaker_identity_state WHERE id = 1")
        let currentUser: String? = state?["currentUserPersonId"]
        var corrections: [SpeakerCorrection] = []
        // Bound SQLite's variables for large exports/backfills. No audio or transcript is read.
        let unique = Array(Set(segmentIds)).sorted()
        for offset in stride(from: 0, to: unique.count, by: 400) {
            let batch = Array(unique[offset..<min(offset + 400, unique.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            corrections += try Row.fetchAll(d, sql: """
                SELECT sc.*, p.name AS personName FROM speaker_corrections sc
                LEFT JOIN people p ON p.id = sc.personId
                WHERE sc.segmentId IN (\(placeholders))
                ORDER BY sc.segmentId, sc.startMediaMs
                """, arguments: StatementArguments(batch)).map { row in
                    let personId: String? = row["personId"]
                    let person = personId.map {
                        Person(id: $0, name: row["personName"], isCurrentUser: $0 == currentUser)
                    }
                    return SpeakerCorrection(id: row["id"], segmentId: row["segmentId"],
                                             startMediaMs: row["startMediaMs"], endMediaMs: row["endMediaMs"],
                                             person: person, createdAtMs: row["createdAtMs"])
                }
        }
        return SpeakerIdentitySnapshot(revision: state?["revision"] ?? 0,
                                       currentUserPersonId: currentUser, corrections: corrections)
    }

    // MARK: - Additive schema and transactional change propagation

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE speaker_identity_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                currentUserPersonId TEXT REFERENCES people(id) ON DELETE SET NULL,
                revision INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE speaker_corrections (
                id TEXT PRIMARY KEY NOT NULL,
                segmentId TEXT NOT NULL CHECK (length(segmentId) > 0),
                startMediaMs INTEGER NOT NULL CHECK (startMediaMs >= 0),
                endMediaMs INTEGER NOT NULL CHECK (endMediaMs > startMediaMs),
                personId TEXT REFERENCES people(id) ON DELETE SET NULL,
                createdAtMs INTEGER NOT NULL
            );
            CREATE INDEX speaker_corrections_segment ON speaker_corrections(segmentId, startMediaMs, endMediaMs);
            CREATE INDEX speaker_corrections_person ON speaker_corrections(personId);
            """)
        // Older migration tests recreate only the tables they exercise, omitting `people`.
        // A real v1 database always has it; don't create invented people in those fixtures.
        guard try d.tableExists("people") else { return }
        try d.execute(sql: "INSERT INTO speaker_identity_state (id) VALUES (1)")
        let revision = "UPDATE speaker_identity_state SET revision = revision + 1 WHERE id = 1;"
        for (event, reference) in [("INSERT", "NEW"), ("DELETE", "OLD")] {
            try trigger(d, name: "identity_correction_\(event.lowercased())", event: event,
                        table: "speaker_corrections", statements: [revision] + markRange(reference))
        }
        try trigger(d, name: "identity_correction_update", event: "UPDATE", table: "speaker_corrections",
                    when: "OLD.segmentId IS NOT NEW.segmentId OR OLD.startMediaMs IS NOT NEW.startMediaMs OR OLD.endMediaMs IS NOT NEW.endMediaMs OR OLD.personId IS NOT NEW.personId",
                    statements: [revision] + markRange("OLD") + markRange("NEW"))
        try trigger(d, name: "identity_person_rename", event: "UPDATE OF name", table: "people",
                    when: "OLD.name IS NOT NEW.name", statements: [revision] + markPerson("NEW.id"))
        try trigger(d, name: "identity_person_delete", event: "DELETE", table: "people", statements: [revision])
        try trigger(d, name: "identity_current_user", event: "UPDATE OF currentUserPersonId",
                    table: "speaker_identity_state", when: "OLD.currentUserPersonId IS NOT NEW.currentUserPersonId",
                    statements: [revision] + markPerson("OLD.currentUserPersonId") + markPerson("NEW.currentUserPersonId"))
    }

    private static func trigger(
        _ d: Database, name: String, event: String, table: String,
        when condition: String? = nil, statements: [String]
    ) throws {
        try d.execute(sql: """
            CREATE TRIGGER \(name) AFTER \(event) ON \(table)
            \(condition.map { "WHEN \($0)" } ?? "")
            BEGIN
            \(statements.joined(separator: "\n"))
            END
            """)
    }

    private static func markRange(_ row: String) -> [String] {
        ["conversation", "transcript"].map { kind in
            ArchiveOutbox.enqueueSQL(kind: "'\(kind)'", id: "cs.conversationId", op: "'upsert'",
                from: "conversation_segments cs",
                condition: "cs.segmentId = \(row).segmentId AND COALESCE(cs.startMediaMs, 0) < \(row).endMediaMs AND (cs.endMediaMs IS NULL OR cs.endMediaMs > \(row).startMediaMs)")
        }
    }

    private static func markPerson(_ person: String) -> [String] {
        ["conversation", "transcript"].map { kind in
            ArchiveOutbox.enqueueSQL(kind: "'\(kind)'", id: "c.id", op: "'upsert'", from: "conversations c",
                condition: """
                    c.id IN (SELECT conversationId FROM speaker_assignments WHERE personId = \(person)
                    UNION SELECT cs.conversationId FROM conversation_segments cs
                    JOIN speaker_corrections sc ON sc.segmentId = cs.segmentId
                    WHERE sc.personId = \(person) AND COALESCE(cs.startMediaMs, 0) < sc.endMediaMs
                        AND (cs.endMediaMs IS NULL OR cs.endMediaMs > sc.startMediaMs))
                    """)
        }
    }
}
