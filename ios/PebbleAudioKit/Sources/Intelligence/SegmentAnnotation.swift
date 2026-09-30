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
    /// Final-pass attempts that failed ON THE INPUT (`AiFailureKind.blamesTheInput`), so a
    /// conversation the model genuinely cannot title stops costing calls. A failure that was the
    /// world's — offline, a broke or busy account — does not count (see `AiRetryPolicy`).
    public var finalAttempts: Int
    /// The final pass does not run before this. Set by every failure (a short wait for one on
    /// the input, a doubling one for one that was the world's, six hours once the budget is
    /// spent) and by a provisional answer; nil when nothing is owed. Reset by an AI
    /// configuration change.
    public var nextAttemptAtMs: Int64?
    /// Consecutive final-pass failures that were NOT the input's fault; drives their backoff.
    public var transientFailures: Int
    /// Which pieces of which segments this was written from (`ConversationSourceKey`) — nil on
    /// rows written before it was recorded. A conversation's id stays with its first part when
    /// it is cut, so without this a final title would follow the id onto audio it never
    /// described. `EnrichmentWorker` treats a final annotation whose key no longer describes
    /// the conversation as not final, and writes it again.
    public var sourceKey: String?
    /// Set when the PERSON typed the title (`AnnotationStore.setUserTitle`), to the time they
    /// did. While it is set the title is theirs: regeneration refreshes the summary and the
    /// tags and leaves the title alone, and `AnnotationStore.save` will not overwrite it with
    /// an unmarked one.
    public var titleEditedAtMs: Int64?

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
        finalAttempts: Int = 0,
        nextAttemptAtMs: Int64? = nil,
        transientFailures: Int = 0,
        sourceKey: String? = nil,
        titleEditedAtMs: Int64? = nil
    ) {
        self.nextAttemptAtMs = nextAttemptAtMs
        self.transientFailures = transientFailures
        self.sourceKey = sourceKey
        self.titleEditedAtMs = titleEditedAtMs
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
                // The retry bookkeeping `AiRetryPolicy` needs (2026-09-29): when the final pass
                // may run again, and how many failures in a row were the world's rather than the
                // input's.
                ("nextAttemptAtMs", "INTEGER"),
                ("transientFailures", "INTEGER NOT NULL DEFAULT 0"),
            ]
            for column in additions where !existing.contains(column.name) {
                try db.execute(
                    sql: "ALTER TABLE annotations ADD COLUMN \(column.name) \(column.definition)")
            }
        }
    }

    /// Saves (upserts) the annotation, stamping `updatedAtMs` (KMP `save` stamped
    /// `createdAtMs` the same way). Returns the stamped value.
    ///
    /// A title the person typed is never lost to a save that does not know about it: where the
    /// stored row carries `titleEditedAtMs` and the saved value does not, the stored title and
    /// its mark are kept and everything else is written. The worker reads an annotation, waits
    /// on a provider for seconds, and then saves; a rename that lands in between would
    /// otherwise be overwritten by the title the model was already writing. (The returned value
    /// is what was handed in, so in that one case its title is not the stored one.)
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
                        modelUsed, attempts, lastError, nextAttemptAtMs, transientFailures,
                        sourceKey, titleEditedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET
                        title = CASE
                            WHEN annotations.titleEditedAtMs IS NOT NULL
                                AND excluded.titleEditedAtMs IS NULL
                            THEN annotations.title ELSE excluded.title END,
                        titleEditedAtMs =
                            COALESCE(excluded.titleEditedAtMs, annotations.titleEditedAtMs),
                        sourceKey = excluded.sourceKey,
                        summary = excluded.summary,
                        tagsJson = excluded.tagsJson, isFinal = excluded.isFinal,
                        sourceCharCount = excluded.sourceCharCount,
                        finalAttempts = excluded.finalAttempts,
                        updatedAtMs = excluded.updatedAtMs, modeUsed = excluded.modeUsed,
                        providerId = excluded.providerId, modelUsed = excluded.modelUsed,
                        attempts = excluded.attempts, lastError = excluded.lastError,
                        nextAttemptAtMs = excluded.nextAttemptAtMs,
                        transientFailures = excluded.transientFailures
                    """,
                arguments: [
                    toStore.conversationId, toStore.title, toStore.summary, tagsJson,
                    toStore.isFinal, toStore.sourceCharCount, toStore.finalAttempts,
                    toStore.updatedAtMs, toStore.modeUsed?.rawValue, toStore.providerId,
                    toStore.modelUsed, toStore.attempts, toStore.lastError,
                    toStore.nextAttemptAtMs, toStore.transientFailures,
                    toStore.sourceKey, toStore.titleEditedAtMs,
                ]
            )
            // `tagsJson` is the PROPOSAL; the Library's chips, tag filter, row/detail pills and
            // Search all read `conversation_tags`. Adopting here — in the annotation's own
            // transaction — is what makes the generated tags exist for the person rather than
            // only in a column nothing filters on. Unchanged proposals write nothing, so a
            // re-save does not churn every library observation.
            try TagStore.applyAiTags(
                db, conversationId: toStore.conversationId, names: toStore.tags)
        }
        return stamped
    }

    /// The person names a conversation. One write, so it cannot lose a summary the worker saved
    /// a moment earlier the way a load-modify-save from the UI could: only the title and its
    /// mark change, and a conversation with no annotation yet gets a row holding just those.
    ///
    /// The mark is what makes the name stick. Every later regeneration — a provisional refresh
    /// while the conversation is live, the final pass, a re-title after its pieces changed —
    /// keeps a marked title and rewrites only the summary and tags, and `ConversationReconciler`
    /// carries a marked title to the conversation that takes over when this one's id goes.
    ///
    /// `updatedAtMs` is left alone on an existing row: it anchors the worker's refresh and
    /// retry clocks, and a rename is not a generation.
    @discardableResult
    public func setUserTitle(
        _ title: String, conversationId: String
    ) async throws -> ConversationAnnotation {
        let now = nowMs()
        return try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO annotations (conversationId, title, titleEditedAtMs, updatedAtMs)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET
                        title = excluded.title, titleEditedAtMs = excluded.titleEditedAtMs
                    """,
                arguments: [conversationId, title, now, now])
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM annotations WHERE conversationId = ?",
                arguments: [conversationId])
            return row.map(Self.annotation(from:))
                ?? ConversationAnnotation(
                    conversationId: conversationId, title: title, updatedAtMs: now,
                    titleEditedAtMs: now)
        }
    }

    public func load(_ conversationId: String) async throws -> ConversationAnnotation? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM annotations WHERE conversationId = ?",
                arguments: [conversationId]
            ).map(Self.annotation(from:))
        }
    }

    /// Every annotation, by conversation — one read where a pass used to make one per
    /// conversation.
    public func all() async throws -> [String: ConversationAnnotation] {
        try await db.reader.read { db in
            var out: [String: ConversationAnnotation] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM annotations") {
                let annotation = Self.annotation(from: row)
                out[annotation.conversationId] = annotation
            }
            return out
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

    /// Every conversation's final-pass budget and backoff start over — the AI configuration
    /// changed (a key, a mode, a model, a held account taking work again), so what failed may
    /// now succeed. Content is untouched: a provisional title stays on screen until the final
    /// pass replaces it.
    public func resetRetryBudgets() async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE annotations SET finalAttempts = 0, nextAttemptAtMs = NULL,
                        transientFailures = 0
                    WHERE finalAttempts > 0 OR nextAttemptAtMs IS NOT NULL
                        OR transientFailures > 0
                    """)
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
            finalAttempts: row["finalAttempts"],
            nextAttemptAtMs: row["nextAttemptAtMs"],
            transientFailures: row["transientFailures"] ?? 0,
            sourceKey: row["sourceKey"],
            titleEditedAtMs: row["titleEditedAtMs"]
        )
    }
}
