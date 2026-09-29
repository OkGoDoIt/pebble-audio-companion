import AppDB
import Foundation
import GRDB
import SegmentStore
import Transcription

// Pass one of two: read ONE finished conversation and propose what it might contain.
//
// Nothing this worker writes reaches the person. It writes CANDIDATES, and `FollowUpCurator`
// decides. The split exists because the two jobs need different things in front of them: this
// one needs the whole transcript (so a loop that opens at 2pm and closes at 4pm is visibly
// closed), and curation needs every conversation's proposals at once (so the same errand said
// on Tuesday and again on Thursday is one item, and nine proposals from one sitting become
// two).
//
// Cost shape: at most one provider call per conversation per transcript revision, only for a
// closed and fully transcribed conversation, and only for one recorded inside
// `freshnessWindowMs`. The last of those is a product rule as much as a budget one — this list
// is about what is live in someone's life now, and a commitment from six weeks ago that
// nobody has thought about since is not.

/// Durable bookkeeping for follow-up extraction, one row per conversation.
///
/// This is what makes "this conversation legitimately has nothing" a settled, free answer
/// instead of a provider call repeated on every pass forever. DERIVED state: dropping the
/// table only costs a re-extraction.
public struct FollowUpExtractionState: Equatable, Sendable {
    public var conversationId: String
    /// Combined transcript length the last attempt ran over. A different length means the
    /// transcript materially changed (a reprocess landed), so the answer is re-derived and the
    /// attempt budget starts over.
    public var sourceCharCount: Int
    /// True once an extraction completed — including one that found nothing.
    public var settled: Bool
    public var itemCount: Int
    /// Failed attempts at THIS `sourceCharCount` that failed ON THE INPUT, so a broken provider
    /// cannot spin. A failure that was the world's (offline, a broke account) is not counted —
    /// see `AiRetryPolicy`.
    public var attempts: Int
    public var lastError: String?
    public var updatedAtMs: Int64
    /// Extraction does not run before this: set by every failure and by a provisional answer.
    public var nextAttemptAtMs: Int64?
    /// Consecutive failures that were not the input's fault; drives their backoff.
    public var transientFailures: Int

    public init(
        conversationId: String,
        sourceCharCount: Int = 0,
        settled: Bool = false,
        itemCount: Int = 0,
        attempts: Int = 0,
        lastError: String? = nil,
        updatedAtMs: Int64 = 0,
        nextAttemptAtMs: Int64? = nil,
        transientFailures: Int = 0
    ) {
        self.conversationId = conversationId
        self.sourceCharCount = sourceCharCount
        self.settled = settled
        self.itemCount = itemCount
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAtMs = updatedAtMs
        self.nextAttemptAtMs = nextAttemptAtMs
        self.transientFailures = transientFailures
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
            // The retry bookkeeping `AiRetryPolicy` needs, added in place so a table created by
            // an earlier build picks it up.
            let existing = Set(try db.columns(in: "follow_up_extractions").map(\.name))
            let additions: [(name: String, definition: String)] = [
                ("nextAttemptAtMs", "INTEGER"),
                ("transientFailures", "INTEGER NOT NULL DEFAULT 0"),
            ]
            for column in additions where !existing.contains(column.name) {
                try db.execute(
                    sql: "ALTER TABLE follow_up_extractions ADD COLUMN "
                        + "\(column.name) \(column.definition)")
            }
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
                         lastError, updatedAtMs, nextAttemptAtMs, transientFailures)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversationId) DO UPDATE SET
                        sourceCharCount = excluded.sourceCharCount,
                        settled = excluded.settled, itemCount = excluded.itemCount,
                        attempts = excluded.attempts, lastError = excluded.lastError,
                        updatedAtMs = excluded.updatedAtMs,
                        nextAttemptAtMs = excluded.nextAttemptAtMs,
                        transientFailures = excluded.transientFailures
                    """,
                arguments: [
                    state.conversationId, state.sourceCharCount, state.settled, state.itemCount,
                    state.attempts, state.lastError, state.updatedAtMs, state.nextAttemptAtMs,
                    state.transientFailures,
                ])
        }
    }

    /// Every unsettled conversation's budget and backoff start over — the AI configuration
    /// changed, so what failed may now succeed. Settled conversations stay settled.
    public func resetRetryBudgets() async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE follow_up_extractions
                    SET attempts = 0, nextAttemptAtMs = NULL, transientFailures = 0
                    WHERE settled = 0
                    """)
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
            updatedAtMs: row["updatedAtMs"],
            nextAttemptAtMs: row["nextAttemptAtMs"],
            transientFailures: row["transientFailures"] ?? 0
        )
    }
}

