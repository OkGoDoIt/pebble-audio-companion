import Foundation
import GRDB

// UI-facing stores over the AppDatabase (plan 6.5). Async APIs for mutations/fetches plus
// GRDB ValueObservation wrappers (AsyncSequence) so the UI observes the DB and never polls
// or re-reads the filesystem (anti-B17). ConversationQueries lives in its own file.
//
// `transcription_tasks` is owned by the transcription-queue port — no store here writes it.

// MARK: - Value types

public struct TagWithCount: Equatable, Sendable {
    public var id: String
    public var name: String
    public var count: Int

    public init(id: String, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

public struct ConversationTag: Equatable, Sendable {
    public var id: String
    public var name: String
    /// "ai" | "user"
    public var source: String

    public init(id: String, name: String, source: String) {
        self.id = id
        self.name = name
        self.source = source
    }
}

public struct FollowUp: Equatable, Sendable {
    public var id: String
    public var text: String
    public var done: Bool
    public var sourceConversationId: String?
    public var sourceSegmentId: String?
    public var createdAtMs: Int64

    public init(
        id: String, text: String, done: Bool, sourceConversationId: String?,
        sourceSegmentId: String?, createdAtMs: Int64
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.sourceConversationId = sourceConversationId
        self.sourceSegmentId = sourceSegmentId
        self.createdAtMs = createdAtMs
    }
}

public struct AskCitation: Codable, Equatable, Sendable {
    public var segmentId: String
    public var number: Int
    /// Absolute wall-clock bounds of the stretch this cites, when the answer was written
    /// against numbered stretches rather than whole segments. Nil for citations stored before
    /// that (and for imports), which can only be followed as far as the member segment.
    public var startMs: Int64?
    public var endMs: Int64?

    public init(segmentId: String, number: Int, startMs: Int64? = nil, endMs: Int64? = nil) {
        self.segmentId = segmentId
        self.number = number
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// One turn — a question and its answer — of an Ask conversation.
public struct AskEntry: Equatable, Sendable {
    public var id: String
    /// Every turn of one Ask conversation shares this. A turn with no explicit thread is its
    /// own thread of one (legacy single-shot rows, and the opening question of a new thread).
    public var threadId: String
    public var question: String
    public var answerText: String
    public var citations: [AskCitation]
    public var scopeDescription: String
    /// Conversations the answer was built from, and how many the scope held. Nil together on
    /// rows saved before coverage was recorded — unknown, so the UI stays silent about them.
    public var conversationsRead: Int?
    public var conversationsInScope: Int?
    public var createdAtMs: Int64

    public init(
        id: String, threadId: String? = nil, question: String, answerText: String,
        citations: [AskCitation], scopeDescription: String,
        conversationsRead: Int? = nil, conversationsInScope: Int? = nil, createdAtMs: Int64
    ) {
        self.id = id
        self.threadId = threadId ?? id
        self.question = question
        self.answerText = answerText
        self.citations = citations
        self.scopeDescription = scopeDescription
        self.conversationsRead = conversationsRead
        self.conversationsInScope = conversationsInScope
        self.createdAtMs = createdAtMs
    }

    /// True when the answer was built from less than the whole range it was asked about — the
    /// one case the answer card has to say something about, because a partial answer otherwise
    /// reads exactly like a complete one.
    public var isPartialCoverage: Bool {
        guard let conversationsRead, let conversationsInScope else { return false }
        return conversationsRead < conversationsInScope
    }
}

/// A whole Ask conversation: its turns in the order they were had.
public struct AskThread: Equatable, Sendable, Identifiable {
    public var id: String
    /// Oldest first.
    public var turns: [AskEntry]

    public init(id: String, turns: [AskEntry]) {
        self.id = id
        self.turns = turns
    }

    /// The question the thread opened with — what it is titled by in Recent.
    public var openingQuestion: String { turns.first?.question ?? "" }
    public var lastTurn: AskEntry? { turns.last }
    public var updatedAtMs: Int64 { turns.last?.createdAtMs ?? 0 }

    /// Groups rows (any order) into threads, newest-updated first, turns oldest-first.
    public static func group(_ entries: [AskEntry]) -> [AskThread] {
        var order: [String] = []
        var byThread: [String: [AskEntry]] = [:]
        for entry in entries.sorted(by: { $0.createdAtMs < $1.createdAtMs }) {
            if byThread[entry.threadId] == nil { order.append(entry.threadId) }
            byThread[entry.threadId, default: []].append(entry)
        }
        return order
            .map { AskThread(id: $0, turns: byThread[$0] ?? []) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
    }
}

public struct Note: Equatable, Sendable {
    public var id: String
    public var conversationId: String
    public var templateId: String
    public var title: String
    public var body: String
    /// Citation payload as JSON — shape owned by the Intelligence layer.
    public var citationsJson: String
    public var provider: String?
    public var model: String?
    public var createdAtMs: Int64
    public var editedAtMs: Int64?

    public init(
        id: String, conversationId: String, templateId: String, title: String, body: String,
        citationsJson: String, provider: String?, model: String?, createdAtMs: Int64,
        editedAtMs: Int64?
    ) {
        self.id = id
        self.conversationId = conversationId
        self.templateId = templateId
        self.title = title
        self.body = body
        self.citationsJson = citationsJson
        self.provider = provider
        self.model = model
        self.createdAtMs = createdAtMs
        self.editedAtMs = editedAtMs
    }
}

public struct Person: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SpeakerAssignment: Equatable, Sendable {
    public var conversationId: String
    /// Diarization label within the conversation, e.g. "Speaker 1".
    public var label: String
    public var personId: String
    public var personName: String

    public init(conversationId: String, label: String, personId: String, personName: String) {
        self.conversationId = conversationId
        self.label = label
        self.personId = personId
        self.personName = personName
    }
}

public struct PauseInterval: Equatable, Sendable {
    public var id: Int64?
    public var startMs: Int64
    /// Nil while the pause is ongoing.
    public var endMs: Int64?
    public var source: String

    public init(id: Int64? = nil, startMs: Int64, endMs: Int64? = nil, source: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.source = source
    }
}

/// Where a pause was initiated from (schema comment in AppDatabase.swift).
public enum PauseSource: String, Sendable {
    case statusCard, liveScreen, intent
}

public struct CustomTemplate: Equatable, Sendable {
    public var id: String
    public var title: String
    public var prompt: String
    public var createdAtMs: Int64

    public init(id: String, title: String, prompt: String, createdAtMs: Int64) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.createdAtMs = createdAtMs
    }
}

// MARK: - TagStore (Q10)

public struct TagStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func fetchTags(_ db: Database) throws -> [TagWithCount] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT t.id AS id, t.name AS name, COUNT(ct.conversationId) AS count
                FROM tags t
                LEFT JOIN conversation_tags ct ON ct.tagId = t.id
                GROUP BY t.id
                ORDER BY count DESC, t.name COLLATE NOCASE ASC
                """
        ).map { TagWithCount(id: $0["id"], name: $0["name"], count: $0["count"]) }
    }

    /// All tags with usage counts, most used first.
    public func listTags() async throws -> [TagWithCount] {
        try await db.reader.read { try Self.fetchTags($0) }
    }

    public func observeTags() -> AsyncValueObservation<[TagWithCount]> {
        ValueObservation.tracking { try Self.fetchTags($0) }.values(in: db.reader)
    }

    public func tags(forConversation conversationId: String) async throws -> [ConversationTag] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS id, t.name AS name, ct.source AS source
                    FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                    WHERE ct.conversationId = ?
                    ORDER BY t.name COLLATE NOCASE ASC
                    """,
                arguments: [conversationId]
            ).map { ConversationTag(id: $0["id"], name: $0["name"], source: $0["source"]) }
        }
    }

