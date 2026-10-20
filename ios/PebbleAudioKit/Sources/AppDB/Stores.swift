import Foundation
import GRDB
import SegmentStore

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

/// How much a follow-up wants to be looked at. Set by the curation pass, overridable by the
/// person — never inferred from age, which is what `archivedAtMs` is for.
public enum FollowUpPriority: Int, Equatable, Sendable, CaseIterable, Codable {
    case low = 0
    case normal = 1
    case high = 2
}

/// Who put the item on the list. Replaces the old "does the id contain `-action-`" test: that
/// was a guess about a string, this is a fact about a row — and it is what stops a
/// re-extraction from touching something the person typed themselves.
public enum FollowUpOrigin: String, Equatable, Sendable, Codable {
    case ai
    case user
    /// Written by an assistant through the Pebble Audio server (an MCP write tool), and applied
    /// here from the sync request channel. Left alone by curation and the age rule, like a
    /// person's own item: someone asked for it.
    case assistant
}

/// Which slice of the list a query wants. `open` is what the app shows by default: not done,
/// not archived, and not snoozed past the given clock.
public enum FollowUpScope: Equatable, Sendable {
    case open
    case completed
    case archived
    case all
}

public struct FollowUp: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var done: Bool
    public var sourceConversationId: String?
    public var sourceSegmentId: String?
    public var createdAtMs: Int64
    /// The words in the recording that created this item, verbatim. The single most useful
    /// thing the detail screen can show: it is the difference between "the app decided this"
    /// and "you said this, here it is".
    public var quote: String?
    /// What goes wrong if it never happens, in the extractor's own words. This is the
    /// gate that killed most of the old false positives — an item nobody can name a cost for
    /// is not a follow-up — and it doubles as the honest line the detail screen shows.
    public var why: String?
    /// Resolved deadline, start of that day in the capture time zone. Nil is the common case.
    public var dueAtMs: Int64?
    public var priority: FollowUpPriority
    /// Offsets INSIDE `sourceSegmentId` where the quote was spoken, so the detail screen can
    /// open the recording at the moment rather than at the top.
    public var sourceStartMs: Int64?
    public var sourceEndMs: Int64?
    public var completedAtMs: Int64?
    /// Set when the item left the working list — by the age rule or by hand. Archived is not
    /// deleted: nothing the person may have acted on disappears without them saying so.
    public var archivedAtMs: Int64?
    public var snoozedUntilMs: Int64?
    /// Set the moment the person edits the text. Extraction never overwrites an edited row.
    public var editedAtMs: Int64?
    /// The last time the person did something deliberate to this row — restored it, un-ticked
    /// it, dated it, re-worded it, put it off. The age rule's memory of them: a clock may file
    /// away something nobody has looked at, never something somebody has answered.
    public var touchedAtMs: Int64?
    public var origin: FollowUpOrigin
    /// The model that found it, for an AI item — shown on its provenance card. Nil for an item
    /// a person wrote, and for rows written before this was recorded.
    public var model: String?
    /// When the quote was said, on the wall clock (epoch ms): `sourceStartMs`/`sourceEndMs`
    /// converted through the segment's own clock at the moment they were located, so it
    /// survives the segment's sidecar. `isApproximate` when that clock's gap records did not
    /// account for the recording. Nil when the moment is unknown — a hand-written item, an
    /// item whose quote matched no diarized turn, or a row nothing has filled yet.
    public var sourceWall: SegmentWallRange?

    public init(
        id: String, text: String, done: Bool, sourceConversationId: String?,
        sourceSegmentId: String?, createdAtMs: Int64,
        quote: String? = nil,
        why: String? = nil,
        dueAtMs: Int64? = nil,
        priority: FollowUpPriority = .normal,
        sourceStartMs: Int64? = nil,
        sourceEndMs: Int64? = nil,
        completedAtMs: Int64? = nil,
        archivedAtMs: Int64? = nil,
        snoozedUntilMs: Int64? = nil,
        editedAtMs: Int64? = nil,
        touchedAtMs: Int64? = nil,
        origin: FollowUpOrigin = .ai,
        model: String? = nil,
        sourceWall: SegmentWallRange? = nil
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.sourceConversationId = sourceConversationId
        self.sourceSegmentId = sourceSegmentId
        self.createdAtMs = createdAtMs
        self.quote = quote
        self.why = why
        self.dueAtMs = dueAtMs
        self.priority = priority
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.completedAtMs = completedAtMs
        self.archivedAtMs = archivedAtMs
        self.snoozedUntilMs = snoozedUntilMs
        self.editedAtMs = editedAtMs
        self.touchedAtMs = touchedAtMs
        self.origin = origin
        self.model = model
        self.sourceWall = sourceWall
    }

    public var isArchived: Bool { archivedAtMs != nil }

    /// Snoozed past `nowMs` — still open, deliberately out of sight until then.
    public func isSnoozed(at nowMs: Int64) -> Bool {
        guard let snoozedUntilMs else { return false }
        return snoozedUntilMs > nowMs
    }

    /// On the working list right now: not done, not archived, not snoozed.
    public func isActive(at nowMs: Int64) -> Bool {
        !done && !isArchived && !isSnoozed(at: nowMs)
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
    /// Who wrote it: `assistant` for a note an assistant created through the Pebble Audio
    /// server; nil for every note the app made itself (a person's, or a template's).
    public var origin: String?

    public init(
        id: String, conversationId: String, templateId: String, title: String, body: String,
        citationsJson: String, provider: String?, model: String?, createdAtMs: Int64,
        editedAtMs: Int64?, origin: String? = nil
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
        self.origin = origin
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
    /// The key the name is filed under: `SpeakerKey.stored`, the segment and its diarization
    /// label. Rows written before names were scoped hold the label alone, as the rename sheet
    /// filed it ("Speaker 1") or bare ("1") — see `SpeakerKey.lookupOrder`.
    public var label: String
    public var personId: String
    public var personName: String

    public init(conversationId: String, label: String, personId: String, personName: String) {
        self.conversationId = conversationId
        self.label = label
        self.personId = personId
        self.personName = personName
    }

    /// The assignment that names `key`'s speaker, if any, by `SpeakerKey.lookupOrder`.
    public static func match(
        _ key: SpeakerKey, in assignments: [SpeakerAssignment]
    ) -> SpeakerAssignment? {
        for stored in key.lookupOrder {
            if let found = assignments.first(where: { $0.label == stored }) { return found }
        }
        return nil
    }

    /// The same for a label as a transcript turn carries it: a `SpeakerKey.stored`, or any
    /// other label taken as it is.
    public static func match(
        stored label: String, in assignments: [SpeakerAssignment]
    ) -> SpeakerAssignment? {
        if let key = SpeakerKey(stored: label) { return match(key, in: assignments) }
        return assignments.first { $0.label == label }
    }
}

/// Where a speaker's name is filed: the provider's diarization label AND the segment it labels.
///
/// A provider labels ONE segment — one rotation, one transcription — at a time, so "1" in one
/// segment is not "1" in the next, and one person routinely holds a different number in each.
/// A conversation spans several segments. Names used to be filed under the bare label, so naming
/// "Speaker 1" in one segment named whoever held label 1 in every segment of the conversation,
/// and the archive sync sent that mapping on to the server.
///
/// `speaker_assignments.label` holds `stored`. The table and its key are unchanged; only what
/// the label column says is narrower.
public struct SpeakerKey: Hashable, Sendable {
    public var segmentId: String
    /// The provider's raw label for the speaker within the segment ("1").
    public var label: String

    /// `label` may be the raw label or the form the transcript renderer shows ("Speaker 1",
    /// which is what a transcript turn carries): both file under the raw one, so the app and the
    /// archive export, which reads raw labels, find the same name.
    public init(segmentId: String, label: String) {
        self.segmentId = segmentId
        self.label = Self.rawLabel(label)
    }

    /// "Speaker 7" → "7"; anything else as it is.
    static func rawLabel(_ label: String) -> String {
        let prefix = "Speaker "
        guard label.hasPrefix(prefix) else { return label }
        let digits = label.dropFirst(prefix.count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? String(digits) : label
    }

    /// Never in a segment id, which is `seg-<ms>-<hex>-<n>`.
    static let separator: Character = "#"

    /// What `speaker_assignments.label` holds for this speaker.
    public var stored: String { "\(segmentId)\(Self.separator)\(label)" }

    /// Reads a stored label. Nil for a row written before names were scoped, which names a
    /// label rather than a segment's speaker.
    public init?(stored: String) {
        guard let separator = stored.firstIndex(of: Self.separator),
            separator > stored.startIndex
        else { return nil }
        self.segmentId = String(stored[..<separator])
        self.label = String(stored[stored.index(after: separator)...])
    }

    /// The stored labels that can name this speaker, most specific first.
    ///
    /// Its own key, then the two forms rows were written in before names were scoped: the bare
    /// label, and its display form ("Speaker 1"), which is what the rename sheet filed names
    /// under because that is what a transcript turn carried. Those named the label in every
    /// segment of the conversation; they still do wherever a segment has no name of its own,
    /// because that is what the person saw when they made them.
    public var lookupOrder: [String] {
        var keys = [stored, label]
        if !label.isEmpty, label.allSatisfy(\.isNumber) { keys.append("Speaker \(label)") }
        return keys
    }

    /// This speaker's name in a table keyed by stored label (the archive export's form).
    public func name(in names: [String: String]) -> String? {
        for stored in lookupOrder {
            if let name = names[stored] { return name }
        }
        return nil
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

/// Which surface asked for a capture change. Stored as the `source` of a pause-journal row
/// (schema comment in AppDatabase.swift) and written to the flight recorder with every intent
/// transition — the 2026-09-19 12:17 stop could not be attributed to any control because the
/// recorder only ever saw the receiver's side of it.
public enum PauseSource: String, Sendable {
    /// Today's capture switch (its status card no longer offers Stop; the switch is the control).
    case statusCard
    /// The live conversation screen's Stop.
    case liveScreen
    /// Control Center, a widget button, Siri or a Shortcut, via the App Group mailbox.
    case intent
    /// Settings › the "Background audio" switch.
    case settingsSwitch
    /// Settings › Watch › Forget: capture off as part of dropping the binding.
    case forgetWatch
    /// Onboarding's provisional Connect being undone (Cancel, or an abandoned run).
    case onboarding
    /// A timed pause coming due — the one change nobody taps.
    case schedule

    /// The words the flight recorder uses.
    public var label: String {
        switch self {
        case .statusCard: return "Today switch"
        case .liveScreen: return "Live screen Stop"
        case .intent: return "Control Center / widget / Siri"
        case .settingsSwitch: return "Settings switch"
        case .forgetWatch: return "Forget Watch"
        case .onboarding: return "onboarding cancelled"
        case .schedule: return "pause schedule"
        }
    }
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

/// The `conversation_tags.source` values.
public enum TagSource {
    /// Proposed by the annotation pass and adopted automatically (`TagStore.applyAiTags`).
    public static let ai = "ai"
    /// Added (or re-added) by the person in the Tag Editor.
    public static let user = "user"
    /// Tombstone: an AI-proposed tag the person removed. The pair is KEPT, with this source,
    /// so the next enrichment pass over the same conversation does not silently re-propose
    /// what they just took off. Every read filters it out, so it is invisible everywhere.
    public static let removed = "removed"
}

public struct TagStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Tags carried by at least one conversation, most used first.
    ///
    /// Zero-count tags are dropped rather than listed: the Library chip row is a filter, and a
    /// chip that filters the library down to nothing is a dead control. A name with no pairs
    /// left (its last conversation deleted, or its only proposal withdrawn) still lives in
    /// `tags` so the Tag Editor can suggest it again.
    static func fetchTags(_ db: Database) throws -> [TagWithCount] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT t.id AS id, t.name AS name, COUNT(ct.conversationId) AS count
                FROM tags t
                LEFT JOIN conversation_tags ct
                    ON ct.tagId = t.id AND ct.source <> '\(TagSource.removed)'
                GROUP BY t.id
                HAVING count > 0
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
                    WHERE ct.conversationId = ? AND ct.source <> '\(TagSource.removed)'
                    ORDER BY t.name COLLATE NOCASE ASC
                    """,
                arguments: [conversationId]
            ).map { ConversationTag(id: $0["id"], name: $0["name"], source: $0["source"]) }
        }
    }

    /// Every conversation carrying this tag: what a rename of it changes everywhere.
    public func conversationIds(taggedWith tagId: String) async throws -> [String] {
        try await db.reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT conversationId FROM conversation_tags
                    WHERE tagId = ? AND source <> '\(TagSource.removed)'
                    ORDER BY conversationId
                    """,
                arguments: [tagId])
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
                    WHERE ct.conversationId = ? AND ct.source <> '\(TagSource.removed)'
                    ORDER BY t.name COLLATE NOCASE ASC
                    """,
                arguments: [conversationId]
            ).map { ConversationTag(id: $0["id"], name: $0["name"], source: $0["source"]) }
        }.values(in: db.reader)
    }

    /// Find-or-create a tag id for `name`, matching case-INSENSITIVELY.
    ///
    /// `tags.name` is `UNIQUE ON CONFLICT REPLACE`, so a second insert of the same name would
    /// delete the first row and cascade its pairs away — every conversation silently loses the
    /// tag. Matching NOCASE also keeps "Budget" from becoming a second chip beside "budget";
    /// the annotation pass lowercases general topics but title-cases proper nouns, and models
    /// are not consistent about which a word is.
    static func tagId(_ db: Database, forName name: String) throws -> String {
        if let existing = try String.fetchOne(
            db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE", arguments: [name])
        {
            return existing
        }
        let tagId = UUID().uuidString.lowercased()
        try db.execute(sql: "INSERT INTO tags (id, name) VALUES (?, ?)", arguments: [tagId, name])
        return tagId
    }

    /// Adds a tag (find-or-create by name) to a conversation. A user re-adding an AI-proposed
    /// tag — or one they had removed — upgrades the pair's source.
    @discardableResult
    public func addTag(
        conversationId: String, name: String, source: String
    ) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await db.writer.write { db in
            let tagId = try Self.tagId(db, forName: trimmed)
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

    /// Removes a tag from a conversation. An AI-proposed tag leaves a tombstone (see
    /// `TagSource.removed`) so the next annotation pass cannot put it straight back; a tag the
    /// person added themselves is simply deleted.
    public func removeTag(conversationId: String, tagId: String) async throws {
        try await db.writer.write { db in
            let source = try String.fetchOne(
                db,
                sql: "SELECT source FROM conversation_tags WHERE conversationId = ? AND tagId = ?",
                arguments: [conversationId, tagId]
            )
            if source == TagSource.ai {
                try db.execute(
                    sql: """
                        UPDATE conversation_tags SET source = ?
                        WHERE conversationId = ? AND tagId = ?
                        """,
                    arguments: [TagSource.removed, conversationId, tagId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM conversation_tags WHERE conversationId = ? AND tagId = ?",
                    arguments: [conversationId, tagId]
                )
            }
        }
    }

    /// Adopts the annotation pass's proposed tags for one conversation.
    ///
    /// The AI tags were being written to `annotations.tagsJson` and read back by nothing that
    /// filters: the Library chip row, the `tagName` filter, the row/detail pills and the
    /// Search "Tags" section all read `conversation_tags`, which only the Tag Editor ever
    /// wrote. So every library was untagged unless the person typed the tags in by hand, and
    /// the chip row — hidden when there are no tags — never appeared at all.
    ///
    /// Adoption is a REPLACE of this conversation's AI set, never a merge: a re-run proposing
    /// a different set leaves the old names behind. Pairs the person owns are untouched —
    /// their tags are not re-sourced, and the ones they removed stay removed.
    ///
    /// Returns whether anything changed, so a no-op pass does not wake every library
    /// observation.
    @discardableResult
    public static func applyAiTags(
        _ db: Database, conversationId: String, names: [String]
    ) throws -> Bool {
        let proposed =
            names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, name in
                if !unique.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    unique.append(name)
                }
            }

        let existing = try Row.fetchAll(
            db,
            sql: """
                SELECT ct.tagId AS tagId, ct.source AS source, t.name AS name
                FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                WHERE ct.conversationId = ?
                """,
            arguments: [conversationId]
        ).map {
            (tagId: $0["tagId"] as String, source: $0["source"] as String, name: $0["name"] as String)
        }

        // A name the person owns or has removed is theirs to decide; the pass says nothing
        // about it either way.
        let spokenFor = Set(
            existing.filter { $0.source != TagSource.ai }.map { $0.name.lowercased() })
        let wanted = proposed.filter { !spokenFor.contains($0.lowercased()) }
        let wantedKeys = Set(wanted.map { $0.lowercased() })
        let mine = existing.filter { $0.source == TagSource.ai }
        var changed = false

        for pair in mine where !wantedKeys.contains(pair.name.lowercased()) {
            try db.execute(
                sql: """
                    DELETE FROM conversation_tags WHERE conversationId = ? AND tagId = ?
                    """,
                arguments: [conversationId, pair.tagId]
            )
            changed = true
        }

        let held = Set(mine.map { $0.name.lowercased() })
        for name in wanted where !held.contains(name.lowercased()) {
            let tagId = try Self.tagId(db, forName: name)
            try db.execute(
                sql: """
                    INSERT INTO conversation_tags (conversationId, tagId, source)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversationId, tagId) DO NOTHING
                    """,
                arguments: [conversationId, tagId, TagSource.ai]
            )
            changed = true
        }
        return changed
    }

    @discardableResult
    public func applyAiTags(conversationId: String, names: [String]) async throws -> Bool {
        try await db.writer.write {
            try Self.applyAiTags($0, conversationId: conversationId, names: names)
        }
    }

    /// Drops every pair for a conversation that no longer exists (delete cascade). Without
    /// this the deleted conversation keeps inflating every chip's count, and a filter on that
    /// chip shows fewer rows than the count promised.
    public func forgetConversation(_ conversationId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM conversation_tags WHERE conversationId = ?",
                arguments: [conversationId])
        }
    }

    /// RENAME IS GLOBAL (Q10): updates `tags.name`, so every conversation carrying the tag
    /// shows the new name. Renaming onto an existing tag's name merges into that tag.
    public func renameTag(tagId: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.writer.write { db in
            if let target = try String.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND id <> ?",
                arguments: [trimmed, tagId]
            ) {
                // Merge: repoint pairs (keeping existing target pairs), drop the old tag. A
                // tombstone on the target would otherwise win the `OR IGNORE` and swallow a
                // real pair, so the removal is cleared first — a rename is the person putting
                // the tag back into play under a new name.
                try db.execute(
                    sql: """
                        DELETE FROM conversation_tags
                        WHERE tagId = ? AND source = ? AND conversationId IN
                            (SELECT conversationId FROM conversation_tags WHERE tagId = ?)
                        """,
                    arguments: [target, TagSource.removed, tagId])
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

    /// Recently used tags not already on this conversation (Tag Editor "Suggestions"). A tag
    /// the person removed here IS offered again — the tombstone only stops the AI from
    /// re-proposing it, it does not put the name out of reach.
    public func suggestions(
        forConversation conversationId: String, limit: Int = 6
    ) async throws -> [TagWithCount] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS id, t.name AS name,
                        (SELECT COUNT(*) FROM conversation_tags c2
                            WHERE c2.tagId = t.id AND c2.source <> ?) AS count,
                        IFNULL((SELECT MAX(rowid) FROM conversation_tags c3 WHERE c3.tagId = t.id), -1)
                            AS lastUse
                    FROM tags t
                    WHERE t.id NOT IN
                        (SELECT tagId FROM conversation_tags
                            WHERE conversationId = ? AND source <> ?)
                    ORDER BY lastUse DESC, t.name COLLATE NOCASE ASC
                    LIMIT ?
                    """,
                arguments: [TagSource.removed, conversationId, TagSource.removed, limit]
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
            sourceSegmentId: row["sourceSegmentId"], createdAtMs: row["createdAtMs"],
            quote: row["quote"],
            why: row["why"],
            dueAtMs: row["dueAtMs"],
            priority: FollowUpPriority(rawValue: row["priority"] ?? 1) ?? .normal,
            sourceStartMs: row["sourceStartMs"],
            sourceEndMs: row["sourceEndMs"],
            completedAtMs: row["completedAtMs"],
            archivedAtMs: row["archivedAtMs"],
            snoozedUntilMs: row["snoozedUntilMs"],
            editedAtMs: row["editedAtMs"],
            touchedAtMs: row["touchedAtMs"],
            origin: FollowUpOrigin(rawValue: row["origin"] ?? "ai") ?? .ai,
            model: row["model"],
            sourceWall: SegmentWallRange.sourceWall(from: row))
    }

    /// Every column, in one place, so `add` and `upsert` cannot drift apart.
    private static let insertSQL = """
        INSERT INTO follow_ups
            (id, text, done, sourceConversationId, sourceSegmentId, createdAtMs,
             quote, why, dueAtMs, priority, sourceStartMs, sourceEndMs,
             completedAtMs, archivedAtMs, snoozedUntilMs, editedAtMs, touchedAtMs, origin,
             model, sourceWallStartMs, sourceWallEndMs, sourceWallApproximate)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static func arguments(_ item: FollowUp) -> StatementArguments {
        [
            item.id, item.text, item.done, item.sourceConversationId, item.sourceSegmentId,
            item.createdAtMs, item.quote, item.why, item.dueAtMs, item.priority.rawValue,
            item.sourceStartMs, item.sourceEndMs, item.completedAtMs, item.archivedAtMs,
            item.snoozedUntilMs, item.editedAtMs, item.touchedAtMs, item.origin.rawValue,
            item.model, item.sourceWall?.startMs, item.sourceWall?.endMs,
            item.sourceWall?.isApproximate,
        ]
    }

    /// A follow-up the person wrote themselves. `origin: .user` is load-bearing — it is what
    /// keeps curation and the age rule off it.
    @discardableResult
    public func add(
        text: String, conversationId: String? = nil, segmentId: String? = nil,
        dueAtMs: Int64? = nil, priority: FollowUpPriority = .normal,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> FollowUp {
        let item = FollowUp(
            id: UUID().uuidString.lowercased(), text: text, done: false,
            sourceConversationId: conversationId, sourceSegmentId: segmentId, createdAtMs: nowMs,
            dueAtMs: dueAtMs, priority: priority, origin: .user)
        try await db.writer.write { db in
            try db.execute(sql: Self.insertSQL, arguments: Self.arguments(item))
        }
        return item
    }

    /// Writes an item the curation pass decided to keep.
    ///
    /// The conflict clause is deliberately narrow. `done`, `completedAtMs`, `archivedAtMs`,
    /// `snoozedUntilMs` and an edited `text` are the person's answer to the item, and a second
    /// pass over the same conversation must never overwrite an answer: re-running extraction
    /// cannot un-tick, un-archive, un-snooze, or un-edit anything.
    public func upsertExtracted(_ item: FollowUp) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: Self.insertSQL + """
                    \nON CONFLICT(id) DO UPDATE SET
                        text = CASE WHEN follow_ups.editedAtMs IS NULL
                                    THEN excluded.text ELSE follow_ups.text END,
                        quote = excluded.quote,
                        why = excluded.why,
                        dueAtMs = excluded.dueAtMs,
                        priority = excluded.priority,
                        sourceConversationId = excluded.sourceConversationId,
                        sourceSegmentId = excluded.sourceSegmentId,
                        sourceStartMs = excluded.sourceStartMs,
                        sourceEndMs = excluded.sourceEndMs,
                        model = COALESCE(excluded.model, follow_ups.model),
                        \(Self.keepWallTimeUnlessRelocated)
                    """,
                arguments: Self.arguments(item))
        }
    }

    /// The wall-time half of `upsertExtracted`'s conflict clause. The incoming value wins —
    /// it was computed from the location being written — except where it is NULL and the
    /// location (segment and media offsets) is the one already on the row: a writer that did
    /// not compute a wall time must not erase one the fill or an earlier extraction stored for
    /// the very same words. A MOVED location takes the incoming value, NULL included, so a
    /// stale time never outlives the quote it described. In an upsert, `follow_ups.x` is the
    /// row's value before the update.
    private static let keepWallTimeUnlessRelocated =
        ["sourceWallStartMs", "sourceWallEndMs", "sourceWallApproximate"].map { column in
            """
            \(column) = CASE
                    WHEN excluded.sourceWallStartMs IS NULL
                        AND excluded.sourceSegmentId IS follow_ups.sourceSegmentId
                        AND excluded.sourceStartMs IS follow_ups.sourceStartMs
                        AND excluded.sourceEndMs IS follow_ups.sourceEndMs
                    THEN follow_ups.\(column) ELSE excluded.\(column) END
            """
        }.joined(separator: ",\n")

    public func load(id: String) async throws -> FollowUp? {
        try await db.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM follow_ups WHERE id = ?", arguments: [id])
                .map(Self.followUp(from:))
        }
    }

    /// `open` excludes done, archived and still-snoozed rows; `completed` is done-and-not-
    /// archived; `archived` is everything that left the working list; `all` is the table.
    ///
    /// Ordering matches how each slice is read: open by due date then priority then newest,
    /// completed and archived newest-first.
    public func list(
        scope: FollowUpScope = .open,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> [FollowUp] {
        try await db.reader.read { db in
            let sql: String
            let arguments: StatementArguments
            switch scope {
            case .open:
                // Snoozed rows are INCLUDED. They used to be excluded here and matched no
                // other scope either, so putting something off removed it from every list in
                // the app until the snooze expired — with the only control for undoing that on
                // the screen you could no longer reach. The list sections them under "Put off"
                // instead; `openCount` is the thing that leaves them out, because Today should
                // not show what you deliberately deferred.
                sql = """
                    SELECT * FROM follow_ups
                    WHERE done = 0 AND archivedAtMs IS NULL
                    ORDER BY (snoozedUntilMs IS NOT NULL AND snoozedUntilMs > ?),
                             (dueAtMs IS NULL), dueAtMs, priority DESC, createdAtMs DESC, id
                    """
                arguments = [nowMs]
            case .completed:
                sql = """
                    SELECT * FROM follow_ups
                    WHERE done = 1 AND archivedAtMs IS NULL
                    ORDER BY COALESCE(completedAtMs, createdAtMs) DESC, id
                    """
                arguments = []
            case .archived:
                sql = """
                    SELECT * FROM follow_ups WHERE archivedAtMs IS NOT NULL
                    ORDER BY archivedAtMs DESC, id
                    """
                arguments = []
            case .all:
                sql = "SELECT * FROM follow_ups ORDER BY done ASC, createdAtMs DESC, id"
                arguments = []
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.followUp(from:))
        }
    }

    /// Snoozed items included: on a conversation's own screen, hiding one of its follow-ups
    /// because it was put off until Thursday would just look like the app lost it.
    public func list(conversationId: String) async throws -> [FollowUp] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_ups WHERE sourceConversationId = ?
                    ORDER BY done ASC, archivedAtMs IS NOT NULL, createdAtMs DESC, id
                    """,
                arguments: [conversationId]
            ).map(Self.followUp(from:))
        }
    }

    /// Flips done state; returns the new value. Ticking stamps the completion time, un-ticking
    /// clears it, and either way the item comes back out of the archive — you cannot act on
    /// something the app has filed away.
    @discardableResult
    public func toggle(
        id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Bool {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups
                    SET done = NOT done,
                        completedAtMs = CASE WHEN done = 0 THEN ? ELSE NULL END,
                        archivedAtMs = NULL, touchedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [nowMs, nowMs, id])
            return try Bool.fetchOne(
                db, sql: "SELECT done FROM follow_ups WHERE id = ?", arguments: [id]) ?? false
        }
    }

    public func setDone(
        id: String, _ done: Bool, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups
                    SET done = ?, completedAtMs = ?, archivedAtMs = NULL, touchedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [done, done ? nowMs : nil, nowMs, id])
        }
    }

    /// A hand-edit. Stamping `editedAtMs` is what makes the edit survive re-extraction.
    public func setText(
        id: String, _ text: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups SET text = ?, editedAtMs = ?, touchedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [text, nowMs, nowMs, id])
        }
    }

    public func setDue(
        id: String, _ dueAtMs: Int64?, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET dueAtMs = ?, touchedAtMs = ? WHERE id = ?",
                arguments: [dueAtMs, nowMs, id])
        }
    }

    public func setPriority(
        id: String, _ priority: FollowUpPriority,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET priority = ?, touchedAtMs = ? WHERE id = ?",
                arguments: [priority.rawValue, nowMs, id])
        }
    }

    /// Put off until `untilMs` (nil clears it). Snoozing also un-archives, so "not now" and
    /// "not ever" stay different answers.
    public func snooze(
        id: String, until untilMs: Int64?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups
                    SET snoozedUntilMs = ?, archivedAtMs = NULL, touchedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [untilMs, nowMs, id])
        }
    }

    public func setArchived(
        id: String, _ archived: Bool,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET archivedAtMs = ?, touchedAtMs = ? WHERE id = ?",
                arguments: [archived ? nowMs : nil, nowMs, id])
        }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM follow_ups WHERE id = ?", arguments: [id])
        }
    }

    /// An item an assistant created through the Pebble Audio server, under the id the server
    /// gave it (`origin` is forced to `.assistant`). A second delivery of the same request finds
    /// it there and changes nothing. Returns false when it was already there.
    @discardableResult
    public func insertFromAssistant(_ item: FollowUp) async throws -> Bool {
        var stamped = item
        stamped.origin = .assistant
        let toWrite = stamped
        return try await db.writer.write { db in
            try db.execute(
                sql: Self.insertSQL + "\nON CONFLICT(id) DO NOTHING",
                arguments: Self.arguments(toWrite))
            return db.changesCount > 0
        }
    }

    /// The fields an assistant may change on an item (`sync-protocol.md` §4 `followUp.update`).
    /// `nil` leaves a field alone; `.some(nil)` clears it.
    public struct AssistantChange: Equatable, Sendable {
        public var done: Bool?
        public var completedAtMs: Int64??
        public var text: String?
        public var dueAtMs: Int64??
        public var snoozedUntilMs: Int64??
        public var archivedAtMs: Int64??

        public init(
            done: Bool? = nil, completedAtMs: Int64?? = nil, text: String? = nil,
            dueAtMs: Int64?? = nil, snoozedUntilMs: Int64?? = nil, archivedAtMs: Int64?? = nil
        ) {
            self.done = done
            self.completedAtMs = completedAtMs
            self.text = text
            self.dueAtMs = dueAtMs
            self.snoozedUntilMs = snoozedUntilMs
            self.archivedAtMs = archivedAtMs
        }

        public var isEmpty: Bool {
            done == nil && completedAtMs == nil && text == nil && dueAtMs == nil
                && snoozedUntilMs == nil && archivedAtMs == nil
        }
    }

    /// Applies an assistant's change. Like a person's own edit it stamps `touchedAtMs` (so the
    /// age rule leaves the item alone) and, for new text, `editedAtMs` (so re-extraction never
    /// overwrites it). Ticking without a completion time stamps now. Returns false when there is
    /// no such item.
    @discardableResult
    public func applyAssistantChange(
        id: String, _ change: AssistantChange,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Bool {
        var sets: [String] = ["touchedAtMs = ?"]
        var arguments: [(any DatabaseValueConvertible)?] = [nowMs]
        if let done = change.done {
            sets.append("done = ?")
            arguments.append(done)
            sets.append("completedAtMs = ?")
            arguments.append(done ? ((change.completedAtMs ?? nil) ?? nowMs) : nil)
        } else if let completed = change.completedAtMs {
            sets.append("completedAtMs = ?")
            arguments.append(completed)
        }
        if let text = change.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        {
            sets.append("text = ?")
            arguments.append(text)
            sets.append("editedAtMs = ?")
            arguments.append(nowMs)
        }
        if let due = change.dueAtMs {
            sets.append("dueAtMs = ?")
            arguments.append(due)
        }
        if let snoozed = change.snoozedUntilMs {
            sets.append("snoozedUntilMs = ?")
            arguments.append(snoozed)
        }
        if let archived = change.archivedAtMs {
            sets.append("archivedAtMs = ?")
            arguments.append(archived)
        }
        arguments.append(id)
        let sql = "UPDATE follow_ups SET \(sets.joined(separator: ", ")) WHERE id = ?"
        let statementArguments = StatementArguments(arguments)
        return try await db.writer.write { db in
            try db.execute(sql: sql, arguments: statementArguments)
            return db.changesCount > 0
        }
    }

    /// The age rule, run by the pipeline: an open item the AI proposed, that nobody has
    /// touched, that has no deadline of its own, and that is older than `olderThanMs`, leaves
    /// the working list.
    ///
    /// It is archived, never deleted, and it is still one tap from coming back. Hand-written
    /// items, edited items, snoozed items and anything with a due date are all left alone —
    /// those are all evidence that a person, not a clock, is in charge of this row.
    /// Returns how many were filed away.
    @discardableResult
    public func archiveStale(
        olderThanMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Int {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_ups SET archivedAtMs = ?
                    WHERE done = 0 AND archivedAtMs IS NULL AND origin = 'ai'
                      AND touchedAtMs IS NULL AND editedAtMs IS NULL
                      AND snoozedUntilMs IS NULL AND dueAtMs IS NULL
                      AND createdAtMs < ?
                    """,
                arguments: [nowMs, nowMs - olderThanMs])
            return db.changesCount
        }
    }

    /// Count of items on the working list — what "See all N" and the widget say.
    public func openCount(
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Int {
        try await db.reader.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM follow_ups
                    WHERE done = 0 AND archivedAtMs IS NULL
                      AND (snoozedUntilMs IS NULL OR snoozedUntilMs <= ?)
                    """,
                arguments: [nowMs]) ?? 0
        }
    }

    /// Change signal for the working list. Tracks the whole table on purpose: an item being
    /// archived or snoozed leaves the set, and the screen has to hear about that too.
    public func observeOpen(limit: Int = 200) -> AsyncValueObservation<[FollowUp]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_ups
                    ORDER BY done ASC, archivedAtMs IS NOT NULL, createdAtMs DESC, id
                    LIMIT ?
                    """,
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
            createdAtMs: row["createdAtMs"], editedAtMs: row["editedAtMs"],
            origin: row["origin"])
    }

    /// A note an assistant wrote through the Pebble Audio server, under the id the server gave
    /// it. A second delivery of the same request finds the note there and changes nothing.
    /// Returns false when it was already there.
    @discardableResult
    public func insertFromAssistant(_ note: Note) async throws -> Bool {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes (id, conversationId, templateId, title, body, citations,
                        provider, model, createdAtMs, editedAtMs, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'assistant')
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    note.id, note.conversationId, note.templateId, note.title, note.body,
                    note.citationsJson, note.provider, note.model, note.createdAtMs,
                    note.editedAtMs,
                ])
            return db.changesCount > 0
        }
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

    /// Files a speaker under a person, in one conversation (upsert per label). `label` is a
    /// `SpeakerKey.stored`, so the name reaches that segment's speaker and nobody else's.
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

    /// Every conversation with a speaker assigned to this person: what a rename or a delete of
    /// the person changes, and so what has to be indexed again.
    public func conversationIds(assignedTo personId: String) async throws -> [String] {
        try await db.reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT conversationId FROM speaker_assignments
                    WHERE personId = ? ORDER BY conversationId
                    """,
                arguments: [personId])
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