/// What the worker knows about a conversation beyond its member segments.
public struct FollowUpConversationContext: Sendable, Equatable {
    public let title: String?
    public let summary: String?

    public init(title: String?, summary: String?) {
        self.title = title
        self.summary = summary
    }
}

/// Reads finished conversations and proposes follow-up candidates.
public final class FollowUpWorker: @unchecked Sendable {
    /// Failed attempts per transcript revision before the conversation is left alone.
    public static let maxAttempts = 2

    /// How long a conversation that used up its attempts waits before being tried again.
    ///
    /// Without this, two passes during a revoked key, a flight, or a rate limit cost those
    /// conversations their follow-ups for the life of the database: the budget only reset when
    /// the transcript's length changed, and nothing else ever re-enabled them.
    public static let retryAfterMs: Int64 = 6 * 60 * 60 * 1000

    /// Conversations actually sent to the provider per pass. Newest-first ordering means a
    /// conversation that just finished is never stuck behind a migrated backlog.
    public static let maxPerPass = 3

    /// Below this much combined text there is nothing an extraction could honestly find, so the
    /// conversation settles at zero items without costing a call.
    public static let minChars = 200

    /// How far back extraction reaches. A conversation older than this settles at zero without
    /// a call.
    ///
    /// Deliberately the SAME span as `FollowUpCurator.staleAfterMs`. Anything found in an
    /// older recording would be filed away by the age rule the moment it appeared, so reading
    /// those conversations could only ever produce something nobody would see — and on a
    /// migrated library it is the difference between a few dozen provider calls and a few
    /// hundred. A commitment nobody has thought about in a fortnight is history, and history
    /// is what Ask and the Library are for.
    public static let freshnessWindowMs: Int64 = 14 * 24 * 60 * 60 * 1000

    /// Transcript characters sent in one call. Well inside every catalogue model's window; the
    /// cap exists so a four-hour conversation cannot quietly become the most expensive call the
    /// app makes.
    public static let maxTranscriptChars = 120_000

    /// Extraction runs on a stronger model than the user's global choice, and with more
    /// thinking. It is one call per conversation, it decides what appears on a list the person
    /// is meant to trust, and the cheap model's failure mode here is exactly the one that makes
    /// the feature worth turning off: reading ambient chatter as commitments.
    public static let modelId = "gpt-5.6-terra"
    public static let reasoningEffort = "medium"

    private let candidates: FollowUpCandidateStore
    private let state: FollowUpExtractionStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64
    private let timeZone: @Sendable () -> TimeZone
    private let contextOf: @Sendable (String) async -> FollowUpConversationContext?
    private let transcriptVersionOf: @Sendable (String) -> String?

    /// The combined transcript length last computed for a conversation, by membership key.
    /// Freshness is judged on that length, and computing it means reading and JSON-decoding
    /// every member transcript; without the memo every pass did that for every finished
    /// conversation in the library, settled or not (see `EnrichmentWorker`).
    private struct Measured: Equatable {
        let key: String
        let combined: Int
    }
    private let measured = TranscriptMemo<Measured>()