    public func observeTags(
        forConversation conversationId: String
    ) -> AsyncValueObservation<[ConversationTag]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS id, t.name AS name, ct.source AS source
                    FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                    WHERE ct.conversationId = ?
                    ORDER BY t.name COLLATE NOCASE ASC
                    """,
                arguments: [conversationId]
            ).map { ConversationTag(id: $0["id"], name: $0["name"], source: $0["source"]) }
        }.values(in: db.reader)
    }

    /// Adds a tag (find-or-create by name) to a conversation. A user re-adding an AI-proposed
    /// tag upgrades the pair's source.
    @discardableResult
    public func addTag(
        conversationId: String, name: String, source: String
    ) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await db.writer.write { db in
            let existing = try String.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [trimmed])
            let tagId: String
            if let existing {
                tagId = existing
            } else {
                tagId = UUID().uuidString.lowercased()
                try db.execute(
                    sql: "INSERT INTO tags (id, name) VALUES (?, ?)", arguments: [tagId, trimmed])
            }
            try db.execute(
                sql: """
                    INSERT INTO conversation_tags (conversationId, tagId, source)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversationId, tagId) DO UPDATE SET source = excluded.source
                    """,
                arguments: [conversationId, tagId, source]
            )
            return tagId
        }
    }

    public func removeTag(conversationId: String, tagId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM conversation_tags WHERE conversationId = ? AND tagId = ?",
                arguments: [conversationId, tagId]
            )
        }
    }

    /// RENAME IS GLOBAL (Q10): updates `tags.name`, so every conversation carrying the tag
    /// shows the new name. Renaming onto an existing tag's name merges into that tag.
    public func renameTag(tagId: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.writer.write { db in
            if let target = try String.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ? AND id <> ?",
                arguments: [trimmed, tagId]
            ) {
                // Merge: repoint pairs (keeping existing target pairs), drop the old tag.
                try db.execute(
                    sql: "UPDATE OR IGNORE conversation_tags SET tagId = ? WHERE tagId = ?",
                    arguments: [target, tagId])
                try db.execute(
                    sql: "DELETE FROM conversation_tags WHERE tagId = ?", arguments: [tagId])
                try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagId])
            } else {
                try db.execute(
                    sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [trimmed, tagId])
            }
        }
    }

    /// Recently used tags not already on this conversation (Tag Editor "Suggestions").
    public func suggestions(
        forConversation conversationId: String, limit: Int = 6
    ) async throws -> [TagWithCount] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS id, t.name AS name,
                        (SELECT COUNT(*) FROM conversation_tags c2 WHERE c2.tagId = t.id) AS count,
                        IFNULL((SELECT MAX(rowid) FROM conversation_tags c3 WHERE c3.tagId = t.id), -1)
                            AS lastUse
                    FROM tags t
                    WHERE t.id NOT IN
                        (SELECT tagId FROM conversation_tags WHERE conversationId = ?)
                    ORDER BY lastUse DESC, t.name COLLATE NOCASE ASC
                    LIMIT ?
                    """,
                arguments: [conversationId, limit]
            ).map { TagWithCount(id: $0["id"], name: $0["name"], count: $0["count"]) }
        }
    }
}

