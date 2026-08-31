import Foundation
import GRDB
import AppDB

// Port of `core/ai/AiOutputStore.kt`'s behavioral contract (FileAiOutputStoreTest) against the
// DB: the plan moves persistent AI outputs into the `notes` table (plan 6.5 — notes ARE the
// durable per-run outputs; the Saved Notes flow reads the same rows through NotesStore).
//
// Row mapping: id=outputId · conversationId (from request metadata, "" for scope-level runs
// like Ask) · templateId=promptTemplateId · title=promptTitle · body=text ·
// provider/model/createdAtMs/editedAtMs directly · citations = a JSON payload owned by this
// layer carrying the fields the schema has no column for (requestId, segmentIds, modeUsed,
// token usage, consent). NotesStore-authored rows (citations "[]" or other shapes) do not
// decode as outputs and are invisible to this store, so `deleteAll()` cannot eat user notes.

public struct AiOutput: Equatable, Sendable {
    public let outputId: String
    public let requestId: String
    public let promptTemplateId: String
    public let promptTitle: String
    public let conversationId: String
    public let segmentIds: [String]
    public let text: String
    public let modeUsed: AiProcessingMode
    public let providerId: String
    public let modelUsed: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let createdAtMs: Int64
    public let userConsentedToRemote: Bool
    public let editedAtMs: Int64?

    public init(
        outputId: String, requestId: String, promptTemplateId: String, promptTitle: String,
        conversationId: String = "", segmentIds: [String], text: String,
        modeUsed: AiProcessingMode, providerId: String, modelUsed: String? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil, createdAtMs: Int64,
        userConsentedToRemote: Bool, editedAtMs: Int64? = nil
    ) {
        self.outputId = outputId
        self.requestId = requestId
        self.promptTemplateId = promptTemplateId
        self.promptTitle = promptTitle
        self.conversationId = conversationId
        self.segmentIds = segmentIds
        self.text = text
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.createdAtMs = createdAtMs
        self.userConsentedToRemote = userConsentedToRemote
        self.editedAtMs = editedAtMs
    }
}

/// The citations-column payload: everything AiOutput carries that has no `notes` column.
private struct AiOutputPayload: Codable {
    var requestId: String
    var segmentIds: [String]
    var modeUsed: AiProcessingMode
    var inputTokens: Int?
    var outputTokens: Int?
    var userConsentedToRemote: Bool
}

public struct AiOutputStore: Sendable {
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

    /// Persists one routed AI run. The output id is the request id (reruns of the same request
    /// replace their output). `conversationId` comes from `request.metadata["conversationId"]`
    /// when the run belongs to a conversation.
    @discardableResult
    public func save(
        request: AiRunRequest,
        result: RoutedAiResult,
        userConsentedToRemote: Bool
    ) async throws -> AiOutput {
        var seen = Set<String>()
        let segmentIds = request.transcripts.compactMap {
            seen.insert($0.segmentId).inserted ? $0.segmentId : nil
        }
        let output = AiOutput(
            outputId: request.requestId,
            requestId: request.requestId,
            promptTemplateId: request.prompt.id,
            promptTitle: request.prompt.title,
            conversationId: request.metadata["conversationId"] ?? "",
            segmentIds: segmentIds,
            text: result.text,
            modeUsed: result.modeUsed,
            providerId: result.providerId,
            modelUsed: result.modelUsed,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            createdAtMs: nowMs(),
            userConsentedToRemote: userConsentedToRemote)
        try await write(output)
        return output
    }

    public func load(outputId: String) async throws -> AiOutput? {
        try await db.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ?", arguments: [outputId])
                .flatMap(Self.output(from:))
        }
    }

    /// All outputs, oldest first (KMP `list()` order: sortedBy createdAtMs).
    public func list() async throws -> [AiOutput] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY createdAtMs ASC, id")
                .compactMap(Self.output(from:))
        }
    }

    public func delete(outputId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [outputId])
        }
    }

    /// Replaces the output text and stamps `editedAtMs` (the UI shows edited state).
    @discardableResult
    public func updateText(outputId: String, text: String) async throws -> AiOutput? {
        guard let existing = try await load(outputId: outputId) else { return nil }
        let editedAt = nowMs()
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE notes SET body = ?, editedAtMs = ? WHERE id = ?",
                arguments: [text, editedAt, outputId])
        }
        return AiOutput(
            outputId: existing.outputId, requestId: existing.requestId,
            promptTemplateId: existing.promptTemplateId, promptTitle: existing.promptTitle,
            conversationId: existing.conversationId, segmentIds: existing.segmentIds,
            text: text, modeUsed: existing.modeUsed, providerId: existing.providerId,
            modelUsed: existing.modelUsed, inputTokens: existing.inputTokens,
            outputTokens: existing.outputTokens, createdAtMs: existing.createdAtMs,
            userConsentedToRemote: existing.userConsentedToRemote, editedAtMs: editedAt)
    }

    /// "Clear AI data": removes every row this store wrote. Rows whose citations column is not
    /// an output payload (user/Notes-flow rows) are left alone.
    public func deleteAll() async throws {
        try await db.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, citations FROM notes")
            let outputIds = rows.compactMap { row -> String? in
                let json: String = row["citations"]
                let decodable =
                    (try? JSONDecoder().decode(AiOutputPayload.self, from: Data(json.utf8)))
                    != nil
                return decodable ? row["id"] : nil
            }
            for id in outputIds {
                try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
            }
        }
    }

    // MARK: - Row codec

    private func write(_ output: AiOutput) async throws {
        let payload = AiOutputPayload(
            requestId: output.requestId,
            segmentIds: output.segmentIds,
            modeUsed: output.modeUsed,
            inputTokens: output.inputTokens,
            outputTokens: output.outputTokens,
            userConsentedToRemote: output.userConsentedToRemote)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let citationsJson = String(decoding: try encoder.encode(payload), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes (id, conversationId, templateId, title, body, citations,
                        provider, model, createdAtMs, editedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        conversationId = excluded.conversationId,
                        templateId = excluded.templateId, title = excluded.title,
                        body = excluded.body, citations = excluded.citations,
                        provider = excluded.provider, model = excluded.model,
                        createdAtMs = excluded.createdAtMs, editedAtMs = excluded.editedAtMs
                    """,
                arguments: [
                    output.outputId, output.conversationId, output.promptTemplateId,
                    output.promptTitle, output.text, citationsJson, output.providerId,
                    output.modelUsed, output.createdAtMs, output.editedAtMs,
                ]
            )
        }
    }

    static func output(from row: Row) -> AiOutput? {
        let json: String = row["citations"]
        guard
            let payload = try? JSONDecoder().decode(AiOutputPayload.self, from: Data(json.utf8))
        else { return nil }
        guard let provider: String = row["provider"] else { return nil }
        return AiOutput(
            outputId: row["id"],
            requestId: payload.requestId,
            promptTemplateId: row["templateId"],
            promptTitle: row["title"],
            conversationId: row["conversationId"],
            segmentIds: payload.segmentIds,
            text: row["body"],
            modeUsed: payload.modeUsed,
            providerId: provider,
            modelUsed: row["model"],
            inputTokens: payload.inputTokens,
            outputTokens: payload.outputTokens,
            createdAtMs: row["createdAtMs"],
            userConsentedToRemote: payload.userConsentedToRemote,
            editedAtMs: row["editedAtMs"])
    }
}