    public init(
        candidates: FollowUpCandidateStore,
        state: FollowUpExtractionStore,
        router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        contextOf: @escaping @Sendable (String) async -> FollowUpConversationContext? =
            { _ in nil },
        transcriptVersionOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.candidates = candidates
        self.state = state
        self.router = router
        self.nowMs = nowMs
        self.timeZone = timeZone
        self.contextOf = contextOf
        self.transcriptVersionOf = transcriptVersionOf
    }

    /// Drops the extraction bookkeeping for a conversation that no longer exists, so the
    /// derived table does not accumulate a row per deleted conversation forever.
    public func forgetExtraction(conversationId: String) async {
        try? await state.delete(conversationId)
        try? await candidates.deleteForConversation(conversationId: conversationId)
    }

    /// Runs one bounded extraction pass. Returns the number of candidates newly proposed.
    @discardableResult
    public func extract(
        _ conversations: [EnrichmentConversation],
        transcriptOf: (String) -> SegmentTranscript?
    ) async throws -> Int {
        guard let activeRouter = router else { return 0 }
        guard await activeRouter.isAvailable() else { return 0 }

        let ordered = conversations.sorted(by: EnrichmentWorker.newestFirst)
        let settledStates = try await state.all()
        let now = nowMs()

        var proposed = 0
        var calls = 0
        for conversation in ordered {
            try Task.checkCancellation()
            if calls >= Self.maxPerPass { break }
            let existing = settledStates[conversation.conversationId]
            // Same inputs as last time, and a state that says nothing to do: answer without
            // opening a single transcript. This is the steady state of every finished
            // conversation in the library, on every pass.
            let key = EnrichmentWorker.membershipKey(
                conversation, transcriptVersionOf: transcriptVersionOf)
            if let existing, let key,
                let last = measured.value(conversation.conversationId), last.key == key,
                last.combined == existing.sourceCharCount
            {
                if existing.settled { continue }
                if let next = existing.nextAttemptAtMs, now < next { continue }
                if existing.attempts >= Self.maxAttempts,
                    now - existing.updatedAtMs < Self.retryAfterMs
                {
                    continue
                }
            }
            guard let parts = partsIfDue(conversation, transcriptOf: transcriptOf) else {
                continue
            }
            let combined = parts.map(\.text).joined(separator: "\n\n").count
            if let key {
                measured.remember(
                    conversation.conversationId, key: Measured(key: key, combined: combined))
            }
            // A different transcript length is a different question: start the budget over.
            let fresh = existing.map { $0.sourceCharCount != combined } ?? true
            if let existing, !fresh {
                if existing.settled { continue }
                // Waiting out a backoff: a failure or a provisional answer set it.
                if let next = existing.nextAttemptAtMs, now < next { continue }
                // Out of attempts, but a provider outage is temporary and a conversation is
                // not: come back to it after `retryAfterMs` rather than abandoning it forever.
                if existing.attempts >= Self.maxAttempts,
                    now - existing.updatedAtMs < Self.retryAfterMs
                {
                    continue
                }
            }

            // Too little text, or too long ago — settle for free rather than asking every pass
            // for the rest of time.
            let startedAtMs = parts.first?.startedAtMs ?? 0
            let tooOld = now - startedAtMs > Self.freshnessWindowMs
            if combined < Self.minChars || tooOld {
                try await state.save(
                    FollowUpExtractionState(
                        conversationId: conversation.conversationId,
                        sourceCharCount: combined, settled: true, itemCount: 0,
                        attempts: fresh ? 0 : (existing?.attempts ?? 0),
                        updatedAtMs: now))
                continue
            }

            calls += 1
            let exhausted = (existing?.attempts ?? 0) >= Self.maxAttempts
            // A cooled-off retry starts the budget over; anything else keeps counting.
            let priorAttempts = fresh || exhausted ? 0 : (existing?.attempts ?? 0)
            proposed += try await run(
                activeRouter, conversation, parts: parts, combined: combined,
                priorAttempts: priorAttempts,
                priorTransientFailures: fresh ? 0 : (existing?.transientFailures ?? 0))
        }
        return proposed
    }