// MARK: - FollowUpStore

public struct FollowUpStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func followUp(from row: Row) -> FollowUp {
        FollowUp(
            id: row["id"], text: row["text"], done: row["done"],
            sourceConversationId: row["sourceConversationId"],
            sourceSegmentId: row["sourceSegmentId"], createdAtMs: row["createdAtMs"])
    }

    @discardableResult
    public func add(
        text: String, conversationId: String? = nil, segmentId: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> FollowUp {
        let item = FollowUp(
            id: UUID().uuidString.lowercased(), text: text, done: false,
            sourceConversationId: conversationId, sourceSegmentId: segmentId, createdAtMs: nowMs)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO follow_ups
                        (id, text, done, sourceConversationId, sourceSegmentId, createdAtMs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [item.id, item.text, item.done, conversationId, segmentId, nowMs]
            )
        }
        return item
    }

    /// Open first then done, newest first within each; `done: nil` lists everything.
    public func list(done: Bool? = nil) async throws -> [FollowUp] {
        try await db.reader.read { db in
            let rows: [Row]
            if let done {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM follow_ups WHERE done = ? ORDER BY createdAtMs DESC, id",
                    arguments: [done])
            } else {
                rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM follow_ups ORDER BY done ASC, createdAtMs DESC, id")
            }
            return rows.map(Self.followUp(from:))
        }
    }

    public func list(conversationId: String) async throws -> [FollowUp] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_ups WHERE sourceConversationId = ?
                    ORDER BY done ASC, createdAtMs DESC, id
                    """,
                arguments: [conversationId]
            ).map(Self.followUp(from:))
        }
    }

    /// Flips done state; returns the new value.
    @discardableResult
    public func toggle(id: String) async throws -> Bool {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET done = NOT done WHERE id = ?", arguments: [id])
            return try Bool.fetchOne(
                db, sql: "SELECT done FROM follow_ups WHERE id = ?", arguments: [id]) ?? false
        }
    }

    public func setDone(id: String, _ done: Bool) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET done = ? WHERE id = ?", arguments: [done, id])
        }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM follow_ups WHERE id = ?", arguments: [id])
        }
    }

    /// "See all N" — count of open follow-ups.
    public func openCount() async throws -> Int {
        try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM follow_ups WHERE done = 0") ?? 0
        }
    }

    /// Open follow-ups plus the open count, for the Today card.
    public func observeOpen(limit: Int = 50) -> AsyncValueObservation<[FollowUp]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM follow_ups WHERE done = 0 ORDER BY createdAtMs DESC, id LIMIT ?",
                arguments: [limit]
            ).map(Self.followUp(from:))
        }.values(in: db.reader)
    }
}

// MARK: - AskHistoryStore (Q18)

public struct AskHistoryStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// The sheet shows up to 5 past Ask conversations (plan 6.6); the table keeps exactly that
    /// many THREADS — trimming by row would decapitate a long conversation and leave its
    /// follow-ups behind as orphaned fragments.
    public static let maxEntries = 5

    /// Newest-thread window used by both the trim and the Recent list.
    private static let newestThreadIds = """
        SELECT threadId FROM ask_history
        GROUP BY threadId
        ORDER BY MAX(createdAtMs) DESC, MAX(rowid) DESC
        LIMIT ?
        """

    static func entry(from row: Row) throws -> AskEntry {
        let json: String = row["citations"]
        let citations =
            (try? JSONDecoder().decode([AskCitation].self, from: Data(json.utf8))) ?? []
        return AskEntry(
            id: row["id"], threadId: row["threadId"], question: row["question"],
            answerText: row["answerText"], citations: citations,
            scopeDescription: row["scopeDescription"],
            conversationsRead: row["conversationsRead"],
            conversationsInScope: row["conversationsInScope"],
            createdAtMs: row["createdAtMs"])
    }

    @discardableResult
    public func save(
        question: String, answerText: String, citations: [AskCitation],
        scopeDescription: String, conversationsRead: Int? = nil,
        conversationsInScope: Int? = nil, threadId: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> AskEntry {
        let entry = AskEntry(
            id: UUID().uuidString.lowercased(), threadId: threadId, question: question,
            answerText: answerText, citations: citations,
            scopeDescription: scopeDescription, conversationsRead: conversationsRead,
            conversationsInScope: conversationsInScope, createdAtMs: nowMs)
        let citationsJson = String(
            decoding: try JSONEncoder().encode(citations), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ask_history
                        (id, threadId, question, answerText, citations, scopeDescription,
                         conversationsRead, conversationsInScope, createdAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.id, entry.threadId, question, answerText, citationsJson,
                    scopeDescription, conversationsRead, conversationsInScope, nowMs,
                ]
            )
            // Trim to the newest maxEntries THREADS, keeping every turn of each.
            try db.execute(
                sql: "DELETE FROM ask_history WHERE threadId NOT IN (\(Self.newestThreadIds))",
                arguments: [Self.maxEntries]
            )
        }
        return entry
    }

    /// The newest `limit` Ask conversations, newest-updated first, each with all its turns.
    public func recentThreads(
        limit: Int = AskHistoryStore.maxEntries
    ) async throws -> [AskThread] {
        try await db.reader.read { db in
            AskThread.group(
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM ask_history WHERE threadId IN (\(Self.newestThreadIds))",
                    arguments: [limit]
                ).map { try Self.entry(from: $0) })
        }
    }

    public func observeRecentThreads(
        limit: Int = AskHistoryStore.maxEntries
    ) -> AsyncValueObservation<[AskThread]> {
        ValueObservation.tracking { db in
            AskThread.group(
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM ask_history WHERE threadId IN (\(Self.newestThreadIds))",
                    arguments: [limit]
                ).map { try Self.entry(from: $0) })
        }.values(in: db.reader)
    }

    /// Flat newest-turn-first view, independent of threading.
    public func recent(limit: Int = AskHistoryStore.maxEntries) async throws -> [AskEntry] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM ask_history ORDER BY createdAtMs DESC, rowid DESC LIMIT ?",
                arguments: [limit]
            ).map { try Self.entry(from: $0) }
        }
    }

    public func observeRecent(
        limit: Int = AskHistoryStore.maxEntries
    ) -> AsyncValueObservation<[AskEntry]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM ask_history ORDER BY createdAtMs DESC, rowid DESC LIMIT ?",
                arguments: [limit]
            ).map { try Self.entry(from: $0) }
        }.values(in: db.reader)
    }

    public func clear() async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM ask_history")
        }
    }
}

// MARK: - NotesStore

public struct NotesStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func note(from row: Row) -> Note {
        Note(
            id: row["id"], conversationId: row["conversationId"],
            templateId: row["templateId"], title: row["title"], body: row["body"],
            citationsJson: row["citations"], provider: row["provider"], model: row["model"],
            createdAtMs: row["createdAtMs"], editedAtMs: row["editedAtMs"])
    }

    @discardableResult
    public func create(
        conversationId: String, templateId: String, title: String, body: String,
        citationsJson: String = "[]", provider: String? = nil, model: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Note {
        let note = Note(
            id: UUID().uuidString.lowercased(), conversationId: conversationId,
            templateId: templateId, title: title, body: body, citationsJson: citationsJson,
            provider: provider, model: model, createdAtMs: nowMs, editedAtMs: nil)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes (id, conversationId, templateId, title, body, citations,
                        provider, model, createdAtMs, editedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    note.id, conversationId, templateId, title, body, citationsJson,
                    provider, model, nowMs,
                ]
            )
        }
        return note
    }

    /// Regeneration: replaces everything the model produced while KEEPING the note's id.
    ///
    /// The id is the note's identity everywhere else — the pushed route, the Spotlight entry,
    /// the citation targets. Regenerating used to create a second note and delete the first, so
    /// the open screen went on addressing a row that no longer existed: a later Edit → Save
    /// updated 0 rows and blanked the screen, and Delete Note deleted nothing while the
    /// regenerated note stayed in the library.
    ///
    /// `createdAtMs` moves to now (the provenance line reads "Generated {time}", and that time
    /// is now this text's), and `editedAtMs` clears — freshly generated text is not user-edited.
    public func replaceContent(
        id: String, title: String, body: String, citationsJson: String,
        provider: String?, model: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE notes SET title = ?, body = ?, citations = ?, provider = ?,
                        model = ?, createdAtMs = ?, editedAtMs = NULL
                    WHERE id = ?
                    """,
                arguments: [title, body, citationsJson, provider, model, nowMs, id]
            )
        }
    }

    /// Edits stamp `editedAtMs` (the UI shows edited state; B19's Cancel simply skips this).
    public func update(
        id: String, title: String, body: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE notes SET title = ?, body = ?, editedAtMs = ? WHERE id = ?",
                arguments: [title, body, nowMs, id]
            )
        }
    }

    public func get(id: String) async throws -> Note? {
        try await db.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ?", arguments: [id])
                .map(Self.note(from:))
        }
    }

    public func list(conversationId: String) async throws -> [Note] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM notes WHERE conversationId = ? ORDER BY createdAtMs DESC, id",
                arguments: [conversationId]
            ).map(Self.note(from:))
        }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
        }
    }

    public func observe(conversationId: String) -> AsyncValueObservation<[Note]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM notes WHERE conversationId = ? ORDER BY createdAtMs DESC, id",
                arguments: [conversationId]
            ).map(Self.note(from:))
        }.values(in: db.reader)
    }
}

