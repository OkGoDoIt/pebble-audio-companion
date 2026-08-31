import Foundation
import GRDB
import AppDB

// Follow-up extraction (plan Part 4.5 "Follow-ups") — the port of `core/ai/ActionItemStore.kt`
// with two deliberate changes from the KMP behavior:
//  - persistence moves from `<root>/ai/action_items/*.action.json` files to the DB
//    `follow_ups` table, so extracted items surface through the same store/observations the
//    Today card uses;
//  - the lenient text parser is a LAST RESORT that REJECTS lines with residual markdown/list
//    structure instead of cleaning them (anti-B4: `**Owner:**` leaked into the UI and numbered
//    fragments shipped as items). The strict JSON path — the `action_items` structured-output
//    schema — is the only intended path for providers that support it.

/// One extracted action item linked to its source segment. Vocabulary note: the UI calls these
/// "Follow-ups" everywhere; "action item" survives only at this extraction seam.
public struct ActionItem: Equatable, Sendable {
    public var id: String
    public var text: String
    public var done: Bool
    public var sourceSegmentId: String
    public var createdAtMs: Int64

    public init(
        id: String, text: String, done: Bool = false, sourceSegmentId: String,
        createdAtMs: Int64
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.sourceSegmentId = sourceSegmentId
        self.createdAtMs = createdAtMs
    }
}

/// Wire shape of the strict structured-output path. Empty string = unknown (the schema requires
/// every key, so providers cannot omit fields to mean "unknown").
public struct ExtractedActionItem: Equatable, Sendable, Codable {
    public var task: String
    public var owner: String
    public var due: String
    public var sourceSegmentId: String

    public init(task: String, owner: String = "", due: String = "", sourceSegmentId: String = "") {
        self.task = task
        self.owner = owner
        self.due = due
        self.sourceSegmentId = sourceSegmentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(String.self, forKey: .task)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
        sourceSegmentId = try c.decodeIfPresent(String.self, forKey: .sourceSegmentId) ?? ""
    }
}

public struct ExtractedActionItems: Equatable, Sendable, Codable {
    public var items: [ExtractedActionItem]

    public init(items: [ExtractedActionItem]) {
        self.items = items
    }
}

/// Parses action-item template output into structured items.
public enum ActionItemParser {
    /// Name of the structured-output JSON schema (`response_format`/`text.format` name).
    public static let structuredOutputSchemaName = "action_items"

    /// The strict `action_items` JSON schema for structured-output providers:
    /// `additionalProperties: false`, every key required, empty string = unknown.
    public static let structuredOutputSchemaJSON = """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["items"],
          "properties": {
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["task", "owner", "due", "sourceSegmentId"],
                "properties": {
                  "task": {
                    "type": "string",
                    "description": "Concrete action or follow-up task. Empty only if omitted from items."
                  },
                  "owner": {
                    "type": "string",
                    "description": "Responsible person or team if stated, otherwise empty string."
                  },
                  "due": {
                    "type": "string",
                    "description": "Deadline if stated, otherwise empty string."
                  },
                  "sourceSegmentId": {
                    "type": "string",
                    "description": "Transcript segment id supporting the item, otherwise empty string."
                  }
                }
              }
            }
          }
        }
        """

    public static func parse(
        raw: String, sourceSegmentId: String, nowMs: Int64, idPrefix: String? = nil
    ) -> [ActionItem] {
        let prefix = idPrefix ?? sourceSegmentId
        if let structured = parseStructured(
            raw: raw, fallbackSourceSegmentId: sourceSegmentId, nowMs: nowMs, idPrefix: prefix)
        {
            return structured
        }
        if raw.range(of: "no action items", options: .caseInsensitive) != nil { return [] }
        var seen = Set<String>()
        var texts: [String] = []
        for rawLine in raw.components(separatedBy: "\n") {
            guard let line = acceptLenientLine(rawLine) else { continue }
            let normalized = line.lowercased()
            if normalized.hasPrefix("here are ") || normalized.hasPrefix("action items")
                || normalized.hasPrefix("owner:") || normalized == "tasks" || normalized == "task"
            {
                continue
            }
            if seen.insert(line).inserted { texts.append(line) }
        }
        return texts.enumerated().map { index, text in
            ActionItem(
                id: "\(prefix)-action-\(index)", text: text, sourceSegmentId: sourceSegmentId,
                createdAtMs: nowMs)
        }
    }

    public static func parseStructured(
        raw: String, fallbackSourceSegmentId: String, nowMs: Int64, idPrefix: String? = nil
    ) -> [ActionItem]? {
        let prefix = idPrefix ?? fallbackSourceSegmentId
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let parsed = try? JSONDecoder().decode(
                ExtractedActionItems.self, from: Data(trimmed.utf8))
        else { return nil }
        return parsed.items.enumerated().compactMap { index, item in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.isEmpty { return nil }
            let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let due = item.due.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = task
            if !owner.isEmpty { text += ". Owner: \(owner)" }
            if !due.isEmpty { text += ". Due: \(due)" }
            let source = item.sourceSegmentId.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionItem(
                id: "\(prefix)-action-\(index)",
                text: text,
                sourceSegmentId: source.isEmpty ? fallbackSourceSegmentId : source,
                createdAtMs: nowMs)
        }
    }