    /// Every unsettled conversation's budget and backoff start over — the AI configuration
    /// changed, so a conversation that failed may now be read.
    public func resetRetryBudgets() async {
        try? await state.resetRetryBudgets()
    }

    // MARK: - Planning

    /// The member recordings to read, or nil when the conversation is not a candidate.
    /// Same gate as `EnrichmentWorker`'s final pass: closed, non-empty, every member terminal.
    private func partsIfDue(
        _ conversation: EnrichmentConversation,
        transcriptOf: (String) -> SegmentTranscript?
    ) -> [FollowUpSourcePart]? {
        guard !conversation.isOpen, !conversation.members.isEmpty,
            conversation.members.allSatisfy({ !$0.isOpen && $0.isFullyTranscribed })
        else { return nil }
        let parts: [FollowUpSourcePart] = conversation.members.compactMap { member in
            guard member.transcriptionState == .complete,
                let transcript = transcriptOf(member.segmentId)
            else { return nil }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return FollowUpSourcePart(
                // `startWallMs`, not the raw `startTimeMs`: the latter anchors sample index 0 of
                // the STREAM, so every reattach and every 15-minute rotation successor carries
                // the stream's birth clock instead of its own start. Over the 2026-09-08 backup
                // (774 segments) the two differ on 602 of them, 594 by more than a minute, by a
                // median of 1 h 59 m and up to 24 h 21 m. This value is the day and clock time
                // the model is told the conversation happened at — which is what "tomorrow" and
                // "next Tuesday" inside it resolve against — and it is what `recordedAtMs` on
                // every candidate row becomes, so "play the moment this came from" was aiming at
                // the stream's birth rather than the sentence.
                segmentId: member.segmentId,
                startedAtMs: member.startWallMs,
                text: text,
                turns: transcript.segments)
        }
        return parts.isEmpty ? nil : parts
    }

    // MARK: - Running

