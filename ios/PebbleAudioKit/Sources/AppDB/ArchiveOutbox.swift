import Foundation
import GRDB

// The phone half of the Pebble Audio archive sync (`server/docs/sync-protocol.md`): what has
// changed since the server last heard, one row per entity.
//
// WHY A STATE TABLE AND NOT A LOG
//
// The server keeps the highest version it has seen of each `(kind, id)` and ignores anything at
// or below it, so the only thing the phone ever owes it is the CURRENT state of each entity that
// changed. A log of every write would send a live conversation's annotation twenty times; this
// sends it once, at whatever it is when the batch is built. The row stays after it is sent: it
// holds the last version (so the next one is higher even if the clock moved back), the hash of
// what the server accepted (so an unchanged payload is never sent again), and for a
// conversation the piece list it was sent with.
//
// WHO WRITES IT
//
//  - SQL triggers on the tables a payload is built from (annotations, tags, speaker names,
//    people, follow-ups, notes, recaps, briefs, finished transcriptions, audio-content spans).
//    Every write path reaches them, the reconciler's raw `UPDATE`s and a future store included,
//    and they run inside the write's own transaction, so a change and its outbox row commit
//    together or not at all.
//  - `ConversationGrouper.apply` for the grouping itself, explicitly (`ArchiveOutboxGrouping`):
//    it rewrites every row on every change, so a trigger there would mark the whole library
//    each pass while the watch records.
//  - `DeleteCascade` for the two deletes a trigger cannot tell apart: retention ageing a
//    recording out (`expire`, which the server keeps) and the person deleting it (`delete`).
//
// Nothing is written while no server is linked (`sync_outbox_state.active`): a phone that never
// links pays one indexed read per write and keeps no history it would later have to discard.

/// What the server calls each synced thing (`sync-protocol.md` §2).
public enum ArchiveEntityKind: String, Codable, Sendable, CaseIterable {
    case conversation
    case transcript
    case recap
    case brief
    case followUp
    case note
    case person
    case coverage
}

/// `upsert` carries a payload; `delete` is the person deleting it (the server deletes it and
/// everything derived from it); `expire` is retention ageing it out (the server keeps it).
public enum ArchiveOp: String, Codable, Sendable, CaseIterable {
    case upsert
    case delete
    case expire
    /// A names-only transcript overlay. Stored outbox rows still use upsert; the builder
    /// chooses this wire operation when retention prevents sending a complete transcript.
    case speakerPatch
}

/// One entity's sync state.
public struct ArchiveOutboxRow: Equatable, Sendable {
    public var kind: ArchiveEntityKind
    public var entityId: String
    /// Only ever increases for this entity: `max(now, previous + 1)` at every change.
    public var version: Int64
    public var op: ArchiveOp
    public var changedAtMs: Int64
    public var pending: Bool
    /// Rejections of the current version. Reset by every new change.
    public var attempts: Int
    public var lastError: String?
    /// For a conversation: whether it was provisional when it was last marked ("p1"/"p0").
    public var hint: String?
    /// What the server accepted last: the payload's hash (a transcript's `sourceHash`).
    public var sentHash: String?
    /// For a conversation or transcript: the piece list (`ConversationSourceKey`) last accepted.
    public var sentKey: String?

    public init(
        kind: ArchiveEntityKind, entityId: String, version: Int64, op: ArchiveOp,
        changedAtMs: Int64, pending: Bool, attempts: Int = 0, lastError: String? = nil,
        hint: String? = nil, sentHash: String? = nil, sentKey: String? = nil
    ) {
        self.kind = kind
        self.entityId = entityId
        self.version = version
        self.op = op
        self.changedAtMs = changedAtMs
        self.pending = pending
        self.attempts = attempts
        self.lastError = lastError
        self.hint = hint
        self.sentHash = sentHash
        self.sentKey = sentKey
    }

    static func from(_ row: Row) -> ArchiveOutboxRow? {
        guard let kind = ArchiveEntityKind(rawValue: row["kind"]),
            let op = ArchiveOp(rawValue: row["op"])
        else { return nil }
        return ArchiveOutboxRow(
            kind: kind, entityId: row["entityId"], version: row["version"], op: op,
            changedAtMs: row["changedAtMs"], pending: row["pending"], attempts: row["attempts"],
            lastError: row["lastError"], hint: row["hint"], sentHash: row["sentHash"],
            sentKey: row["sentKey"])
    }
}

/// One item of a batch the server answered about.
public struct ArchiveItemKey: Hashable, Sendable {
    public var kind: ArchiveEntityKind
    public var entityId: String
    public var version: Int64

    public init(kind: ArchiveEntityKind, entityId: String, version: Int64) {
        self.kind = kind
        self.entityId = entityId
        self.version = version
    }
}

/// What an item was sent as, recorded when the batch is submitted so the answer can be applied
/// after a relaunch: the server's reply names only kind, id and version.
public struct ArchiveSentItem: Hashable, Sendable {
    public var key: ArchiveItemKey
    public var hash: String?
    public var pieceKey: String?

    public init(key: ArchiveItemKey, hash: String?, pieceKey: String?) {
        self.key = key
        self.hash = hash
        self.pieceKey = pieceKey
    }
}