// MARK: - PeopleStore + speaker assignments (Q17 / plan 6.3)

public struct PeopleStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    @discardableResult
    public func createPerson(name: String) async throws -> Person {
        let person = Person(id: UUID().uuidString.lowercased(), name: name)
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO people (id, name) VALUES (?, ?)",
                arguments: [person.id, person.name])
        }
        return person
    }

    /// Renaming a PERSON updates every conversation assigned to them — assignments reference
    /// the person by id, so this is one row update ("applies everywhere", plan 6.3).
    ///
    /// Renaming ONTO an existing name merges, the same way `renameTag` does (Q10). Speakers are
    /// named by free text, so a typo ("Alx") creates a second person; without the merge, fixing
    /// the typo would collide with the real "Alex" and leave two identical names in the
    /// suggestion list forever. The surviving person is the one already carrying the name, so
    /// every conversation assigned to either ends up on one record.
    public func renamePerson(id: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await db.writer.write { db in
            if let survivor = try String.fetchOne(
                db,
                sql: "SELECT id FROM people WHERE name = ? COLLATE NOCASE AND id <> ?",
                arguments: [trimmed, id]
            ) {
                // Repoint this person's assignments onto the survivor. The unique key is
                // (conversationId, label) and personId is not part of it, so this can never
                // collide — unlike the tag merge, which repoints a pair that IS the key.
                try db.execute(
                    sql: "UPDATE speaker_assignments SET personId = ? WHERE personId = ?",
                    arguments: [survivor, id])
                try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
            } else {
                try db.execute(
                    sql: "UPDATE people SET name = ? WHERE id = ?", arguments: [trimmed, id])
            }
        }
    }

    /// Cascades the person's speaker assignments away (FK on delete cascade).
    public func deletePerson(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
        }
    }

    /// People ordered for one-tap suggestions: frequency, then recency, then name.
    public func listPeople() async throws -> [(person: Person, assignmentCount: Int)] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id AS id, p.name AS name,
                        (SELECT COUNT(*) FROM speaker_assignments sa WHERE sa.personId = p.id)
                            AS count,
                        IFNULL((SELECT MAX(rowid) FROM speaker_assignments sa2
                                WHERE sa2.personId = p.id), -1) AS lastUse
                    FROM people p
                    ORDER BY count DESC, lastUse DESC, p.name COLLATE NOCASE ASC
                    """
            ).map { (Person(id: $0["id"], name: $0["name"]), $0["count"]) }
        }
    }

    /// Assigns a diarization label within a conversation to a person (upsert per label).
    public func assign(conversationId: String, label: String, personId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_assignments (conversationId, label, personId)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversationId, label) DO UPDATE SET personId = excluded.personId
                    """,
                arguments: [conversationId, label, personId]
            )
        }
    }

    public func unassign(conversationId: String, label: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM speaker_assignments WHERE conversationId = ? AND label = ?",
                arguments: [conversationId, label]
            )
        }
    }

    static func fetchAssignments(
        _ db: Database, conversationId: String
    ) throws -> [SpeakerAssignment] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT sa.conversationId AS conversationId, sa.label AS label,
                    sa.personId AS personId, p.name AS personName
                FROM speaker_assignments sa JOIN people p ON p.id = sa.personId
                WHERE sa.conversationId = ?
                ORDER BY sa.label
                """,
            arguments: [conversationId]
        ).map {
            SpeakerAssignment(
                conversationId: $0["conversationId"], label: $0["label"],
                personId: $0["personId"], personName: $0["personName"])
        }
    }

    public func assignments(forConversation conversationId: String) async throws
        -> [SpeakerAssignment]
    {
        try await db.reader.read { db in
            try Self.fetchAssignments(db, conversationId: conversationId)
        }
    }

    public func observeAssignments(
        forConversation conversationId: String
    ) -> AsyncValueObservation<[SpeakerAssignment]> {
        ValueObservation.tracking { db in
            try Self.fetchAssignments(db, conversationId: conversationId)
        }.values(in: db.reader)
    }
}

// MARK: - PauseJournal (plan 6.1)

/// The phone-side journal of capture pauses: the watch cannot report them and coverage needs
/// them. `begin` on the Pause ack, `end` on Resume; an open interval has a nil `endMs`.
public struct PauseJournal: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func interval(from row: Row) -> PauseInterval {
        PauseInterval(
            id: row["id"], startMs: row["startMs"], endMs: row["endMs"], source: row["source"])
    }

    /// Starts a pause interval. Idempotent: while an interval is already open, returns it
    /// unchanged (a second Pause ack must not stack intervals).
    @discardableResult
    public func begin(
        source: PauseSource, atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> PauseInterval {
        try await db.writer.write { db in
            if let open = try Row.fetchOne(
                db, sql: "SELECT * FROM pause_intervals WHERE endMs IS NULL ORDER BY id DESC")
            {
                return Self.interval(from: open)
            }
            try db.execute(
                sql: "INSERT INTO pause_intervals (startMs, endMs, source) VALUES (?, NULL, ?)",
                arguments: [atMs, source.rawValue]
            )
            return PauseInterval(
                id: db.lastInsertedRowID, startMs: atMs, endMs: nil, source: source.rawValue)
        }
    }

    /// Closes the open interval (no-op when none is open).
    public func end(atMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE pause_intervals SET endMs = ? WHERE endMs IS NULL",
                arguments: [atMs]
            )
        }
    }

    public func openInterval() async throws -> PauseInterval? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM pause_intervals WHERE endMs IS NULL ORDER BY id DESC"
            ).map(Self.interval(from:))
        }
    }

    /// Intervals overlapping [fromMs, toMs) — the day-coverage input. Open intervals overlap
    /// everything after their start.
    public func intervals(overlappingMs fromMs: Int64, _ toMs: Int64) async throws
        -> [PauseInterval]
    {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM pause_intervals
                    WHERE startMs < ? AND (endMs IS NULL OR endMs > ?)
                    ORDER BY startMs, id
                    """,
                arguments: [toMs, fromMs]
            ).map(Self.interval(from:))
        }
    }

    public func all() async throws -> [PauseInterval] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pause_intervals ORDER BY startMs, id")
                .map(Self.interval(from:))
        }
    }

    public func observeOpen() -> AsyncValueObservation<PauseInterval?> {
        ValueObservation.tracking { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM pause_intervals WHERE endMs IS NULL ORDER BY id DESC"
            ).map(Self.interval(from:))
        }.values(in: db.reader)
    }
}

