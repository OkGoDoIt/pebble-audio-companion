import AppDB
import Foundation
import GRDB
import SegmentStore
import Transcription

// The half of plan Part 4.5 "Follow-ups" that was missing: something that actually CALLS the
// extractor. `FollowUps.swift` (the schema, the strict/lenient parser, `ActionItemStore`) was
// ported whole and then referenced by nothing, so every conversation honestly reported "All
// caught up." — nothing had ever written a follow-up. This worker is the seam that closes it,
// shaped after `EnrichmentWorker`: the same conversation input, the same "is this worth a
// provider call yet" planning, the same bounded-attempts posture.
//
// Cost shape (deliberate, see the plan's 55-items-vs-331-annotations note): extraction is its
// OWN provider call, made at most once per conversation per transcript revision, and only for
// a CLOSED, fully transcribed conversation. It is not merged into the annotation call because
// the annotation runs repeatedly while a conversation is still live, and follow-ups extracted
// from half-heard partial text would be wrong far more often than they would be cheap.

/// Durable bookkeeping for follow-up extraction, one row per conversation.
///
/// This is what makes "this conversation legitimately has no follow-ups" a settled, free
/// answer instead of a provider call repeated on every pass forever. DERIVED state: dropping
/// the table only costs a re-extraction.
public struct FollowUpExtractionState: Equatable, Sendable {
    public var conversationId: String
    /// Combined transcript length the last attempt ran over. A different length means the
    /// transcript materially changed (a reprocess landed), so the answer is re-derived and the
    /// attempt budget starts over.
    public var sourceCharCount: Int
    /// True once an extraction completed — including one that found nothing.
    public var settled: Bool
    public var itemCount: Int
    /// Failed attempts at THIS `sourceCharCount`, so a broken provider cannot spin.
    public var attempts: Int
    public var lastError: String?
    public var updatedAtMs: Int64

    public init(
        conversationId: String,
        sourceCharCount: Int = 0,
        settled: Bool = false,
        itemCount: Int = 0,
        attempts: Int = 0,
        lastError: String? = nil,
        updatedAtMs: Int64 = 0
    ) {
        self.conversationId = conversationId
        self.sourceCharCount = sourceCharCount
        self.settled = settled
        self.itemCount = itemCount
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAtMs = updatedAtMs
    }
}

/// Storage for `FollowUpExtractionState`. Creates its own table idempotently on init, the same
/// way `AnnotationStore` adds its own bookkeeping columns, so an already-migrated database
/// picks it up without a coordinated AppDB schema change.
public struct FollowUpExtractionStore: Sendable {
    public let db: AppDatabase