    private func run(
        _ router: AiModeRouter,
        _ conversation: EnrichmentConversation,
        parts: [FollowUpSourcePart],
        combined: Int,
        priorAttempts: Int,
        priorTransientFailures: Int
    ) async throws -> Int {
        let now = nowMs()
        let zone = timeZone()
        let attempt = priorAttempts + 1
        let context = await contextOf(conversation.conversationId)
        let body = FollowUpTranscriptRenderer.render(
            parts: parts,
            title: context?.title,
            summary: context?.summary,
            recordedAt: Date(
                timeIntervalSince1970: Double(parts[0].startedAtMs) / 1000),
            timeZone: zone,
            maxChars: Self.maxTranscriptChars)
        do {
            let result = try await router.run(
                AiRunRequest(
                    requestId: "followups-\(conversation.conversationId)-\(attempt)",
                    prompt: AiPromptTemplates.followUpExtraction,
                    transcripts: [
                        TranscriptExcerpt(
                            segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
                    ],
                    metadata: [
                        AiRunRequest.modelKey: Self.modelId,
                        AiRunRequest.reasoningEffortKey: Self.reasoningEffort,
                        AiRunRequest.requiresStructuredOutputKey: "1",
                    ]))
            guard let parsed = FollowUpExtractionParser.parse(raw: result.text) else {
                throw AiError.providerFailed(
                    "Follow-up extraction did not return the agreed JSON", underlying: nil)
            }
            let written = try await persist(
                parsed, conversation: conversation, parts: parts, timeZone: zone, now: now)
            // A fallback that read only part of the conversation found what was in that part —
            // its quotes are real, so the candidates it wrote stay — but it cannot say the rest
            // holds nothing. The conversation is NOT settled; it is read again once the
            // preferred provider can take all of it.
            let provisional = result.isProvisional
            let transient = provisional ? priorTransientFailures + 1 : 0
            try await state.save(
                FollowUpExtractionState(
                    conversationId: conversation.conversationId,
                    sourceCharCount: combined, settled: !provisional, itemCount: written,
                    attempts: priorAttempts,
                    lastError: provisional
                        ? "provisional: \(result.providerId) read part of this conversation"
                        : nil,
                    updatedAtMs: now,
                    nextAttemptAtMs: provisional
                        ? now
                            + max(
                                AiRetryPolicy.provisionalRetryMs,
                                AiRetryPolicy.transientRetryMs(consecutive: transient))
                        : nil,
                    transientFailures: transient))
            return written
        } catch let error where error is CancellationError {
            throw error
        } catch {
            // Only a failure on the input spends an attempt (`AiRetryPolicy`). A revoked key, a
            // flight or a rate limit used to spend both of them in two passes and cost the
            // conversation its follow-ups until the six-hour retry.
            let spends = AiRetryPolicy.spendsAttempt(error)
            let attempts = spends ? attempt : priorAttempts
            let transient = spends ? 0 : priorTransientFailures + 1
            let wait =
                spends
                ? (attempts >= Self.maxAttempts ? Self.retryAfterMs : AiRetryPolicy.contentRetryMs)
                : AiRetryPolicy.transientRetryMs(consecutive: transient)
            try await state.save(
                FollowUpExtractionState(
                    conversationId: conversation.conversationId,
                    sourceCharCount: combined, settled: false, itemCount: 0,
                    attempts: attempts, lastError: Self.errorMessage(error),
                    updatedAtMs: now, nextAttemptAtMs: now + wait,
                    transientFailures: transient))
            return 0
        }
    }

    /// Writes the proposals that are actually grounded.
    ///
    /// The quote is matched back against the member transcripts here, and an item whose words
    /// are not in the recording is DROPPED rather than written with a guess. This is the check
    /// that a schema cannot make and a prompt can only ask for: it turns "quote the words" from
    /// an instruction into a fact about every row that ships.
    private func persist(
        _ items: [ExtractedFollowUp],
        conversation: EnrichmentConversation,
        parts: [FollowUpSourcePart],
        timeZone: TimeZone,
        now: Int64
    ) async throws -> Int {
        var written = 0
        var seen = Set<String>()
        for item in items {
            guard let location = FollowUpQuoteLocator.locate(quote: item.quote, in: parts) else {
                continue
            }
            let id = Self.candidateId(
                conversationId: conversation.conversationId, text: item.task)
            guard seen.insert(id).inserted else { continue }
            try await candidates.save(
                FollowUpCandidate(
                    id: id,
                    conversationId: conversation.conversationId,
                    segmentId: location.segmentId,
                    task: item.task,
                    quote: item.quote,
                    why: item.ifForgotten,
                    confidence: FollowUpConfidence(rawValue: item.confidence) ?? .medium,
                    dueAtMs: Self.dueAtMs(item.dueDate, timeZone: timeZone),
                    startMs: location.startMs,
                    endMs: location.endMs,
                    createdAtMs: now,
                    // When the CONVERSATION happened, which is what "tomorrow" inside it is
                    // relative to. `createdAtMs` is when this pass got round to reading it.
                    recordedAtMs: parts.first?.startedAtMs))
            written += 1
        }
        return written
    }

    /// Start of the named day in the capture time zone. A due date is a day, not an instant —
    /// "Friday" means all of Friday, and stamping noon or midnight-UTC is how an item shows as
    /// overdue on the morning it is actually due.
    static func dueAtMs(_ isoDate: String, timeZone: TimeZone) -> Int64? {
        guard !isoDate.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: isoDate) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// `<conversationId>-action-<contentHash>`. Content-addressed so a re-extraction of the
    /// same conversation lands on the same candidate rather than proposing a duplicate — and
    /// so a candidate curation already decided about is not re-judged forever.
    ///
    /// The `-action-` infix is kept deliberately: rows the old extractor wrote carry it, and
    /// the v5 migration keys their `origin` off it.
    static func candidateId(conversationId: String, text: String) -> String {
        "\(conversationId)-action-\(fnv1a(normalize(text)))"
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so it cannot key a durable row.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func errorMessage(_ error: Error) -> String {
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