public struct ArchiveOutbox: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Rejections after which an item stops being sent and is shown as an error. Each new
    /// change to the entity starts it over.
    public static let maxAttempts = 5

    /// How long an `expire` is protected from the `delete` the rest of its own cascade writes.
    /// Retention deletes the rows an expiry is about a moment after marking them (the
    /// follow-ups, the notes, the conversation itself at the next regroup), and each of those
    /// deletes looks exactly like the person deleting it. A day is generous; a person deleting
    /// a conversation goes through `markUserDelete`, which is never held back.
    public static let expireHoldMs: Int64 = 24 * 60 * 60 * 1000

    // MARK: - Schema (the migration in `AppDatabase` runs this once)

    /// SQLite's clock in epoch milliseconds, usable inside a trigger.
    static let nowMsSQL = "CAST((julianday('now') - 2440587.5) * 86400000.0 AS INTEGER)"

    /// The guard every write carries: nothing while no server is linked.
    static let activeSQL = "(SELECT active FROM sync_outbox_state WHERE id = 1) = 1"

    /// The upsert every enqueue is: insert the row, or bump its version and mark it pending.
    ///
    /// An `expire` is terminal for upserts — what retention aged out is not sent again when a
    /// regenerated recap or the shrunken tail of a conversation is written — and holds against
    /// a `delete` until `holdUntilMs`, so the cascade's own deletes cannot turn it into one.
    /// `hint` is only ever replaced by a value, never cleared by a write that has none.
    static func enqueueSQL(
        kind: String, id: String, op: String, from: String? = nil, condition: String? = nil,
        hint: String = "NULL", holdUntil: String = "NULL"
    ) -> String {
        let fromClause = from.map { " FROM \($0)" } ?? ""
        let whereClause = [activeSQL, condition].compactMap { $0 }.joined(separator: " AND ")
        return """
            INSERT INTO sync_outbox (kind, entityId, version, op, changedAtMs, pending, hint,
                holdUntilMs)
            SELECT \(kind), \(id), \(nowMsSQL), \(op), \(nowMsSQL), 1, \(hint), \(holdUntil)
            \(fromClause) WHERE \(whereClause)
            ON CONFLICT(kind, entityId) DO UPDATE SET
                version = MAX(excluded.version, sync_outbox.version + 1),
                op = excluded.op,
                changedAtMs = excluded.changedAtMs,
                pending = 1, attempts = 0, lastError = NULL,
                hint = COALESCE(excluded.hint, sync_outbox.hint),
                holdUntilMs = excluded.holdUntilMs
            WHERE NOT (sync_outbox.op = 'expire' AND (excluded.op = 'upsert'
                OR (excluded.op = 'delete'
                    AND COALESCE(sync_outbox.holdUntilMs, 0) > excluded.changedAtMs)));
            """
    }

    /// The tables, the activation row, and the triggers. Every trigger is `AFTER` and writes
    /// only `sync_outbox`, so none can fire another.
    static func installSchema(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE sync_outbox (
                    kind TEXT NOT NULL,
                    entityId TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    op TEXT NOT NULL,
                    changedAtMs INTEGER NOT NULL,
                    pending INTEGER NOT NULL DEFAULT 1,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    lastError TEXT,
                    holdUntilMs INTEGER,
                    hint TEXT,
                    sentVersion INTEGER,
                    sentHash TEXT,
                    sentKey TEXT,
                    inflightVersion INTEGER,
                    inflightHash TEXT,
                    inflightKey TEXT,
                    PRIMARY KEY (kind, entityId)
                )
                """)
        try db.execute(
            sql: "CREATE INDEX sync_outbox_pending ON sync_outbox(changedAtMs) WHERE pending = 1")
        try db.execute(
            sql: """
                CREATE INDEX sync_outbox_provisional ON sync_outbox(entityId)
                WHERE kind = 'conversation' AND hint = 'p1'
                """)
        try db.execute(
            sql: """
                CREATE TABLE sync_outbox_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    active INTEGER NOT NULL DEFAULT 0
                )
                """)
        try db.execute(sql: "INSERT INTO sync_outbox_state (id, active) VALUES (1, 0)")
        for trigger in triggers() {
            guard try db.tableExists(trigger.table) else { continue }
            try db.execute(sql: trigger.sql)
        }
    }

    /// `kind`/`id`/`op` are SQL expressions (literals in quotes, or `NEW.x`/`OLD.x`).
    struct Trigger {
        var table: String
        var sql: String
    }

    private static func trigger(
        _ name: String, _ timing: String, on table: String, when: String? = nil,
        _ statements: [String]
    ) -> Trigger {
        Trigger(
            table: table,
            sql: """
                CREATE TRIGGER \(name) AFTER \(timing) ON \(table)
                \(when.map { "WHEN \($0)" } ?? "")
                BEGIN
                \(statements.joined(separator: "\n"))
                END
                """)
    }

    private static func changed(_ columns: [String]) -> String {
        columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
    }

    private static func conversationExists(_ column: String) -> String {
        "EXISTS (SELECT 1 FROM conversations WHERE id = \(column))"
    }

    /// The conversation (and optionally its transcript) a row names, while it exists.
    private static func markConversation(_ column: String, transcript: Bool = false) -> [String] {
        var out = [
            enqueueSQL(
                kind: "'conversation'", id: column, op: "'upsert'",
                condition: conversationExists(column))
        ]
        if transcript {
            out.append(
                enqueueSQL(
                    kind: "'transcript'", id: column, op: "'upsert'",
                    condition: conversationExists(column)))
        }
        return out
    }

    /// Every conversation that holds a piece of `segmentColumn`'s segment.
    private static func markConversations(
        ofSegment segmentColumn: String, conversation: Bool, transcript: Bool
    ) -> [String] {
        var out: [String] = []
        let from = "(SELECT DISTINCT conversationId AS cid FROM conversation_segments WHERE segmentId = \(segmentColumn))"
        if conversation {
            out.append(enqueueSQL(kind: "'conversation'", id: "cid", op: "'upsert'", from: from))
        }
        if transcript {
            out.append(enqueueSQL(kind: "'transcript'", id: "cid", op: "'upsert'", from: from))
        }
        return out
    }

    /// The follow-up columns a payload is built from, as `archive-sync-outbox-v1` installed them.
    /// `stage` came later (`follow-ups-stage-v1`), so on a phone that ran that migration first the
    /// column did not exist yet; `installFollowUpStage` replaces the update trigger with one that
    /// watches it too.
    static let followUpColumns = [
        "text", "done", "sourceConversationId", "sourceSegmentId", "quote", "why", "dueAtMs",
        "priority", "completedAtMs", "archivedAtMs", "snoozedUntilMs", "editedAtMs", "origin",
        "sourceWallStartMs", "sourceWallEndMs", "sourceWallApproximate",
    ]

    private static func followUpUpdateTrigger(columns: [String]) -> Trigger {
        trigger("sync_follow_ups_au", "UPDATE", on: "follow_ups",
            when: changed(columns),
            [enqueueSQL(kind: "'followUp'", id: "NEW.id", op: "'upsert'")])
    }

    /// A follow-up's stage on the wire (`sync-protocol.md` §2.5): the update trigger watches
    /// `stage` too, so a review's answer reaches the server, and every follow-up is marked to be
    /// sent once more so the server learns the stage of each. The payload gained the field, so
    /// none of them matches the hash the server last accepted. Nothing is marked while no server
    /// is linked.
    static func installFollowUpStage(_ db: Database) throws {
        guard try db.tableExists("follow_ups"), try db.tableExists("sync_outbox") else { return }
        try db.execute(sql: "DROP TRIGGER IF EXISTS sync_follow_ups_au")
        try db.execute(sql: followUpUpdateTrigger(columns: followUpColumns + ["stage"]).sql)
        try db.execute(
            sql: enqueueSQL(kind: "'followUp'", id: "id", op: "'upsert'", from: "follow_ups"))
    }

    static func triggers() -> [Trigger] {
        let annotationColumns = ["title", "summary", "tagsJson", "isFinal", "titleEditedAtMs"]
        let recapColumns = [
            "text", "segmentIds", "provider", "model", "shortText", "headline", "lineSummary",
        ]
        let briefColumns = ["text", "headline", "lineSummary", "provider", "model"]
        let noteColumns = [
            "conversationId", "templateId", "title", "body", "citations", "provider", "model",
            "editedAtMs", "origin",
        ]
        let deleteOp = "'delete'"
        return [
            // A conversation's title, summary and tags.
            trigger("sync_annotations_ai", "INSERT", on: "annotations",
                markConversation("NEW.conversationId")),
            trigger("sync_annotations_au", "UPDATE", on: "annotations",
                when: changed(annotationColumns), markConversation("NEW.conversationId")),
            trigger("sync_annotations_ad", "DELETE", on: "annotations",
                markConversation("OLD.conversationId")),
            trigger("sync_conversation_tags_ai", "INSERT", on: "conversation_tags",
                markConversation("NEW.conversationId")),
            trigger("sync_conversation_tags_au", "UPDATE", on: "conversation_tags",
                markConversation("NEW.conversationId")),
            trigger("sync_conversation_tags_ad", "DELETE", on: "conversation_tags",
                markConversation("OLD.conversationId")),
            trigger("sync_tags_au", "UPDATE OF name", on: "tags",
                when: "OLD.name IS NOT NEW.name",
                [
                    enqueueSQL(
                        kind: "'conversation'", id: "ct.conversationId", op: "'upsert'",
                        from: "conversation_tags ct",
                        condition: "ct.tagId = NEW.id AND " + conversationExists("ct.conversationId"))
                ]),
            // Speaker names: the conversation's people and the transcript's turns.
            trigger("sync_speakers_ai", "INSERT", on: "speaker_assignments",
                markConversation("NEW.conversationId", transcript: true)),
            trigger("sync_speakers_au", "UPDATE", on: "speaker_assignments",
                markConversation("NEW.conversationId", transcript: true)
                    + markConversation("OLD.conversationId", transcript: true)),
            trigger("sync_speakers_ad", "DELETE", on: "speaker_assignments",
                markConversation("OLD.conversationId", transcript: true)),
            // People.
            trigger("sync_people_ai", "INSERT", on: "people",
                [enqueueSQL(kind: "'person'", id: "NEW.id", op: "'upsert'")]),
            trigger("sync_people_au", "UPDATE", on: "people", when: "OLD.name IS NOT NEW.name",
                [
                    enqueueSQL(kind: "'person'", id: "NEW.id", op: "'upsert'"),
                    enqueueSQL(
                        kind: "'conversation'", id: "sa.conversationId", op: "'upsert'",
                        from: "speaker_assignments sa",
                        condition: "sa.personId = NEW.id AND " + conversationExists("sa.conversationId")),
                    enqueueSQL(
                        kind: "'transcript'", id: "sa.conversationId", op: "'upsert'",
                        from: "speaker_assignments sa",
                        condition: "sa.personId = NEW.id AND " + conversationExists("sa.conversationId")),
                ]),
            trigger("sync_people_ad", "DELETE", on: "people",
                [enqueueSQL(kind: "'person'", id: "OLD.id", op: deleteOp)]),
            // Follow-ups.
            trigger("sync_follow_ups_ai", "INSERT", on: "follow_ups",
                [enqueueSQL(kind: "'followUp'", id: "NEW.id", op: "'upsert'")]),
            followUpUpdateTrigger(columns: followUpColumns),
            trigger("sync_follow_ups_ad", "DELETE", on: "follow_ups",
                [enqueueSQL(kind: "'followUp'", id: "OLD.id", op: deleteOp)]),
            // Notes.
            trigger("sync_notes_ai", "INSERT", on: "notes",
                [enqueueSQL(kind: "'note'", id: "NEW.id", op: "'upsert'")]),
            trigger("sync_notes_au", "UPDATE", on: "notes", when: changed(noteColumns),
                [enqueueSQL(kind: "'note'", id: "NEW.id", op: "'upsert'")]),
            trigger("sync_notes_ad", "DELETE", on: "notes",
                [enqueueSQL(kind: "'note'", id: "OLD.id", op: deleteOp)]),
            // Day recaps.
            trigger("sync_recaps_ai", "INSERT", on: "recaps",
                [enqueueSQL(kind: "'recap'", id: "NEW.dateKey", op: "'upsert'")]),
            trigger("sync_recaps_au", "UPDATE", on: "recaps", when: changed(recapColumns),
                [enqueueSQL(kind: "'recap'", id: "NEW.dateKey", op: "'upsert'")]),
            trigger("sync_recaps_ad", "DELETE", on: "recaps",
                [enqueueSQL(kind: "'recap'", id: "OLD.dateKey", op: deleteOp)]),
            // Week and month briefs. A row with no text is a failed attempt's bookkeeping.
            trigger("sync_briefs_ai", "INSERT", on: "period_briefs",
                when: "NEW.text IS NOT NULL",
                [enqueueSQL(kind: "'brief'", id: "NEW.periodKey", op: "'upsert'")]),
            trigger("sync_briefs_au", "UPDATE", on: "period_briefs", when: changed(briefColumns),
                [enqueueSQL(kind: "'brief'", id: "NEW.periodKey", op: "'upsert'")]),
            trigger("sync_briefs_ad", "DELETE", on: "period_briefs",
                [enqueueSQL(kind: "'brief'", id: "OLD.periodKey", op: deleteOp)]),
            // A transcription finished (first time, or a re-transcription): the transcripts of
            // the conversations that hold the segment.
            trigger("sync_transcription_done_ai", "INSERT", on: "transcription_tasks",
                when: "NEW.state IN ('Complete', 'NoSpeech')",
                markConversations(ofSegment: "NEW.segmentId", conversation: false, transcript: true)),
            trigger("sync_transcription_done_au", "UPDATE OF state", on: "transcription_tasks",
                when: "NEW.state IN ('Complete', 'NoSpeech') AND OLD.state IS NOT NEW.state",
                markConversations(ofSegment: "NEW.segmentId", conversation: false, transcript: true)),
            // What a stretch holds decides a conversation's kind and the transcript's mask.
            trigger("sync_content_ai", "INSERT", on: "audio_content_spans",
                markConversations(ofSegment: "NEW.segmentId", conversation: true, transcript: true)),
            trigger("sync_content_ad", "DELETE", on: "audio_content_spans",
                markConversations(ofSegment: "OLD.segmentId", conversation: true, transcript: true)),
        ]
    }

    // MARK: - Enqueue from Swift (inside the caller's transaction)

    public static func isActive(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT active FROM sync_outbox_state WHERE id = 1") ?? false
    }

    /// Marks one entity. `holdMs` protects an `expire` from deletes for that long.
    public static func enqueue(
        _ db: Database, kind: ArchiveEntityKind, id: String, op: ArchiveOp,
        hint: String? = nil, holdMs: Int64? = nil
    ) throws {
        try db.execute(
            sql: enqueueSQL(
                kind: "?", id: "?", op: "?", hint: "?",
                holdUntil: holdMs.map { "\(nowMsSQL) + \($0)" } ?? "NULL"),
            arguments: [kind.rawValue, id, op.rawValue, hint])
    }

    /// A delete the PERSON asked for. Never held back by an expiry: what they delete is deleted
    /// on the server too, whatever retention said about it before.
    public static func enqueueUserDelete(
        _ db: Database, kind: ArchiveEntityKind, id: String
    ) throws {
        guard try isActive(db) else { return }
        try db.execute(
            sql: """
                INSERT INTO sync_outbox (kind, entityId, version, op, changedAtMs, pending)
                VALUES (?, ?, \(nowMsSQL), 'delete', \(nowMsSQL), 1)
                ON CONFLICT(kind, entityId) DO UPDATE SET
                    version = MAX(excluded.version, sync_outbox.version + 1),
                    op = 'delete', changedAtMs = excluded.changedAtMs,
                    pending = 1, attempts = 0, lastError = NULL, holdUntilMs = NULL
                """,
            arguments: [kind.rawValue, id])
    }

    // MARK: - The two deletes a trigger cannot tell apart

    /// Retention is about to delete `segmentId`. Marks everything the server should KEEP as
    /// expired — the conversations with a piece of it and their transcripts and notes, the
    /// follow-ups said in it, the day recaps that quote it, the coverage of its days, and the
    /// week and month briefs over those days — before the cascade deletes any of them, so the
    /// deletes that follow (and the regroup that drops the conversation) are held back.
    ///
    /// A conversation that runs on into a newer recording is expired too. It is about to age
    /// out itself, and the alternative is the server overwriting the whole conversation with
    /// the tail the phone still holds.
    public func markExpiring(segmentId: String) async throws {
        try await db.writer.write { d in
            guard try Self.isActive(d) else { return }
            let hold = Self.expireHoldMs
            let conversations = try Row.fetchAll(
                d,
                sql: """
                    SELECT DISTINCT c.id AS id, c.startMs AS startMs, c.endMs AS endMs,
                        c.timezone AS timezone
                    FROM conversation_segments cs JOIN conversations c ON c.id = cs.conversationId
                    WHERE cs.segmentId = ?
                    """,
                arguments: [segmentId])
            var days = Set<String>()
            for row in conversations {
                let id: String = row["id"]
                try Self.enqueue(d, kind: .conversation, id: id, op: .expire, holdMs: hold)
                try Self.enqueue(d, kind: .transcript, id: id, op: .expire, holdMs: hold)
                for note in try String.fetchAll(
                    d, sql: "SELECT id FROM notes WHERE conversationId = ?", arguments: [id])
                {
                    try Self.enqueue(d, kind: .note, id: note, op: .expire, holdMs: hold)
                }
                let start: Int64 = row["startMs"]
                days.formUnion(
                    ConversationQueries.dateKeys(
                        startMs: start, endMs: row["endMs"] ?? start, timeZoneID: row["timezone"]))
            }
            for followUp in try String.fetchAll(
                d, sql: "SELECT id FROM follow_ups WHERE sourceSegmentId = ?",
                arguments: [segmentId])
            {
                try Self.enqueue(d, kind: .followUp, id: followUp, op: .expire, holdMs: hold)
            }
            // `segmentIds` is a JSON array of strings; a segment id contains no quote.
            for row in try Row.fetchAll(
                d, sql: "SELECT dateKey FROM recaps WHERE segmentIds LIKE ?",
                arguments: ["%\"\(segmentId)\"%"])
            {
                let day: String = row["dateKey"]
                days.insert(day)
                try Self.enqueue(d, kind: .recap, id: day, op: .expire, holdMs: hold)
            }
            for day in days {
                try Self.enqueue(d, kind: .coverage, id: day, op: .expire, holdMs: hold)
            }
            // A brief summarises its recaps; once one of them is aging out, what the server has
            // is the brief written from the whole period.
            for key in try String.fetchAll(
                d, sql: "SELECT periodKey FROM period_briefs WHERE text IS NOT NULL")
            where Self.brief(key, covers: days) {
                try Self.enqueue(d, kind: .brief, id: key, op: .expire, holdMs: hold)
            }
        }
    }

    /// `week:<first day>` covers seven days from it; `month:<yyyy-MM>` its month.
    static func brief(_ key: String, covers days: Set<String>) -> Bool {
        if key.hasPrefix("month:") {
            let month = String(key.dropFirst("month:".count))
            return days.contains { $0.hasPrefix(month + "-") }
        }
        guard key.hasPrefix("week:") else { return false }
        let first = String(key.dropFirst("week:".count))
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        func date(_ key: String) -> Date? {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let start = date(first) else { return false }
        return days.contains { day in
            guard let d = date(day) else { return false }
            let offset = utc.dateComponents([.day], from: start, to: d).day ?? -1
            return offset >= 0 && offset < 7
        }
    }

    /// The person is deleting `conversationId`: it, its transcript, its notes and the
    /// follow-ups sourced in it are deleted on the server too. Marked before the cascade runs.
    public func markUserDelete(conversationId: String) async throws {
        try await db.writer.write { d in
            guard try Self.isActive(d) else { return }
            try Self.enqueueUserDelete(d, kind: .conversation, id: conversationId)
            try Self.enqueueUserDelete(d, kind: .transcript, id: conversationId)
            for note in try String.fetchAll(
                d, sql: "SELECT id FROM notes WHERE conversationId = ?",
                arguments: [conversationId])
            {
                try Self.enqueueUserDelete(d, kind: .note, id: note)
            }
            for followUp in try String.fetchAll(
                d, sql: "SELECT id FROM follow_ups WHERE sourceConversationId = ?",
                arguments: [conversationId])
            {
                try Self.enqueueUserDelete(d, kind: .followUp, id: followUp)
            }
        }
    }

    // MARK: - Linking, unlinking, wiping

    /// Starts (or stops) recording changes. Stopping forgets everything recorded so far: the
    /// next link starts from a full send (`markEverything`), not from a stale history.
    public func setActive(_ active: Bool) async throws {
        try await db.writer.write { d in
            let was = try Self.isActive(d)
            guard was != active else { return }
            try d.execute(
                sql: "UPDATE sync_outbox_state SET active = ? WHERE id = 1", arguments: [active])
            if !active { try d.execute(sql: "DELETE FROM sync_outbox") }
        }
    }

    public func isActive() async throws -> Bool {
        try await db.reader.read { try Self.isActive($0) }
    }

    /// Everything the server should hold, marked pending: the first sync after linking, and the
    /// re-send after a wipe. Coverage is marked for every day a conversation touches.
    @discardableResult
    public func markEverything() async throws -> Int {
        try await db.writer.write { d in
            guard try Self.isActive(d) else { return 0 }
            let before = d.totalChangesCount
            try d.execute(
                sql: Self.enqueueSQL(
                    kind: "'conversation'", id: "id", op: "'upsert'", from: "conversations"))
            try d.execute(
                sql: Self.enqueueSQL(
                    kind: "'transcript'", id: "id", op: "'upsert'", from: "conversations"))
            try d.execute(
                sql: Self.enqueueSQL(kind: "'recap'", id: "dateKey", op: "'upsert'", from: "recaps"))
            try d.execute(
                sql: Self.enqueueSQL(
                    kind: "'brief'", id: "periodKey", op: "'upsert'", from: "period_briefs",
                    condition: "text IS NOT NULL"))
            try d.execute(
                sql: Self.enqueueSQL(kind: "'followUp'", id: "id", op: "'upsert'", from: "follow_ups"))
            try d.execute(
                sql: Self.enqueueSQL(kind: "'note'", id: "id", op: "'upsert'", from: "notes"))
            try d.execute(
                sql: Self.enqueueSQL(kind: "'person'", id: "id", op: "'upsert'", from: "people"))
            var days = Set<String>()
            for row in try Row.fetchAll(
                d, sql: "SELECT startMs, endMs, timezone FROM conversations")
            {
                let start: Int64 = row["startMs"]
                days.formUnion(
                    ConversationQueries.dateKeys(
                        startMs: start, endMs: row["endMs"] ?? start, timeZoneID: row["timezone"]))
            }
            for day in days.sorted() {
                try Self.enqueue(d, kind: .coverage, id: day, op: .upsert)
            }
            return d.totalChangesCount - before
        }
    }

    /// The next `limit` conversations after `cursor` (by id), each with its transcript, marked
    /// to be sent again: one page of a re-export (`ArchiveSyncService`). Both, because both
    /// payloads carry the export's meaning — the conversation's gaps are the screen's rows too.
    /// A conversation whose payload comes out unchanged is not sent (its hash says so). Returns
    /// the ids it marked, in order, or nil when nothing is being recorded.
    public func markForReExport(after cursor: String?, limit: Int) async throws -> [String]? {
        try await db.writer.write { d in
            guard try Self.isActive(d) else { return nil }
            let ids = try String.fetchAll(
                d, sql: "SELECT id FROM conversations WHERE id > ? ORDER BY id LIMIT ?",
                arguments: [cursor ?? "", limit])
            for id in ids {
                try Self.enqueue(d, kind: .conversation, id: id, op: .upsert)
                try Self.enqueue(d, kind: .transcript, id: id, op: .upsert)
            }
            return ids
        }
    }

    /// "Delete all": the server is wiped by its own endpoint, so nothing recorded about the
    /// deleted library may be sent after it.
    public func clearAll() async throws {
        try await db.writer.write { d in try d.execute(sql: "DELETE FROM sync_outbox") }
    }

    // MARK: - Draining

    /// The next pending rows, oldest change first, without the ones that ran out of attempts.
    public func pending(limit: Int) async throws -> [ArchiveOutboxRow] {
        try await db.reader.read { d in
            try Row.fetchAll(
                d,
                sql: """
                    SELECT * FROM sync_outbox WHERE pending = 1 AND attempts < ?
                    ORDER BY changedAtMs, kind, entityId LIMIT ?
                    """,
                arguments: [Self.maxAttempts, limit]
            ).compactMap(ArchiveOutboxRow.from)
        }
    }

    /// Whether anything is waiting to be sent. One indexed read.
    public func hasPending() async throws -> Bool {
        try await db.reader.read { d in
            try Bool.fetchOne(
                d,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE pending = 1 AND attempts < ?)",
                arguments: [Self.maxAttempts]) ?? false
        }
    }

    public struct Counts: Equatable, Sendable {
        public var pending: Int
        /// Items the server rejected `maxAttempts` times; they wait for a new change.
        public var parked: Int
        public var lastParkedError: String?

        public init(pending: Int, parked: Int, lastParkedError: String?) {
            self.pending = pending
            self.parked = parked
            self.lastParkedError = lastParkedError
        }
    }

    public func counts() async throws -> Counts {
        try await db.reader.read { d in
            let pending = try Int.fetchOne(
                d, sql: "SELECT COUNT(*) FROM sync_outbox WHERE pending = 1 AND attempts < ?",
                arguments: [Self.maxAttempts]) ?? 0
            let parked = try Int.fetchOne(
                d, sql: "SELECT COUNT(*) FROM sync_outbox WHERE pending = 1 AND attempts >= ?",
                arguments: [Self.maxAttempts]) ?? 0
            let error = try String.fetchOne(
                d,
                sql: """
                    SELECT lastError FROM sync_outbox WHERE pending = 1 AND attempts >= ?
                    ORDER BY changedAtMs DESC LIMIT 1
                    """,
                arguments: [Self.maxAttempts])
            return Counts(pending: pending, parked: parked, lastParkedError: error)
        }
    }

    public func row(kind: ArchiveEntityKind, id: String) async throws -> ArchiveOutboxRow? {
        try await db.reader.read { d in
            try Row.fetchOne(
                d, sql: "SELECT * FROM sync_outbox WHERE kind = ? AND entityId = ?",
                arguments: [kind.rawValue, id]
            ).flatMap(ArchiveOutboxRow.from)
        }
    }

    /// Records what each item of a batch is being sent as, so the answer can be applied after a
    /// relaunch. Only the version still current is touched.
    public func markInFlight(_ items: [ArchiveSentItem]) async throws {
        guard !items.isEmpty else { return }
        try await db.writer.write { d in
            for item in items {
                try d.execute(
                    sql: """
                        UPDATE sync_outbox SET inflightVersion = ?, inflightHash = ?, inflightKey = ?
                        WHERE kind = ? AND entityId = ? AND version = ?
                        """,
                    arguments: [
                        item.key.version, item.hash, item.pieceKey, item.key.kind.rawValue,
                        item.key.entityId, item.key.version,
                    ])
            }
        }
    }

    /// The server holds these versions (accepted, or ignored as no newer than what it had).
    /// Clears each row that is STILL at that version — a change made since stays pending — and
    /// remembers what was sent. A second delivery of the same answer finds nothing to clear.
    /// Returns how many rows were cleared.
    @discardableResult
    public func acknowledge(_ keys: [ArchiveItemKey]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        return try await db.writer.write { d in
            var cleared = 0
            for key in keys {
                try d.execute(
                    sql: """
                        UPDATE sync_outbox SET pending = 0, attempts = 0, lastError = NULL,
                            sentVersion = version,
                            sentHash = CASE WHEN inflightVersion = version
                                THEN inflightHash ELSE sentHash END,
                            sentKey = CASE WHEN inflightVersion = version
                                THEN inflightKey ELSE sentKey END,
                            inflightVersion = NULL, inflightHash = NULL, inflightKey = NULL
                        WHERE kind = ? AND entityId = ? AND version = ? AND pending = 1
                        """,
                    arguments: [key.kind.rawValue, key.entityId, key.version])
                cleared += d.changesCount
            }
            return cleared
        }
    }

    /// The payload built for this version is what the server already has (same hash), or the
    /// entity has nothing new to say: cleared without sending. `pieceKey` is recorded when
    /// given, so a later tail comparison reads from what was decided here.
    public func markUnchanged(
        _ key: ArchiveItemKey, hash: String? = nil, pieceKey: String? = nil
    ) async throws {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    UPDATE sync_outbox SET pending = 0, attempts = 0, lastError = NULL,
                        sentHash = COALESCE(?, sentHash), sentKey = COALESCE(?, sentKey)
                    WHERE kind = ? AND entityId = ? AND version = ? AND pending = 1
                    """,
                arguments: [hash, pieceKey, key.kind.rawValue, key.entityId, key.version])
        }
    }

    /// The server refused an item. It stays pending and counts an attempt; after
    /// `maxAttempts` it is parked until the entity changes again. Returns whether it parked.
    @discardableResult
    public func reject(kind: ArchiveEntityKind, id: String, reason: String) async throws -> Bool {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    UPDATE sync_outbox SET attempts = attempts + 1, lastError = ?
                    WHERE kind = ? AND entityId = ? AND pending = 1
                    """,
                arguments: [String(reason.prefix(300)), kind.rawValue, id])
            let attempts = try Int.fetchOne(
                d, sql: "SELECT attempts FROM sync_outbox WHERE kind = ? AND entityId = ?",
                arguments: [kind.rawValue, id]) ?? 0
            return attempts >= Self.maxAttempts
        }
    }

    // MARK: - The sharing scope (`sync-protocol.md` §5)

    /// This version is outside the sharing scope: the phone did not send it, or the server
    /// answered `outsideScope` (not stored, not recorded). Cleared like an answered row, but with
    /// nothing remembered as sent, so a later change, or the scope widening over it, sends it as
    /// new. Only the version still current is touched.
    public func markOutsideScope(_ key: ArchiveItemKey) async throws {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    UPDATE sync_outbox SET pending = 0, attempts = 0, lastError = NULL,
                        sentVersion = NULL, sentHash = NULL, sentKey = NULL,
                        inflightVersion = NULL, inflightHash = NULL, inflightKey = NULL
                    WHERE kind = ? AND entityId = ? AND version = ? AND pending = 1
                    """,
                arguments: [key.kind.rawValue, key.entityId, key.version])
        }
    }

    /// The scope widened over `[fromMs, toMs)` (days `[fromDay, toDay)`): everything dated in it
    /// is marked to be sent again, with what was sent before forgotten — the server removed it
    /// (and forgot its versions) or never stored it, so a payload that "has not changed" still
    /// has to go. Dated as the server dates it (`ArchiveScopeGate`). Returns how many rows it
    /// marked.
    @discardableResult
    public func markForResend(
        fromMs: Int64?, toMs: Int64, fromDay: String?, toDay: String
    ) async throws -> Int {
        try await db.writer.write { d in
            guard try Self.isActive(d) else { return 0 }
            let low = fromMs ?? Int64.min
            var marked: [(ArchiveEntityKind, String)] = []
            var days = Set<String>()
            for row in try Row.fetchAll(
                d,
                sql: "SELECT id, startMs, endMs, timezone FROM conversations WHERE startMs >= ? AND startMs < ?",
                arguments: [low, toMs])
            {
                let id: String = row["id"]
                marked.append((.conversation, id))
                marked.append((.transcript, id))
                let start: Int64 = row["startMs"]
                days.formUnion(
                    ConversationQueries.dateKeys(
                        startMs: start, endMs: row["endMs"] ?? start, timeZoneID: row["timezone"]))
            }
            for id in try String.fetchAll(
                d,
                sql: """
                    SELECT n.id FROM notes n LEFT JOIN conversations c ON c.id = n.conversationId
                    WHERE COALESCE(c.startMs, n.createdAtMs) >= ? AND COALESCE(c.startMs, n.createdAtMs) < ?
                    """,
                arguments: [low, toMs])
            {
                marked.append((.note, id))
            }
            for id in try String.fetchAll(
                d,
                sql: """
                    SELECT id FROM follow_ups WHERE COALESCE(sourceWallStartMs, createdAtMs) >= ?
                    AND COALESCE(sourceWallStartMs, createdAtMs) < ?
                    """,
                arguments: [low, toMs])
            {
                marked.append((.followUp, id))
            }
            func inDays(_ day: String) -> Bool { day >= (fromDay ?? "") && day < toDay }
            for day in try String.fetchAll(d, sql: "SELECT dateKey FROM recaps") where inDays(day) {
                marked.append((.recap, day))
            }
            for day in days.sorted() where inDays(day) { marked.append((.coverage, day)) }
            for key in try String.fetchAll(
                d, sql: "SELECT periodKey FROM period_briefs WHERE text IS NOT NULL")
            {
                guard let last = Self.lastDay(ofPeriod: key), inDays(last) else { continue }
                marked.append((.brief, key))
            }
            for (kind, id) in marked {
                try Self.enqueue(d, kind: kind, id: id, op: .upsert)
                try d.execute(
                    sql: """
                        UPDATE sync_outbox SET sentVersion = NULL, sentHash = NULL, sentKey = NULL
                        WHERE kind = ? AND entityId = ? AND op = 'upsert'
                        """,
                    arguments: [kind.rawValue, id])
            }
            return marked.count
        }
    }

    /// A brief's last day: `week:2026-10-11` ends six days after it starts, `month:2026-10` on
    /// the month's last day. What the scope dates a brief by.
    public static func lastDay(ofPeriod key: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func string(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        if key.hasPrefix("week:") {
            let parts = key.dropFirst("week:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                let start = calendar.date(
                    from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                let end = calendar.date(byAdding: .day, value: 6, to: start)
            else { return nil }
            return string(end)
        }
        if key.hasPrefix("month:") {
            let parts = key.dropFirst("month:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2,
                let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
                let next = calendar.date(byAdding: .month, value: 1, to: start),
                let end = calendar.date(byAdding: .day, value: -1, to: next)
            else { return nil }
            return string(end)
        }
        return nil
    }

    /// Turns a pending upsert of something that no longer exists locally into a delete. Only
    /// reached when a row vanished without its delete trigger (a table rebuilt by hand).
    public func convertToDelete(_ key: ArchiveItemKey) async throws {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    UPDATE sync_outbox SET op = 'delete'
                    WHERE kind = ? AND entityId = ? AND version = ? AND op = 'upsert'
                    """,
                arguments: [key.kind.rawValue, key.entityId, key.version])
        }
    }
}

// MARK: - The grouping's half

/// What `ConversationGrouper.apply` marks: the conversations whose stored rows changed (and
/// their transcripts and days), the ones that went away, and the ones whose provisional flag
/// flipped without any stored row changing.
///
/// The live conversation's extent creeping forward is not a change here, exactly as it is not
/// one to the AI stages (`ApplyOutcome.structureChanged`): its end is a guess that moves every
/// pass while the watch records, and it is sent again whenever anything real about it changes
/// — a closed recording, a title, the moment it closes.
enum ArchiveOutboxGrouping {
    typealias Image = [[String?]]

    static func note(
        stored: Image, next: Image, conversations: [GroupedConversation], in db: Database
    ) throws {
        guard try ArchiveOutbox.isActive(db) else { return }
        let provisionalNow = Set(conversations.filter(\.isProvisional).map(\.id))
        let provisionalSent = Set(
            try String.fetchAll(
                db,
                sql: "SELECT entityId FROM sync_outbox WHERE kind = 'conversation' AND hint = 'p1'"))
        var marked = Set<String>()
        func mark(_ conversation: GroupedConversation) throws {
            guard marked.insert(conversation.id).inserted else { return }
            let hint = conversation.isProvisional ? "p1" : "p0"
            try ArchiveOutbox.enqueue(
                db, kind: .conversation, id: conversation.id, op: .upsert, hint: hint)
            try ArchiveOutbox.enqueue(db, kind: .transcript, id: conversation.id, op: .upsert)
            for day in ConversationQueries.dateKeys(
                startMs: conversation.startMs, endMs: conversation.endMs,
                timeZoneID: conversation.timeZoneID)
            {
                try ArchiveOutbox.enqueue(db, kind: .coverage, id: day, op: .upsert)
            }
        }
        let byId = Dictionary(
            conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if stored != next {
            let before = grouped(stored)
            let after = grouped(next)
            for (id, rows) in after {
                guard let conversation = byId[id] else { continue }
                guard let old = before[id] else {
                    try mark(conversation)
                    continue
                }
                if old == rows { continue }
                // Only the live conversation's extent moved: not news.
                if conversation.isLive, extentless(old) == extentless(rows) { continue }
                try mark(conversation)
            }
            for (id, rows) in before where after[id] == nil {
                // Gone: re-cut away, or its audio deleted. A delete, unless retention already
                // marked it expired (which the enqueue keeps).
                try ArchiveOutbox.enqueue(db, kind: .conversation, id: id, op: .delete)
                try ArchiveOutbox.enqueue(db, kind: .transcript, id: id, op: .delete)
                if let head = rows.first, head.count > 4, let startText = head[2],
                    let start = Int64(startText), let zone = head[4]
                {
                    let end = head[3].flatMap { Int64($0) } ?? start
                    for day in ConversationQueries.dateKeys(
                        startMs: start, endMs: end, timeZoneID: zone)
                    {
                        try ArchiveOutbox.enqueue(db, kind: .coverage, id: day, op: .upsert)
                    }
                }
            }
        }
        // A provisional flag that flipped with nothing else changed.
        for id in provisionalNow.symmetricDifference(provisionalSent) {
            guard let conversation = byId[id] else { continue }
            try mark(conversation)
        }
    }

    /// Image rows by conversation id (the second column of both row shapes).
    private static func grouped(_ image: Image) -> [String: Image] {
        var out: [String: Image] = [:]
        for row in image {
            guard row.count > 1, let id = row[1] else { continue }
            out[id, default: []].append(row)
        }
        return out
    }

    /// The rows with the conversation's start and end blanked.
    private static func extentless(_ rows: Image) -> Image {
        rows.map { row in
            guard row.first == "c", row.count > 3 else { return row }
            var r = row
            r[2] = nil
            r[3] = nil
            return r
        }
    }
}
