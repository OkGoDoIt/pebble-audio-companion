import Foundation
import GRDB

/// The app's SQLite database, living in the App Group container so widgets and intents can
/// read it (plan Part 6.5 / 6.8). Tables split into AUTHORITATIVE (user-authored — tag edits,
/// follow-up done state, ask history, notes, people, pause intervals, custom templates) and
/// DERIVED (rebuildable from segment files + re-run AI — conversations, annotations, recaps,
/// coverage, transcription queue, search index). A rebuild-on-corruption path may only drop
/// the derived set.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public static let appGroupIdentifier = "group.dev.audiocompanion"

    /// Resolves the database URL inside the App Group container (falls back to Application
    /// Support when the group is unavailable, e.g. in unit tests on macOS).
    public static func defaultDatabaseURL() throws -> URL {
        let base: URL
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            base = group
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        }
        let dir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("companion.sqlite")
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        let db = AppDatabase(writer: pool)
        try db.migrate()
        return db
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue()
        let db = AppDatabase(writer: queue)
        try db.migrate()
        return db
    }

    public var reader: any DatabaseReader { writer }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // ── Authoritative ────────────────────────────────────────────────
            try db.create(table: "tags") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique(onConflict: .replace)
            }
            try db.create(table: "conversation_tags") { t in
                t.column("conversationId", .text).notNull()
                t.column("tagId", .text).notNull().references("tags", onDelete: .cascade)
                t.column("source", .text).notNull() // ai | user
                t.primaryKey(["conversationId", "tagId"])
            }
            try db.create(table: "follow_ups") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("sourceConversationId", .text)
                t.column("sourceSegmentId", .text)
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(table: "ask_history") { t in
                t.column("id", .text).primaryKey()
                t.column("question", .text).notNull()
                t.column("answerText", .text).notNull()
                t.column("citations", .text).notNull() // JSON [{segmentId, number}]
                t.column("scopeDescription", .text).notNull()
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull()
                t.column("templateId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("citations", .text).notNull() // JSON
                t.column("provider", .text)
                t.column("model", .text)
                t.column("createdAtMs", .integer).notNull()
                t.column("editedAtMs", .integer)
            }
            try db.create(table: "people") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
            }
            try db.create(table: "speaker_assignments") { t in
                t.column("conversationId", .text).notNull()
                t.column("label", .text).notNull()
                t.column("personId", .text).notNull().references("people", onDelete: .cascade)
                t.primaryKey(["conversationId", "label"])
            }
            try db.create(table: "pause_intervals") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer) // null while a pause is ongoing
                t.column("source", .text).notNull() // statusCard | liveScreen | intent
            }
            try db.create(table: "custom_templates") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("createdAtMs", .integer).notNull()
            }

            // ── Derived (rebuildable) ────────────────────────────────────────
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer)
                t.column("timezone", .text).notNull()
                t.column("state", .text).notNull() // live | closed
            }
            try db.create(table: "conversation_segments") { t in
                t.column("conversationId", .text).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("segmentId", .text).notNull().unique()
                t.column("ordinal", .integer).notNull()
                t.primaryKey(["conversationId", "ordinal"])
            }
            try db.create(table: "annotations") { t in
                t.column("conversationId", .text).primaryKey()
                t.column("title", .text)
                t.column("summary", .text)
                t.column("tagsJson", .text) // AI-proposed tags before user adoption
                t.column("isFinal", .boolean).notNull().defaults(to: false)
                t.column("sourceCharCount", .integer).notNull().defaults(to: 0)
                t.column("finalAttempts", .integer).notNull().defaults(to: 0)
                t.column("updatedAtMs", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "recaps") { t in
                t.column("dateKey", .text).primaryKey() // YYYY-MM-DD logical day
                t.column("text", .text).notNull()
                t.column("segmentIds", .text).notNull() // JSON array
                t.column("provider", .text)
                t.column("model", .text)
                t.column("updatedAtMs", .integer).notNull()
            }
            try db.create(table: "coverage_days") { t in
                t.column("dateKey", .text).primaryKey()
                t.column("spans", .text).notNull() // JSON [{kind, startMs, endMs}]
                t.column("updatedAtMs", .integer).notNull()
            }
            try db.create(table: "transcription_tasks") { t in
                t.column("segmentId", .text).primaryKey()
                t.column("state", .text).notNull() // Pending|Running|Uploading|Complete|NoSpeech|Failed|Disabled
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("retryable", .boolean).notNull().defaults(to: true)
                t.column("lastError", .text)
                t.column("createdAtMs", .integer).notNull()
                t.column("updatedAtMs", .integer).notNull()
                t.column("modeUsed", .text)
                t.column("providerId", .text)
                t.column("modelUsed", .text)
            }
            try db.create(virtualTable: "search_fts", using: FTS5()) { t in
                t.column("entityId")
                t.column("kind") // conversation | note | recap | followup
                t.column("title")
                t.column("body") // transcript text IS indexed (fixes D7)
                t.column("tags")
            }
        }
        // The segment's OWN durable transcription state, mirrored from its meta at every
        // regroup. `transcription_tasks` is a queue detail — rows are pruned, and segments
        // imported with a transcript already on disk never had one — so the queue alone
        // reported an entire migrated library as "captured · waiting to transcribe" while
        // showing its transcript. The transcript is the truth; this column carries it into
        // the aggregation. Derived, like the rest of the grouping.
        migrator.registerMigration("v2-segment-transcription-state") { db in
            try db.alter(table: "conversation_segments") { t in
                t.add(column: "transcriptionState", .text)
            }
        }
        // Ask is a conversation, not a series of unrelated one-shot questions: the turns of
        // one Ask thread share a threadId so a follow-up can be answered with — and reopened
        // alongside — everything asked before it. Rows written before this each stood alone,
        // so each becomes a thread of one.
        migrator.registerMigration("v3-ask-history-threads") { db in
            try db.alter(table: "ask_history") { t in
                t.add(column: "threadId", .text)
            }
            try db.execute(sql: "UPDATE ask_history SET threadId = id WHERE threadId IS NULL")
        }
        try migrator.migrate(writer)
    }
}