// MARK: - CustomTemplateStore (plan 6.9)

public struct CustomTemplateStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func template(from row: Row) -> CustomTemplate {
        CustomTemplate(
            id: row["id"], title: row["title"], prompt: row["prompt"],
            createdAtMs: row["createdAtMs"])
    }

    @discardableResult
    public func add(
        title: String, prompt: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> CustomTemplate {
        let template = CustomTemplate(
            id: UUID().uuidString.lowercased(), title: title, prompt: prompt, createdAtMs: nowMs)
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO custom_templates (id, title, prompt, createdAtMs) VALUES (?, ?, ?, ?)",
                arguments: [template.id, title, prompt, nowMs]
            )
        }
        return template
    }

    /// Saved templates in creation order (they join the built-in list in Part 6.9's sheet).
    public func list() async throws -> [CustomTemplate] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM custom_templates ORDER BY createdAtMs ASC, id"
            ).map(Self.template(from:))
        }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM custom_templates WHERE id = ?", arguments: [id])
        }
    }

    public func observe() -> AsyncValueObservation<[CustomTemplate]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM custom_templates ORDER BY createdAtMs ASC, id"
            ).map(Self.template(from:))
        }.values(in: db.reader)
    }
}

// MARK: - CoverageDayStore (cache for plan 6.2)

