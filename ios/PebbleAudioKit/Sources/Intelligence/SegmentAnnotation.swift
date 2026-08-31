import AppDB
import Foundation
import GRDB

// Port of the model half of `core/ai/.../SegmentAnnotationStore.kt`, retargeted from segment
// to CONVERSATION granularity (plan Part 3: titles/summaries/tags attach to the
// conversation). Persistence moved from one-JSON-file-per-segment to the AppDB `annotations`
// table (conversationId PK), same as the transcription queue's file→table move.

/// AI-generated title + summary + proposed tags for one conversation, used by Library/Today
/// rows. Row decoration generated automatically under the user's AI consent/mode settings,
/// not user-requested output.
public struct ConversationAnnotation: Equatable, Sendable {
    public var conversationId: String
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var modeUsed: AiProcessingMode?
    public var providerId: String?
    public var modelUsed: String?
    /// Stamped by the store on save (the KMP `createdAtMs`); anchors the live-refresh
    /// interval gate.
    public var updatedAtMs: Int64
    /// Total generation attempts (live + final) so far; informational.
    public var attempts: Int
    public var lastError: String?
    /// True once the annotation was generated from the complete, durable transcripts of a
    /// closed conversation. While a conversation is still live, provisional annotations are
    /// refreshed and stay `false` until the authoritative final pass replaces them.
    public var isFinal: Bool
    /// Length of the combined transcript text last summarized; drives the live-refresh
    /// growth gate.
    public var sourceCharCount: Int
    /// Final-pass attempts only, so a broken provider cannot spin the authoritative pass
    /// forever.
    public var finalAttempts: Int

    public init(
        conversationId: String,
        title: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        modeUsed: AiProcessingMode? = nil,
        providerId: String? = nil,
        modelUsed: String? = nil,
        updatedAtMs: Int64 = 0,
        attempts: Int = 0,
        lastError: String? = nil,
        isFinal: Bool = false,
        sourceCharCount: Int = 0,
        finalAttempts: Int = 0
    ) {
        self.conversationId = conversationId
        self.title = title
        self.summary = summary
        self.tags = tags
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.updatedAtMs = updatedAtMs
        self.attempts = attempts
        self.lastError = lastError
        self.isFinal = isFinal
        self.sourceCharCount = sourceCharCount
        self.finalAttempts = finalAttempts
    }

    public var hasContent: Bool {
        if let title, !title.isBlank { return true }
        if let summary, !summary.isBlank { return true }
        return !tags.isEmpty
    }
}

/// Durable annotation storage over the AppDB `annotations` table.
///
/// The table's core columns (conversationId/title/summary/tagsJson/isFinal/sourceCharCount/
/// finalAttempts/updatedAtMs) are defined by AppDatabase's v1 migration; this store owns the
/// enrichment-bookkeeping columns (modeUsed/providerId/modelUsed/attempts/lastError, matching
/// `transcription_tasks`' provenance columns) and adds them idempotently on init so already-
/// migrated databases pick them up without an AppDB schema change.
public struct AnnotationStore: Sendable {
    public let db: AppDatabase
    private let nowMs: @Sendable () -> Int64

    public init(
        db: AppDatabase,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        self.db = db
        self.nowMs = nowMs
        try Self.ensureEnrichmentColumns(db)
    }

    private static func ensureEnrichmentColumns(_ db: AppDatabase) throws {
        try db.writer.write { db in
            let existing = Set(try db.columns(in: "annotations").map(\.name))
            let additions: [(name: String, definition: String)] = [
                ("modeUsed", "TEXT"),
                ("providerId", "TEXT"),
                ("modelUsed", "TEXT"),
                ("attempts", "INTEGER NOT NULL DEFAULT 0"),
                ("lastError", "TEXT"),
            ]
            for column in additions where !existing.contains(column.name) {
                try db.execute(
                    sql: "ALTER TABLE annotations ADD COLUMN \(column.name) \(column.definition)")
            }
        }
    }

    /// Saves (upserts) the annotation, stamping `updatedAtMs` (KMP `save` stamped
    /// `createdAtMs` the same way). Returns the stamped value.
    @discardableResult
    public func save(_ annotation: ConversationAnnotation) async throws -> ConversationAnnotation {
        var stamped = annotation
        stamped.updatedAtMs = nowMs()
        let tagsJson = String(decoding: try JSONEncoder().encode(stamped.tags), as: UTF8.self)
        let toStore = stamped
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO annotations (conversationId, title, summary, tagsJson, isFinal,
                        sourceCharCount, finalAttempts, updatedAtMs, modeUsed, providerId,
                        modelUsed, attempts, lastError)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET
                        title = excluded.title, summary = excluded.summary,
                        tagsJson = excluded.tagsJson, isFinal = excluded.isFinal,
                        sourceCharCount = excluded.sourceCharCount,
                        finalAttempts = excluded.finalAttempts,
                        updatedAtMs = excluded.updatedAtMs, modeUsed = excluded.modeUsed,
                        providerId = excluded.providerId, modelUsed = excluded.modelUsed,
                        attempts = excluded.attempts, lastError = excluded.lastError
                    """,
                arguments: [
                    toStore.conversationId, toStore.title, toStore.summary, tagsJson,
                    toStore.isFinal, toStore.sourceCharCount, toStore.finalAttempts,
                    toStore.updatedAtMs, toStore.modeUsed?.rawValue, toStore.providerId,
                    toStore.modelUsed, toStore.attempts, toStore.lastError,
                ]
            )
        }
        return stamped
    }

    public func load(_ conversationId: String) async throws -> ConversationAnnotation? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM annotations WHERE conversationId = ?",
                arguments: [conversationId]
            ).map(Self.annotation(from:))
        }
    }

    public func list() async throws -> [ConversationAnnotation] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM annotations ORDER BY updatedAtMs, conversationId"
            ).map(Self.annotation(from:))
        }
    }

    public func delete(_ conversationId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM annotations WHERE conversationId = ?",
                arguments: [conversationId])
        }
    }

    public func deleteAll() async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM annotations")
        }
    }

    static func annotation(from row: Row) -> ConversationAnnotation {
        let tagsJson: String? = row["tagsJson"]
        let tags =
            tagsJson.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            ?? []
        return ConversationAnnotation(
            conversationId: row["conversationId"],
            title: row["title"],
            summary: row["summary"],
            tags: tags,
            modeUsed: (row["modeUsed"] as String?).flatMap(AiProcessingMode.init(rawValue:)),
            providerId: row["providerId"],
            modelUsed: row["modelUsed"],
            updatedAtMs: row["updatedAtMs"],
            attempts: row["attempts"],
            lastError: row["lastError"],
            isFinal: row["isFinal"],
            sourceCharCount: row["sourceCharCount"],
            finalAttempts: row["finalAttempts"]
        )
    }
}