    public static func displayText(_ items: [ActionItem]) -> String {
        if items.isEmpty { return "No action items found." }
        return items.map { "- [ ] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Lenient path (anti-B4)

    /// Accept a lenient line only when, after stripping ONE expected checklist marker, no
    /// markdown or list structure remains. The KMP parser cleaned `**bold**`/headings/numbered
    /// markers away, which is exactly how `**Owner:**` fragments and numbered scraps reached
    /// the UI (bug B4) — here those lines are rejected outright.
    private static func acceptLenientLine(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        // Headings and numbered lists are off-template structure, not checklist items.
        if line.hasPrefix("#") { return nil }
        if line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return nil }
        // Strip one leading checklist marker (the shape the template demands).
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "[ ] ", "[x] ", "[X] ", "- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        // Residual structure after the marker ⇒ reject, never clean.
        if containsResidualStructure(line) { return nil }
        // Punctuation normalization only (not markdown cleaning): the canonical composition is
        // "task. Owner: X. Due: Y".
        line = line.replacingOccurrences(
            of: #"\s+—\s+Owner:"#, with: ". Owner:",
            options: [.regularExpression, .caseInsensitive])
        line = line.replacingOccurrences(
            of: #"\s+-\s+Owner:"#, with: ". Owner:",
            options: [.regularExpression, .caseInsensitive])
        line = line.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    private static func containsResidualStructure(_ line: String) -> Bool {
        if line.contains("**") || line.contains("__") || line.contains("`") { return true }
        // A second list marker after the stripped one = nested list structure.
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("#")
        {
            return true
        }
        // Emphasis spans and markdown links.
        if line.range(of: #"\*[^*\s][^*]*\*"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"\[[^\]]*]\([^)]*\)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

// MARK: - ActionItemStore (DB-backed, follow_ups table)

/// Port of `FileActionItemStore`'s behavioral contract onto the `follow_ups` table, so
/// extracted items land where FollowUpStore (and the Today card's observation) reads. Rows
/// written here use the parser's deterministic `<prefix>-action-<i>` ids; user-added
/// follow-ups keep their UUID ids, which is how `list()`/`deleteAll()` stay scoped to
/// extracted items.
public struct ActionItemStore: Sendable {
    public let db: AppDatabase
    private let nowMs: @Sendable () -> Int64

    public init(
        db: AppDatabase,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.db = db
        self.nowMs = nowMs
    }

    private static let extractedIdPattern = "%-action-%"

    static func item(from row: Row) -> ActionItem {
        ActionItem(
            id: row["id"], text: row["text"], done: row["done"],
            sourceSegmentId: row["sourceSegmentId"] ?? "", createdAtMs: row["createdAtMs"])
    }

    /// Upserts by id (re-running extraction for a segment overwrites, never duplicates).
    /// A zero `createdAtMs` is stamped with the store clock, matching the KMP store.
    @discardableResult
    public func save(_ item: ActionItem) async throws -> ActionItem {
        var stamped = item
        if stamped.createdAtMs == 0 { stamped.createdAtMs = nowMs() }
        let toWrite = stamped
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO follow_ups
                        (id, text, done, sourceConversationId, sourceSegmentId, createdAtMs)
                    VALUES (?, ?, ?, NULL, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text, done = excluded.done,
                        sourceSegmentId = excluded.sourceSegmentId,
                        createdAtMs = excluded.createdAtMs
                    """,
                arguments: [
                    toWrite.id, toWrite.text, toWrite.done, toWrite.sourceSegmentId,
                    toWrite.createdAtMs,
                ]
            )
        }
        return toWrite
    }

    @discardableResult
    public func saveAll(_ items: [ActionItem]) async throws -> [ActionItem] {
        var saved: [ActionItem] = []
        for item in items { saved.append(try await save(item)) }
        return saved
    }

    public func load(id: String) async throws -> ActionItem? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM follow_ups WHERE id = ?", arguments: [id]
            ).map(Self.item(from:))
        }
    }

    /// Extracted items only, newest first (KMP `list()` order).
    public func list() async throws -> [ActionItem] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM follow_ups WHERE id LIKE ?
                    ORDER BY createdAtMs DESC, id
                    """,
                arguments: [Self.extractedIdPattern]
            ).map(Self.item(from:))
        }
    }

    @discardableResult
    public func setDone(id: String, _ done: Bool) async throws -> ActionItem? {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE follow_ups SET done = ? WHERE id = ?", arguments: [done, id])
            return try Row.fetchOne(
                db, sql: "SELECT * FROM follow_ups WHERE id = ?", arguments: [id]
            ).map(Self.item(from:))
        }
    }

    public func delete(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM follow_ups WHERE id = ?", arguments: [id])
        }
    }

    /// Deletes every segment's extracted items. Only rows with parser-shaped ids are removed;
    /// user-added follow-ups (UUID ids) are untouched.
    public func deleteAll() async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM follow_ups WHERE id LIKE ?",
                arguments: [Self.extractedIdPattern])
        }
    }

    /// Deletes the extracted items sourced from one segment (the segment delete cascade).
    public func deleteForSegment(segmentId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM follow_ups WHERE id LIKE ? AND sourceSegmentId = ?",
                arguments: [Self.extractedIdPattern, segmentId])
        }
    }
}