    public init(db: AppDatabase) throws {
        self.db = db
        try db.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS follow_up_extractions (
                        conversationId TEXT PRIMARY KEY,
                        sourceCharCount INTEGER NOT NULL DEFAULT 0,
                        settled BOOLEAN NOT NULL DEFAULT 0,
                        itemCount INTEGER NOT NULL DEFAULT 0,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        lastError TEXT,
                        updatedAtMs INTEGER NOT NULL DEFAULT 0
                    )
                    """)
        }
    }

    public func load(_ conversationId: String) async throws -> FollowUpExtractionState? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM follow_up_extractions WHERE conversationId = ?",
                arguments: [conversationId]
            ).map(Self.state(from:))
        }
    }

    /// Every row, keyed by conversation. One read per pass beats one read per conversation when
    /// a migrated library hands the worker ~178 of them on every single pass.
    public func all() async throws -> [String: FollowUpExtractionState] {
        let rows = try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM follow_up_extractions").map(Self.state(from:))
        }
        return Dictionary(rows.map { ($0.conversationId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func save(_ state: FollowUpExtractionState) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO follow_up_extractions
                        (conversationId, sourceCharCount, settled, itemCount, attempts,
                         lastError, updatedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET
                        sourceCharCount = excluded.sourceCharCount,
                        settled = excluded.settled, itemCount = excluded.itemCount,
                        attempts = excluded.attempts, lastError = excluded.lastError,
                        updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [
                    state.conversationId, state.sourceCharCount, state.settled, state.itemCount,
                    state.attempts, state.lastError, state.updatedAtMs,
                ])
        }
    }

    public func delete(_ conversationId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM follow_up_extractions WHERE conversationId = ?",
                arguments: [conversationId])
        }
    }

    /// Conversations still awaiting a first extraction is not derivable from this table alone
    /// (unseen conversations have no row), so the count of settled ones is what callers get.
    public func settledCount() async throws -> Int {
        try await db.reader.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM follow_up_extractions WHERE settled = 1") ?? 0
        }
    }

    static func state(from row: Row) -> FollowUpExtractionState {
        FollowUpExtractionState(
            conversationId: row["conversationId"],
            sourceCharCount: row["sourceCharCount"],
            settled: row["settled"],
            itemCount: row["itemCount"],
            attempts: row["attempts"],
            lastError: row["lastError"],
            updatedAtMs: row["updatedAtMs"]
        )
    }
}

/// Extracts follow-ups from finished conversations and persists them through
/// `ActionItemStore` into `follow_ups`.
public final class FollowUpWorker: @unchecked Sendable {
    /// Failed attempts per transcript revision before the conversation is left alone.
    public static let maxAttempts = 2

    /// Conversations considered per pass. Roger's migrated library arrives as ~178 conversations
    /// with transcripts and no follow-ups; without a cap the first foreground pass would fire
    /// 178 provider calls back to back. Newest-first ordering means a conversation that just
    /// finished is never stuck behind the backlog.
    public static let maxPerPass = 5

    /// Below this much combined text there is nothing an extraction could honestly find, so the
    /// conversation settles at zero items without costing a call.
    public static let minChars = 120

    private let items: ActionItemStore
    private let state: FollowUpExtractionStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64

    public init(
        items: ActionItemStore,
        state: FollowUpExtractionStore,
        router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64
    ) {
        self.items = items
        self.state = state
        self.router = router
        self.nowMs = nowMs
    }

    /// Drops the extraction bookkeeping for a conversation that no longer exists, so the
    /// derived table does not accumulate a row per deleted conversation forever.
    public func forgetExtraction(conversationId: String) async {
        try? await state.delete(conversationId)
    }

    /// Runs one bounded extraction pass. Returns the items newly written this pass (so the
    /// caller can donate exactly those to the search index).
    public func extract(
        _ conversations: [EnrichmentConversation],
        transcriptOf: (String) -> SegmentTranscript?
    ) async throws -> [ActionItem] {
        guard let activeRouter = router else { return [] }
        guard await activeRouter.isAvailable() else { return [] }

        // Newest first: a conversation that closed a minute ago must not wait behind a
        // migrated backlog. Same ordering rule the annotation backlog uses.
        let ordered = conversations.sorted(by: EnrichmentWorker.newestFirst)
        let settledStates = try await state.all()

        var written: [ActionItem] = []
        var calls = 0
        for conversation in ordered {
            try Task.checkCancellation()
            if calls >= Self.maxPerPass { break }
            guard let excerpts = excerptsIfDue(conversation, transcriptOf: transcriptOf) else {
                continue
            }
            let combined = combinedLength(excerpts)
            let existing = settledStates[conversation.conversationId]
            // A different transcript length is a different question: start the budget over.
            let fresh = existing.map { $0.sourceCharCount != combined } ?? true
            if let existing, !fresh {
                if existing.settled { continue }
                if existing.attempts >= Self.maxAttempts { continue }
            }

            // Too little text to be worth a call — settle it for free rather than asking
            // every pass for the rest of time.
            if combined < Self.minChars {
                try await state.save(
                    FollowUpExtractionState(
                        conversationId: conversation.conversationId,
                        sourceCharCount: combined, settled: true, itemCount: 0,
                        attempts: fresh ? 0 : (existing?.attempts ?? 0),
                        updatedAtMs: nowMs()))
                continue
            }

            calls += 1
            let attempts = (fresh ? 0 : (existing?.attempts ?? 0)) + 1
            written.append(
                contentsOf: try await run(
                    activeRouter, conversation, excerpts: excerpts, combined: combined,
                    attempts: attempts))
        }
        return written
    }

    // MARK: - Planning

    /// The member excerpts to extract from, or nil when the conversation is not a candidate.
    /// Same gate as `EnrichmentWorker`'s final pass: closed, non-empty, every member terminal.
    private func excerptsIfDue(
        _ conversation: EnrichmentConversation,
        transcriptOf: (String) -> SegmentTranscript?
    ) -> [TranscriptExcerpt]? {
        guard !conversation.isOpen, !conversation.members.isEmpty,
            conversation.members.allSatisfy({ !$0.isOpen && $0.isFullyTranscribed })
        else { return nil }
        let excerpts: [TranscriptExcerpt] = conversation.members.compactMap { member in
            guard member.transcriptionState == .complete,
                let text = transcriptOf(member.segmentId)?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { return nil }
            return TranscriptExcerpt(
                segmentId: member.segmentId, text: text, startTimeMs: Int64(member.startTimeMs))
        }
        return excerpts.isEmpty ? nil : excerpts
    }

    private func combinedLength(_ excerpts: [TranscriptExcerpt]) -> Int {
        excerpts.map(\.text).joined(separator: "\n\n").count
    }

    // MARK: - Running

    private func run(
        _ router: AiModeRouter,
        _ conversation: EnrichmentConversation,
        excerpts: [TranscriptExcerpt],
        combined: Int,
        attempts: Int
    ) async throws -> [ActionItem] {
        let now = nowMs()
        do {
            // `AiPromptTemplates.actionItems` is what the providers key their STRICT
            // `action_items` json_schema off (OpenAiChatAiProvider.responseTextConfig), so this
            // template id is the structured-output path. The parser's lenient branch stays the
            // last resort for text-only providers, and it REJECTS residual markdown rather than
            // cleaning it (anti-goal B4).
            let result = try await router.run(
                AiRunRequest(
                    requestId: "followups-\(conversation.conversationId)-\(attempts)",
                    prompt: AiPromptTemplates.actionItems,
                    transcripts: excerpts))
            let parsed = ActionItemParser.parse(
                raw: result.text,
                sourceSegmentId: excerpts[0].segmentId,
                nowMs: now,
                idPrefix: conversation.conversationId)
            let saved = try await persist(
                parsed, conversation: conversation,
                memberIds: Set(conversation.members.map(\.segmentId)),
                fallbackSegmentId: excerpts[0].segmentId, now: now)
            try await state.save(
                FollowUpExtractionState(
                    conversationId: conversation.conversationId,
                    sourceCharCount: combined, settled: true, itemCount: parsed.count,
                    attempts: attempts, updatedAtMs: now))
            return saved
        } catch let error where error is CancellationError {
            throw error
        } catch {
            try await state.save(
                FollowUpExtractionState(
                    conversationId: conversation.conversationId,
                    sourceCharCount: combined, settled: false, itemCount: 0,
                    attempts: attempts, lastError: Self.errorMessage(error),
                    updatedAtMs: now))
            return []
        }
    }

    /// Writes the parsed items, re-keyed by CONTENT so a re-extraction of the same conversation
    /// lands on the same rows. Two consequences, both deliberate:
    ///  - the same task text can never appear twice for one conversation, however many passes
    ///    run over it;
    ///  - a row the user already ticked keeps `done` (the store's upsert leaves the column
    ///    alone, and a genuinely new row is written open).
    ///
    /// Items from a previous extraction that this one no longer produces are LEFT IN PLACE.
    /// `follow_ups` is authoritative user-facing state; quietly deleting something the user may
    /// already have acted on is worse than carrying one stale item.
    private func persist(
        _ parsed: [ActionItem],
        conversation: EnrichmentConversation,
        memberIds: Set<String>,
        fallbackSegmentId: String,
        now: Int64
    ) async throws -> [ActionItem] {
        var saved: [ActionItem] = []
        var seen = Set<String>()
        for item in parsed {
            var row = item
            row.id = Self.itemId(conversationId: conversation.conversationId, text: item.text)
            guard seen.insert(row.id).inserted else { continue }
            row.sourceConversationId = conversation.conversationId
            // The structured schema lets the model name a source segment, and a model that
            // invents one would strand the row: `DeleteCascade` removes follow-ups by
            // `sourceSegmentId`, so an id that belongs to no member survives its own recording.
            if !memberIds.contains(row.sourceSegmentId) {
                row.sourceSegmentId = fallbackSegmentId
            }
            row.createdAtMs = now
            let existed = try await items.load(id: row.id) != nil
            try await items.save(row)
            if !existed { saved.append(row) }
        }
        return saved
    }

    /// `<conversationId>-action-<contentHash>`: still matches `ActionItemStore`'s
    /// `%-action-%` "extracted, not user-added" pattern, but stable under re-extraction in a
    /// way the parser's positional index is not — a re-run that drops one item must not slide
    /// every later item onto a neighbour's row (and its `done` flag).
    static func itemId(conversationId: String, text: String) -> String {
        "\(conversationId)-action-\(fnv1a(normalize(text)))"
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so it cannot key a durable row.
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func errorMessage(_ error: Error) -> String {
        if let aiError = error as? AiError {
            switch aiError {
            case .providerUnavailable(let providerId):
                return "AI provider unavailable: \(providerId)"
            case .consentRequired(let providerId):
                return "AI provider requires consent: \(providerId)"
            case .providerFailed(let message, _):
                return message
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
}
