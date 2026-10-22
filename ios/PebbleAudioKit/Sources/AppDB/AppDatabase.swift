import Foundation
import GRDB

/// The app's SQLite database. Tables split into AUTHORITATIVE (user-authored — tag edits,
/// follow-up done state, ask history, notes, people, pause intervals, custom templates) and
/// DERIVED (rebuildable from segment files + re-run AI — conversations, annotations, recaps,
/// coverage, transcription queue, search index). A rebuild-on-corruption path may only drop
/// the derived set.
///
/// It lives in the APP'S OWN container, next to the segment store — not in the App Group. It
/// used to (plan Part 6.5 / 6.8, "so widgets and intents can read it"), but nothing outside this
/// process ever opened it: the widget extension links nothing from the kit and renders the
/// coverage snapshot JSON, and every App Intent runs in the app's process. What the shared
/// location DID do was expose the app to `0xDEAD10CC` — iOS kills, with that code, any app it
/// suspends while it holds a lock on a file in a shared container, and a `DatabasePool` in WAL
/// mode holds POSIX locks for the length of every write. The regroup pass was caught exactly so
/// on 2026-09-18 09:58 (crash report: thread on `GRDB.DatabasePool.writer` inside
/// `ConversationGrouper.rebuildDetailed`, SIGKILL, RUNNINGBOARD 0xdead10cc) the moment residency
/// lapsed under a pipeline pass. In the app's own container a lock held across suspension is
/// simply held; the kill rule does not apply. `relocateLegacyDatabaseIfNeeded` brings an existing
/// database across once.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public static let appGroupIdentifier = "group.dev.audiocompanion"

    /// Where the database lives now: `<Application Support>/audio-companion/db/companion.sqlite`,
    /// under the same root the segment store, transcripts and flight recorder use — so the
    /// deploy script's backup of that directory covers it too, which the App Group copy never
    /// was. Creates the directory.
    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("audio-companion", isDirectory: true)
        let dir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("companion.sqlite")
    }

    /// Where it lived until 2026-09-19: `<App Group>/db/companion.sqlite`. Nil when this
    /// process has no App Group (unit tests on macOS).
    public static func legacyAppGroupDatabaseURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.appendingPathComponent("db", isDirectory: true).appendingPathComponent("companion.sqlite")
    }

    public enum Relocation: Equatable, Sendable {
        /// Nothing at the old location, or the new one already exists (a previous launch did it).
        case notNeeded
        /// The database was moved across, with `walFrames` WAL frames folded into it first.
        case moved(walFrames: Int)
    }

    /// One-time move of the database from the App Group container to `to`, the app's own
    /// container. Call it BEFORE `open(at:)`, which would otherwise create an empty database at
    /// the new path and leave the real one behind.
    ///
    /// Safe against dying half way: the old database is opened and fully checkpointed
    /// (`TRUNCATE`, so its `-wal` is empty) and closed before the single `rename` of the main
    /// file, which is atomic within the container volume. A process killed before the rename
    /// leaves everything where it was and this runs again next launch; killed after it, the only
    /// leftovers are an empty `-wal`/`-shm` pair that the next launch removes. A database already
    /// present at `to` is never overwritten, whatever remains at `from`.
    @discardableResult
    public static func relocateLegacyDatabaseIfNeeded(
        from legacy: URL? = legacyAppGroupDatabaseURL(),
        to destination: URL
    ) throws -> Relocation {
        let fm = FileManager.default
        guard let legacy else { return .notNeeded }
        if fm.fileExists(atPath: destination.path) {
            // A moved-away main file can leave its (empty) sidecars behind; a main file still
            // there is left alone, sidecars included, rather than half-deleted.
            if !fm.fileExists(atPath: legacy.path) { removeSidecars(of: legacy) }
            return .notNeeded
        }
        guard fm.fileExists(atPath: legacy.path) else { return .notNeeded }

        // Fold the WAL into the main file so the rename carries everything. Opening it here also
        // recovers a WAL left by a process that died mid-write, exactly as an ordinary open would.
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: legacy.path, configuration: config)
        let frames = try pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate).walFrameCount
        }
        try pool.close()

        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: legacy, to: destination)
        removeSidecars(of: legacy)
        return .moved(walFrames: frames)
    }

    /// The `-wal` and `-shm` files SQLite keeps beside a WAL-mode database. Only ever called for
    /// a main file that has been moved away or superseded, so what they hold is empty.
    private static func removeSidecars(of url: URL) {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // `observesSuspensionNotifications` stays off on purpose. GRDB's suspension makes every
        // write throw SQLITE_INTERRUPT/SQLITE_ABORT while the app is backgrounded, and this app's
        // whole purpose is to keep writing while backgrounded. It was only ever a mitigation for
        // 0xDEAD10CC, which applies to shared containers; the database no longer lives in one
        // (see the type comment).
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
            // Unused: nothing ever wrote it, and since 2026-10-21 nothing reads it. Not dropped,
            // because a build from before that reads it in its library query and the
            // side-by-side install shares this database.
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
        // How much of the asked-for range an answer was actually built from. Null on rows
        // written before this existed — those were produced by the retrieval that read twelve
        // recordings regardless of scope, so their coverage is genuinely unknown and the UI
        // says nothing rather than guessing.
        migrator.registerMigration("v4-ask-history-coverage") { db in
            try db.alter(table: "ask_history") { t in
                t.add(column: "conversationsRead", .integer)
                t.add(column: "conversationsInScope", .integer)
            }
        }
        // Follow-ups grow up (session 105). The v1 table held a text blob and a done flag,
        // which is why the feature could not say where an item came from, when it was due, or
        // whether anyone still cared. Every column here is additive and nullable-or-defaulted,
        // so an existing AUTHORITATIVE table keeps every row and every tick.
        //
        // `origin` replaces the old "does the id contain -action-" sniffing. That test was a
        // guess about a string; this is a fact about a row, and it is what lets the UI say
        // "you added this" and lets re-extraction leave hand-written items alone.
        migrator.registerMigration("v5-follow-up-detail") { db in
            try db.alter(table: "follow_ups") { t in
                t.add(column: "quote", .text)
                t.add(column: "why", .text)
                t.add(column: "dueAtMs", .integer)
                t.add(column: "priority", .integer).notNull().defaults(to: 1)
                t.add(column: "sourceStartMs", .integer)
                t.add(column: "sourceEndMs", .integer)
                t.add(column: "completedAtMs", .integer)
                t.add(column: "archivedAtMs", .integer)
                t.add(column: "snoozedUntilMs", .integer)
                t.add(column: "editedAtMs", .integer)
                t.add(column: "origin", .text).notNull().defaults(to: "ai")
            }
            try db.execute(
                sql: """
                    UPDATE follow_ups SET origin =
                        CASE WHEN id LIKE '%-action-%' THEN 'ai' ELSE 'user' END
                    """)
            // A ticked row written before this has no completion time. Its creation time is
            // the only honest stand-in, and leaving it NULL would drop every already-done
            // item out of the Completed section entirely.
            try db.execute(
                sql: "UPDATE follow_ups SET completedAtMs = createdAtMs WHERE done = 1")
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS follow_ups_open
                        ON follow_ups(done, archivedAtMs, createdAtMs)
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS follow_ups_conversation
                        ON follow_ups(sourceConversationId)
                    """)
        }
        // Extraction now proposes; a second pass decides. Candidates land here first so a
        // conversation's raw proposals can be weighed against every other conversation's —
        // which is the only place duplicates, supersessions and "this one matters more" are
        // visible at all. DERIVED: dropping the table costs a re-extraction, never a row the
        // user has seen.
        migrator.registerMigration("v6-follow-up-candidates") { db in
            try db.create(table: "follow_up_candidates") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull()
                t.column("segmentId", .text)
                t.column("task", .text).notNull()
                t.column("quote", .text)
                t.column("why", .text)
                t.column("confidence", .text)
                t.column("dueAtMs", .integer)
                t.column("startMs", .integer)
                t.column("endMs", .integer)
                t.column("createdAtMs", .integer).notNull()
                /// pending | kept | dropped | merged
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("decidedAtMs", .integer)
                t.column("reason", .text)
            }
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS follow_up_candidates_state
                        ON follow_up_candidates(state, createdAtMs)
                    """)
        }
        // Every follow-up on the list right now came out of the extractor this release
        // replaces, and reads like it: "Water the plants on Sunday.. Owner: Roger" from a
        // visitor talking about their own laptop, twenty rows of product feedback dictated to
        // a coding assistant, items from conversations three weeks old. Carrying them forward
        // would mean the new list is judged on the old one's output.
        //
        // So they are FILED AWAY, not deleted — they are still under "Filed away", still
        // restorable, and anything the person had already ticked keeps its tick. Clearing the
        // extraction bookkeeping lets recent conversations be read again by the new pass;
        // conversations outside its freshness window settle for free without a call.
        migrator.registerMigration("v7-refresh-follow-ups") { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups
                    SET archivedAtMs = COALESCE(archivedAtMs, createdAtMs)
                    WHERE origin = 'ai' AND done = 0
                    """)
            try db.execute(sql: "DROP TABLE IF EXISTS follow_up_extractions")
        }
        // Two things the first cut of this feature could not express, both found by review.
        //
        // `touchedAtMs` is the age rule's memory of the person. Un-archiving wrote only
        // `archivedAtMs = NULL`, which left the row in exactly the state `archiveStale` looks
        // for — so Restore was a no-op: the item came back and the next pipeline pass, thirty
        // seconds later, filed it away again. Any deliberate act on a row now stamps this, and
        // a clock never touches a row a person has.
        //
        // `attempts` gives curation the budget extraction already had. Without it a batch the
        // provider could not answer stayed pending, and `pending(limit:)` is deterministic, so
        // the identical twelve candidates were re-sent every five minutes forever.
        // `recordedAtMs` is when the CONVERSATION happened, which is not when extraction ran —
        // curation was being told a Friday commitment was recorded on Monday and dating it
        // from there.
        migrator.registerMigration("v8-follow-up-bookkeeping") { db in
            try db.alter(table: "follow_ups") { t in
                t.add(column: "touchedAtMs", .integer)
            }
            try db.alter(table: "follow_up_candidates") { t in
                t.add(column: "attempts", .integer).notNull().defaults(to: 0)
                t.add(column: "recordedAtMs", .integer)
            }
            // Rows that reached the list before this existed have been seen and acted on by
            // whoever kept them; treat a hand-written or edited one as touched so the age rule
            // cannot claim it retroactively.
            try db.execute(
                sql: """
                    UPDATE follow_ups SET touchedAtMs = COALESCE(editedAtMs, createdAtMs)
                    WHERE origin = 'user' OR editedAtMs IS NOT NULL
                    """)
        }
        // "Today so far" is a glance, and on a full day the digest stopped being one — it grew
        // taller than the coverage strip, the follow-ups and the conversations put together.
        // The digest itself is unchanged (the pushed recap detail and the search index still
        // hold it whole); these two columns carry a SECOND AI pass that shortens it for the
        // card. `shortOfHash` is the fingerprint of the digest the short form was made from, so
        // the pass runs once per digest and a regenerated digest invalidates its own summary
        // instead of keeping a stale one. Both nullable: no condensation is the normal state.
        migrator.registerMigration("v9-recap-condensation") { db in
            try db.alter(table: "recaps") { t in
                t.add(column: "shortText", .text)
                t.add(column: "shortOfHash", .text)
            }
        }
        // Conversation boundaries (see `ConversationBoundaries.swift`).
        //
        // `boundary_overrides` is AUTHORITATIVE — it is the user saying "these two are one
        // conversation" or "split here", and it must survive every regroup, every retention
        // sweep and a derived-table rebuild. Keyed by the segment that FOLLOWS the join because
        // segment ids are stable while conversation ids move whenever a split does.
        //
        // `boundary_reviews` is DERIVED: the optional semantic layer's verdict per candidate
        // join, cached so one AI call is not repeated on every pass. Losing it costs one call.
        //
        // `conversations.startReason` records WHY a conversation starts where it does, so an
        // automatic split can be explained rather than just happening.
        migrator.registerMigration("v10-conversation-boundaries") { db in
            try db.create(table: "boundary_overrides") { t in
                t.column("segmentId", .text).primaryKey()
                t.column("decision", .text).notNull()  // split | join
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(table: "boundary_reviews") { t in
                t.column("segmentId", .text).primaryKey()
                t.column("isBoundary", .boolean).notNull()
                t.column("quietMs", .integer).notNull()
                t.column("reason", .text)
                t.column("provider", .text)
                t.column("model", .text)
                t.column("createdAtMs", .integer).notNull()
            }
            try db.alter(table: "conversations") { t in
                t.add(column: "startReason", .text)
            }
        }
        // Every annotation ever generated carried 2-4 AI tags in `annotations.tagsJson`, and
        // nothing ever turned them into rows: the Library chip row, the tag filter, the row and
        // detail pills and the Search "Tags" section all read `conversation_tags`, which only
        // the Tag Editor wrote. So the feature looked absent — an untagged library with no chip
        // row at all — while the tags themselves had been sitting in the database the whole
        // time. `AnnotationStore.save` adopts them from now on; this hands the existing library
        // the tags it already paid for instead of making it wait for a re-run that (for a
        // finished conversation) never comes.
        migrator.registerMigration("v11-adopt-ai-tags") { db in
            var idsByName: [String: String] = [:]  // lowercased name -> tag id
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM tags") {
                idsByName[(row["name"] as String).lowercased()] = row["id"]
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT conversationId, tagsJson FROM annotations WHERE tagsJson IS NOT NULL")
            {
                let conversationId: String = row["conversationId"]
                guard let json: String = row["tagsJson"],
                    let names = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
                else { continue }
                for name in names {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let key = trimmed.lowercased()
                    let tagId: String
                    if let existing = idsByName[key] {
                        tagId = existing
                    } else {
                        tagId = UUID().uuidString.lowercased()
                        idsByName[key] = tagId
                        try db.execute(
                            sql: "INSERT INTO tags (id, name) VALUES (?, ?)",
                            arguments: [tagId, trimmed])
                    }
                    try db.execute(
                        sql: """
                            INSERT INTO conversation_tags (conversationId, tagId, source)
                            VALUES (?, ?, 'ai')
                            ON CONFLICT(conversationId, tagId) DO NOTHING
                            """,
                        arguments: [conversationId, tagId])
                }
            }
        }
        // When curation last tried a candidate. `attempts` alone made a spent budget permanent:
        // a candidate that three curation calls failed on stayed `pending` forever, excluded
        // from every batch, with nothing that would ever pick it up again. With the time of the
        // last attempt, a spent budget RESTS for six hours and is then tried again
        // (`FollowUpCandidateStore.pending(limit:maxAttempts:retryAfterMs:nowMs:)`).
        migrator.registerMigration("v12-follow-up-candidate-retry") { db in
            try db.alter(table: "follow_up_candidates") { t in
                t.add(column: "lastAttemptAtMs", .integer)
            }
        }
        // Which model FOUND an item. Extraction runs on a stronger model than the person's own
        // choice, and falls back to their model when the key cannot use the stronger one — so
        // "which model decided this belongs on my list" has more than one answer, and the item's
        // provenance card is where a person asks it. Nullable: rows written before this, and
        // rows a person wrote, have none.
        migrator.registerMigration("v13-follow-up-model") { db in
            try db.alter(table: "follow_up_candidates") { t in
                t.add(column: "model", .text)
            }
            try db.alter(table: "follow_ups") { t in
                t.add(column: "model", .text)
            }
        }
        // History reads by time: one day's conversations and pauses, and the follow-ups whose
        // source is one of that day's recordings. None of those columns had an index, so every
        // such read scanned its whole table. Additive and self-contained (indexes only, no data
        // change), so it can be ordered against any other migration freely.
        migrator.registerMigration("v14-history-indexes") { db in
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS conversations_start ON conversations(startMs)")
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS pause_intervals_start ON pause_intervals(startMs)")
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS follow_ups_segment ON follow_ups(sourceSegmentId)")
        }
        // When a follow-up was SAID, on the wall clock, so History can put it inside the part of
        // the day it came from. `sourceStartMs`/`sourceEndMs` cannot answer that on their own:
        // they are MEDIA offsets into the segment's stored audio, and turning them into a time
        // needs the segment's sidecar (start and gap records), which is gone with the segment and
        // costs a file read per row on every History read while it exists. `createdAtMs` is when
        // extraction ran, days later for a backlog, and says nothing about when the words were
        // spoken.
        //
        // `sourceWallApproximate` is stored beside the two times rather than derived at read
        // time: it is a fact about the clock the times were computed through (its gap records did
        // not account for the recording, so the offset was left on the media clock), and it is
        // needed exactly when the segment it could be re-derived from may no longer be there.
        // All three are NULL together when the moment is unknown.
        //
        // Both tables, so curation carries the value from candidate to follow-up. Two partial
        // indexes on `follow_ups`, split on whether the time is known:
        //  - `follow_ups_wall` holds only placed rows and serves History's window read (a range
        //    on the column implies it is not NULL, so SQLite can use it). Partial on purpose: a
        //    full index also answers `sourceWallStartMs IS NULL`, and the planner then served the
        //    fill's read from it — every unplaced row in the table, archived legacy rows included.
        //  - `follow_ups_wall_unfilled` holds only rows with a located quote and no time yet,
        //    which is exactly what the one-time fill (`FollowUpWallTimeFill`) walks, so the fill
        //    costs the rows it has to fill and not the table.
        //
        // Additive and self-contained: columns and indexes only, no data change.
        migrator.registerMigration("v15-follow-up-wall-times") { db in
            for table in ["follow_ups", "follow_up_candidates"] {
                try db.alter(table: table) { t in
                    t.add(column: "sourceWallStartMs", .integer)
                    t.add(column: "sourceWallEndMs", .integer)
                    t.add(column: "sourceWallApproximate", .boolean)
                }
            }
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS follow_ups_wall ON follow_ups(sourceWallStartMs)
                        WHERE sourceWallStartMs IS NOT NULL
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS follow_ups_wall_unfilled
                        ON follow_ups(sourceSegmentId)
                        WHERE sourceWallStartMs IS NULL AND sourceStartMs IS NOT NULL
                            AND sourceSegmentId IS NOT NULL
                    """)
        }
        // What recorded audio HOLDS: conversation, or sound with no conversation in it (see
        // `AudioContentStore.swift`). `audio_content_spans` / `audio_content_segments` are
        // DERIVED from each segment's transcript and recomputed when it or the method changes;
        // `audio_content_overrides` is AUTHORITATIVE — a person's "this was a conversation" —
        // and is kept by wall-clock range so a re-transcription cannot orphan it. Independent
        // of every other table, so its place in the order does not matter to any other
        // migration (the History tab's own migrations land beside it).
        migrator.registerMigration("v14-audio-content") { db in
            try db.create(table: "audio_content_spans") { t in
                t.column("segmentId", .text).notNull()
                t.column("spanIndex", .integer).notNull()
                t.column("startMs", .integer).notNull()  // wall clock
                t.column("endMs", .integer).notNull()
                t.column("mediaStartMs", .integer).notNull()  // the segment's stored-audio clock
                t.column("mediaEndMs", .integer).notNull()
                t.column("kind", .text).notNull()  // conversation | noConversation
                t.column("descriptor", .text)
                t.column("confidence", .double).notNull()
                t.column("decidedBy", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("rowHash", .integer).notNull()
                t.column("updatedAtMs", .integer).notNull()
                t.primaryKey(["segmentId", "spanIndex"])
            }
            try db.create(
                index: "audio_content_spans_start", on: "audio_content_spans",
                columns: ["startMs"])
            try db.create(table: "audio_content_segments") { t in
                t.column("segmentId", .text).primaryKey()
                t.column("inputKey", .text).notNull()
                t.column("updatedAtMs", .integer).notNull()
            }
            try db.create(table: "audio_content_overrides") { t in
                t.column("id", .text).primaryKey()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("createdAtMs", .integer).notNull()
            }
            try db.create(
                index: "audio_content_overrides_start", on: "audio_content_overrides",
                columns: ["startMs"])
        }
        // An AI reading of each transcribed segment, minute by minute: what the words ARE
        // (talk, lyrics, TV, an announcement, a transcriber loop). DERIVED — it costs one call
        // per segment to rebuild — and keyed by the transcript version and prompt version it
        // answered, so a re-transcription or a better prompt asks again. See
        // `AudioContentJudge` and `docs/audio-content-classification.md`.
        migrator.registerMigration("audio-content-judgements-v1") { db in
            try db.create(table: "audio_content_judgements") { t in
                t.column("segmentId", .text).primaryKey()
                t.column("inputKey", .text).notNull()
                t.column("minutesJson", .text)  // [{"m":0,"kind":"music","confidence":0.9}]
                t.column("provider", .text)
                t.column("model", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("nextAttemptAtMs", .integer)
                t.column("judgedAtMs", .integer)
            }
        }
        // Conversations become topic-sized (see `ConversationUnits.swift`): a conversation owns a
        // RANGE of a segment's stored audio, so one segment can belong to two conversations.
        //
        // `conversation_segments` is derived, but it is rebuilt in place rather than dropped so
        // the library does not read as empty between this migration and the first regroup. The
        // only changes are the two nullable range columns (nil = the whole segment, which is
        // what every existing row means) and the UNIQUE on `segmentId` becoming a plain index.
        //
        // `conversation_cuts` is where the segmenter's SETTLED decisions live: a cut that has
        // enough later talk behind it is written once and then held, so a conversation's id and
        // title do not move every time the recording grows. DERIVED — dropping the table costs
        // one re-segmentation. `conversation_cut_overrides` is the person's own "start a new
        // conversation here" / "these are one conversation" at a position inside a segment, and
        // is AUTHORITATIVE like `boundary_overrides` (which keeps the decisions made at a
        // segment's own start).
        migrator.registerMigration("conversation-ranges-v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE conversation_segments_v2 (
                        conversationId TEXT NOT NULL
                            REFERENCES conversations(id) ON DELETE CASCADE,
                        segmentId TEXT NOT NULL,
                        ordinal INTEGER NOT NULL,
                        transcriptionState TEXT,
                        startMediaMs INTEGER,
                        endMediaMs INTEGER,
                        PRIMARY KEY (conversationId, ordinal)
                    )
                    """)
            try db.execute(
                sql: """
                    INSERT INTO conversation_segments_v2
                        (conversationId, segmentId, ordinal, transcriptionState)
                    SELECT conversationId, segmentId, ordinal, transcriptionState
                    FROM conversation_segments
                    """)
            try db.execute(sql: "DROP TABLE conversation_segments")
            try db.execute(
                sql: "ALTER TABLE conversation_segments_v2 RENAME TO conversation_segments")
            try db.execute(
                sql: """
                    CREATE INDEX conversation_segments_segment
                    ON conversation_segments(segmentId)
                    """)
            try db.create(table: "conversation_cuts") { t in
                t.column("segmentId", .text).notNull()
                t.column("mediaMs", .integer).notNull()
                t.column("reason", .text).notNull()
                t.column("algorithm", .integer).notNull()
                t.column("createdAtMs", .integer).notNull()
                t.primaryKey(["segmentId", "mediaMs"])
            }
            try db.create(table: "conversation_cut_overrides") { t in
                t.column("segmentId", .text).notNull()
                t.column("mediaMs", .integer).notNull()
                t.column("decision", .text).notNull()  // split | join
                t.column("createdAtMs", .integer).notNull()
                // A join says "these two are one conversation", and that is a statement about
                // everything the two held, not about one instant: the span from the start of
                // the earlier one to the end of the later one, inside which nothing automatic
                // may cut again. `spanTo*` NULL means "to the end of the run".
                t.column("spanFromSegmentId", .text)
                t.column("spanFromMediaMs", .integer)
                t.column("spanToSegmentId", .text)
                t.column("spanToMediaMs", .integer)
                t.primaryKey(["segmentId", "mediaMs"])
            }
        }
        // What the AI layer needs to survive conversations being re-cut (`conversation-ranges-v1`
        // turns every conversation in an existing library into several smaller ones, and a
        // conversation's id stays with its first part).
        //
        // `annotations.sourceKey` records WHICH PIECES a title and summary were written from
        // (`ConversationSourceKey`: segment ids and ranges, never transcript text). Without it a
        // "final" annotation is final forever, and the ten minutes that inherit a ten-hour
        // conversation's id would keep its title. NULL — every row written before this — reads
        // as "written from something else", so the whole library is re-titled once.
        //
        // `annotations.titleEditedAtMs` marks a title the PERSON typed. Rename used to overwrite
        // `title` and leave no trace, so nothing could tell a typed title from a generated one;
        // regeneration now keeps a marked title and refreshes only the summary and tags.
        //
        // `follow_up_covered_segments` is every segment whose follow-ups had ALREADY been
        // extracted when the library was re-cut. `follow_up_extractions` is keyed by
        // conversation id and candidate ids embed it, so after the re-cut the worker would read
        // the whole library again and propose, under new ids, everything the person already
        // has. A conversation made only of covered segments is settled without a call instead.
        // This has to read `conversation_segments` as the previous release left it — whole
        // segments under the old ids — which `conversation-ranges-v1` preserves and the first
        // regroup after it replaces; so it must run in the same launch, before that regroup.
        // `follow_up_extractions` is created by its store rather than by a migration (and was
        // dropped by v7), so a database that has never extracted anything has no such table.
        migrator.registerMigration("annotation-source-key-v1") { db in
            try db.alter(table: "annotations") { t in
                t.add(column: "sourceKey", .text)
                t.add(column: "titleEditedAtMs", .integer)
            }
            try db.create(table: "follow_up_covered_segments") { t in
                t.column("segmentId", .text).primaryKey()
            }
            if try db.tableExists("follow_up_extractions") {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO follow_up_covered_segments (segmentId)
                        SELECT DISTINCT cs.segmentId
                        FROM conversation_segments cs
                        JOIN follow_up_extractions e ON e.conversationId = cs.conversationId
                        WHERE e.settled = 1
                        """)
            }
        }
        // History's briefs (plan 7.4). The week page listed each day under the FIRST SENTENCE of
        // its recap cut at sixty characters ("The day began with a long planning…") and the month
        // page had no week headlines at all, because nothing short had ever been written about a
        // day, a week or a month.
        //
        // `recaps.headline` / `lineSummary` are a SECOND pass over the day recap, like the
        // condensed form: a phrase naming the day and a line under it. `briefOfHash` is
        // `RecapCondenser.fingerprint` of the recap text the pass last COMPLETED against, so it
        // runs once per recap text and a regenerated recap invalidates what was made from the old
        // one. All three nullable; a stamped hash with nil fields is an attempt that produced
        // nothing usable.
        //
        // `period_briefs` holds the week and month briefs (`week:<first day>`,
        // `month:<yyyy-MM>`). DERIVED — dropping it costs one call per period. `text` is nullable
        // for the same reason as the day's fields; `sourceHash` is what the brief was made from,
        // NULL until an attempt completes. `attempts` / `nextAttemptAtMs` / `lastError` are the
        // failure backoff, and `lastError` holds the classified kind only, never a provider's
        // message.
        migrator.registerMigration("v16-history-briefs") { db in
            try db.alter(table: "recaps") { t in
                t.add(column: "headline", .text)
                t.add(column: "lineSummary", .text)
                t.add(column: "briefOfHash", .text)
            }
            try db.create(table: "period_briefs") { t in
                t.column("periodKey", .text).primaryKey()
                t.column("kind", .text).notNull()  // week | month
                t.column("text", .text)
                t.column("headline", .text)
                t.column("lineSummary", .text)
                t.column("sourceHash", .text)
                t.column("provider", .text)
                t.column("model", .text)
                t.column("updatedAtMs", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAtMs", .integer)
                t.column("lastError", .text)
            }
        }
        // The Pebble Audio archive sync (`server/docs/sync-protocol.md`, `ArchiveOutbox.swift`).
        //
        // `sync_outbox` is one row per synced entity: its version, whether the server still
        // needs it, and what the server last accepted. DERIVED in the sense that dropping it
        // costs one full re-send (`ArchiveOutbox.markEverything`), never a byte of the library.
        // `sync_outbox_state.active` is off until a server is linked, so a phone that never links
        // records nothing. The triggers are the outbox's writers for every table a payload is
        // built from; `ConversationGrouper.apply` and `DeleteCascade` write the rest.
        //
        // `notes.origin` is new: a note an assistant wrote through the server (`assistant`) must
        // say so when it syncs back, and nothing recorded who wrote a note before. NULL is every
        // existing row, and reads as the app's own (`user`, or `ai` when a model wrote it).
        migrator.registerMigration("archive-sync-outbox-v1") { db in
            // Guarded like the triggers below: the hand-built legacy fixtures in the migration
            // tests hold only the tables their suite reads, and a table that does not exist has
            // no writes to record.
            if try db.tableExists("notes") {
                try db.alter(table: "notes") { t in
                    t.add(column: "origin", .text)
                }
            }
            try ArchiveOutbox.installSchema(db)
        }
        // A watch whose clock had not been set dated its recordings to 2010;
        // `SegmentMeta.sampleClockAnchorMs` now places them at their arrival, and everything
        // derived from the recordings follows on the next regroup. A day recap is keyed by its
        // day and written once, so the ones for those 2009/2010 days would stay, describing
        // audio that belongs to another day. Nothing real is that old.
        migrator.registerMigration("recaps-unset-watch-clock-v1") { db in
            guard try db.tableExists("recaps") else { return }
            try db.execute(sql: "DELETE FROM recaps WHERE dateKey < '2020-01-01'")
        }
        // A candidate drawn from beside a sentence in which the person asked, out loud, for a
        // reminder or a follow-up (`FollowUpRequestDetector`). Curation keeps those unless they
        // repeat something already on the list.
        migrator.registerMigration("follow-up-candidates-asked-for-v1") { db in
            guard try db.tableExists("follow_up_candidates") else { return }
            let columns = Set(try db.columns(in: "follow_up_candidates").map(\.name))
            guard !columns.contains("askedFor") else { return }
            try db.execute(
                sql: "ALTER TABLE follow_up_candidates ADD COLUMN askedFor BOOLEAN NOT NULL DEFAULT 0")
        }
        try migrator.migrate(writer)
    }
}