public struct CoverageDayStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func save(
        _ coverage: DayCoverage,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        let json = String(decoding: try JSONEncoder().encode(coverage.spans), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO coverage_days (dateKey, spans, updatedAtMs) VALUES (?, ?, ?)
                    ON CONFLICT(dateKey) DO UPDATE
                        SET spans = excluded.spans, updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [coverage.dateKey, json, nowMs]
            )
        }
    }

    static func decodeSpans(_ json: String?) -> [CoverageSpan]? {
        guard let json else { return nil }
        return try? JSONDecoder().decode([CoverageSpan].self, from: Data(json.utf8))
    }

    public func load(dateKey: String) async throws -> [CoverageSpan]? {
        try await db.reader.read { db in
            Self.decodeSpans(
                try String.fetchOne(
                    db, sql: "SELECT spans FROM coverage_days WHERE dateKey = ?",
                    arguments: [dateKey]))
        }
    }

    public func observe(dateKey: String) -> AsyncValueObservation<[CoverageSpan]?> {
        ValueObservation.tracking { db in
            Self.decodeSpans(
                try String.fetchOne(
                    db, sql: "SELECT spans FROM coverage_days WHERE dateKey = ?",
                    arguments: [dateKey]))
        }.values(in: db.reader)
    }
}
