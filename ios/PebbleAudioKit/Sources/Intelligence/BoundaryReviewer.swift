import AppDB
import Foundation
import GRDB
import SegmentStore
import Transcription

// The OPTIONAL semantic half of conversation splitting (`AppDB/ConversationBoundaries.swift`
// is the structural half). It answers exactly one question, for a short list of joins the
// structure already flagged: after this much quiet, did the recording go on to a different
// subject or different people?
//
// STILL WIRED, NO LONGER FED (2026-09-30). The joins it used to be asked about were the ones
// the structural rules could not settle — a quiet stretch at a segment join, too short to split
// on and too long to ignore. Conversations are now cut between turns, inside the talk, by
// `ConversationSegmenter` (`ConversationUnits.swift`), which decides those places itself from
// the words either side; "a join worth asking a model about" no longer exists as a category.
// `ConversationGrouper.RebuiltGrouping.candidates` is therefore always empty,
// `EnrichmentService.boundaryReviewPass` returns 0 without touching the provider, and no call
// is ever made. The type, its verdict cache (`boundary_reviews`) and its retry bookkeeping stay
// as they are: deleting them is a separate decision, and nothing here costs anything idle.
//
// Four properties it must keep, in the order they matter:
//
//  1. NEVER REQUIRED. With no router, no available provider, or the whole AI layer off, this
//     type does nothing and the grouping is the structural one. Nothing downstream may assume
//     a verdict exists.
//  2. IT CANNOT INVENT A BOUNDARY. Its input is a candidate list the GROUPER hands it
//     (`ConversationGrouper.RebuiltGrouping.candidates` — once the joins with 8–25 minutes of
//     settled quiet around them, now nothing). It is never given continuous speech to split,
//     and a verdict only ever confirms or dismisses a place the grouper named.
//  3. CHEAP AND BATCHED. One provider call carries up to `maxPerCall` candidates, and verdicts
//     are cached in `boundary_reviews` so a candidate is asked about once. Measured over three
//     months of real capture the whole work list is ~23 candidates a month.
//  4. CONSERVATIVE ON FAILURE. Anything that does not parse, or any candidate the model omits,
//     leaves the join alone — the recording stays one conversation, which is what it was.

/// The pieces of transcript the reviewer reads for one candidate. Deliberately small: the last
/// words before the silence and the first words after it are what a person would use.
public struct BoundaryReviewContext: Sendable {
    public var candidate: BoundaryCandidate
    public var before: String
    public var after: String

    public init(candidate: BoundaryCandidate, before: String, after: String) {
        self.candidate = candidate
        self.before = before
        self.after = after
    }
}

/// Model output → verdicts. Strict JSON only; there is deliberately no lenient fallback (the
/// same decision `FollowUpExtractionParser` made after the markdown one leaked field labels).
public enum BoundaryVerdictParser {
    public static let schemaName = "conversation_boundaries"

    struct Payload: Decodable {
        struct Item: Decodable {
            var id: String
            var newConversation: Bool
            var reason: String?
        }
        var boundaries: [Item]
    }

    public struct Verdict: Equatable, Sendable {
        public var id: String
        public var isBoundary: Bool
        public var reason: String?
    }

    public static func parse(raw: String) -> [Verdict]? {
        guard let data = jsonObject(in: raw),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return payload.boundaries.map {
            let reason = $0.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Verdict(
                id: $0.id, isBoundary: $0.newConversation,
                reason: (reason?.isEmpty ?? true) ? nil : String(reason!.prefix(160)))
        }
    }

    /// The first balanced `{…}` in the reply, so a model that wraps its JSON in prose or a
    /// fenced block still parses.
    static func jsonObject(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(raw[start...index]).data(using: .utf8)
                    }
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }
}

/// The prompt lives here rather than in `Prompts.swift` so this feature ships as one unit.
enum BoundaryPromptTemplates {
    static let boundaryReview = AiPromptTemplate(
        id: "conversation-boundary-review",
        title: "Conversation boundaries",
        systemPrompt: """
            You read transcripts of audio captured by an always-on microphone someone wears \
            through their whole day. It is not a meeting recorder: it catches family talk, \
            shops, cars, television, one side of phone calls, dictated notes and long stretches \
            of nothing. Transcription is automatic and often wrong — misheard words, invented \
            words, garbled names.

            The recording has already been cut wherever the microphone stopped or the day went \
            quiet for a long time. You are looking at the leftover cases: places where the \
            record went quiet for several minutes and it is genuinely unclear whether what \
            follows is the SAME occasion continuing or a NEW one.

            For each one, answer one question: after that silence, is this the same \
            conversation, or a different one?

            Say NEW CONVERSATION when the evidence is positive and visible in the words: \
            different people are speaking, the subject has changed completely with no bridge, \
            the setting has plainly changed (a shop, a car, a call), or one side is a goodbye \
            and the other is an opening. A change of language is strong evidence.

            Say SAME CONVERSATION whenever the two sides could plausibly be one occasion: the \
            same people picking a thread back up, a topic that drifted rather than jumped, a \
            pause for food or a task, dictation of the same piece of work, or anything you \
            cannot tell. SAME is the safe answer and the right one when in doubt — a wrongly \
            split conversation is worse for the reader than a slightly long one, because half \
            of it disappears from where they expect to find it.

            Judge only the words you are shown. Never infer a boundary from the length of the \
            silence: you have been told how long it was, and that has already been weighed.
            """,
        userPrompt: """
            Decide, for each numbered gap below, whether the recording after it is a NEW \
            conversation or the SAME one continuing.

            Reply with JSON only, exactly this shape:
            {"boundaries":[{"id":"<the id given>","newConversation":true|false,\
            "reason":"<at most 12 words, only when true>"}]}

            Include every id exactly once. No prose outside the JSON.
            """
    )
}

/// Failed asks per boundary candidate, so a reply that cannot be had is not re-sent every pass.
///
/// The reviewer used to keep no failure memory at all ("there is no failure state to get stuck
/// in"), which made a provider that failed — or a model that returned prose, or skipped a gap —
/// cost a ~20 KB request on EVERY foreground pass, every few seconds, for as long as the app
/// was open. Now each failed ask backs its candidates off (15 minutes, doubling), and after
/// `BoundaryReviewer.maxAttempts` they are left alone until the AI configuration changes
/// (`resetAll`). DERIVED state, created idempotently like `FollowUpExtractionStore`: dropping
/// the table costs a re-ask and nothing else.
public struct BoundaryReviewAttempt: Equatable, Sendable {
    public var segmentId: String
    public var attempts: Int
    public var nextAttemptAtMs: Int64
    public var lastError: String?
}

public struct BoundaryReviewAttemptStore: Sendable {
    public let db: AppDatabase

    public init(db: AppDatabase) throws {
        self.db = db
        try db.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS boundary_review_attempts (
                        segmentId TEXT PRIMARY KEY,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        nextAttemptAtMs INTEGER NOT NULL DEFAULT 0,
                        lastError TEXT
                    )
                    """)
        }
    }

    public func all() async throws -> [String: BoundaryReviewAttempt] {
        try await db.reader.read { db in
            var out: [String: BoundaryReviewAttempt] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM boundary_review_attempts") {
                let attempt = BoundaryReviewAttempt(
                    segmentId: row["segmentId"], attempts: row["attempts"],
                    nextAttemptAtMs: row["nextAttemptAtMs"], lastError: row["lastError"])
                out[attempt.segmentId] = attempt
            }
            return out
        }
    }

    /// One more failed ask for each of `segmentIds`, backed off by `backoffMs(attempts)`.
    public func recordFailure(
        segmentIds: [String], error: String, nowMs: Int64, backoffMs: (Int) -> Int64
    ) async throws {
        guard !segmentIds.isEmpty else { return }
        let existing = try await all()
        let rows: [(id: String, attempts: Int, nextAttemptAtMs: Int64)] = segmentIds.map { id in
            let attempts = (existing[id]?.attempts ?? 0) + 1
            return (id, attempts, nowMs + backoffMs(attempts))
        }
        let reason = String(error.prefix(200))
        try await db.writer.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO boundary_review_attempts
                            (segmentId, attempts, nextAttemptAtMs, lastError)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(segmentId) DO UPDATE SET
                            attempts = excluded.attempts,
                            nextAttemptAtMs = excluded.nextAttemptAtMs,
                            lastError = excluded.lastError
                        """,
                    arguments: [row.id, row.attempts, row.nextAttemptAtMs, reason])
            }
        }
    }

    /// A verdict landed: its candidate owes nothing.
    public func clear(segmentIds: [String]) async throws {
        guard !segmentIds.isEmpty else { return }
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM boundary_review_attempts
                    WHERE segmentId IN (\(databaseQuestionMarks(count: segmentIds.count)))
                    """,
                arguments: StatementArguments(segmentIds))
        }
    }

    /// Every candidate gets a fresh budget — the AI configuration changed, so a different
    /// answer is possible.
    public func resetAll() async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM boundary_review_attempts")
        }
    }
}

/// Asks the model about the joins the structural layer could not settle, and caches the answers.
public final class BoundaryReviewer: @unchecked Sendable {
    /// Candidates carried in one provider call. Enough that a normal backlog clears in a single
    /// call; small enough that one bad reply costs little.
    public static let maxPerCall = 12
    /// Calls per pass. The work list is a couple of dozen a month, so one call is nearly always
    /// the whole of it.
    public static let maxCallsPerPass = 1
    /// Characters of transcript shown either side of a gap. Two or three turns' worth — the
    /// question is "did this continue", not "summarise the hour".
    public static let contextChars = 700
    /// Failed asks before a candidate is left alone until the AI configuration changes. The
    /// grouping stays structural for it meanwhile — which is what it was without the reviewer.
    public static let maxAttempts = 5
    /// 15 minutes, doubling: 15 m, 30 m, 1 h, 2 h, then the candidate rests.
    public static let firstRetryMs: Int64 = 15 * 60_000

    static func retryDelayMs(afterAttempts attempts: Int) -> Int64 {
        firstRetryMs << Int64(min(max(attempts - 1, 0), 8))
    }

    private let reviews: BoundaryReviewStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64
    /// Nil only when the table could not be created; the reviewer then behaves as it always did.
    private let attempts: BoundaryReviewAttemptStore?

    public init(
        reviews: BoundaryReviewStore, router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64
    ) {
        self.reviews = reviews
        self.router = router
        self.nowMs = nowMs
        self.attempts = try? BoundaryReviewAttemptStore(db: reviews.db)
    }

    /// Fresh budgets for every candidate: called when the AI configuration changes, because a
    /// different key, model or mode can answer what the old one could not.
    public func resetRetryBudgets() async {
        try? await attempts?.resetAll()
    }

    /// Reviews what it can and returns the number of verdicts written. Zero is the normal
    /// answer — no router, nothing new to ask about, or a provider that could not be reached.
    @discardableResult
    public func review(
        candidates: [BoundaryCandidate],
        contextFor: (BoundaryCandidate) -> BoundaryReviewContext?
    ) async throws -> Int {
        guard let router, !candidates.isEmpty else { return 0 }
        guard await router.isAvailable() else { return 0 }

        // Newest first, for the same reason enrichment is: a migrated library hands over a
        // whole backlog at once, and the boundary a person is most likely to look at today is
        // the most recent one. A candidate whose last asks failed waits out its backoff, and
        // one that has failed `maxAttempts` times waits for the AI configuration to change.
        let now = nowMs()
        let failed = (try? await attempts?.all()) ?? [:]
        let pending = try await reviews.unreviewed(candidates)
            .filter { candidate in
                guard let record = failed[candidate.newStartSegmentId] else { return true }
                return record.attempts < Self.maxAttempts && now >= record.nextAttemptAtMs
            }
            .sorted { $0.atMs > $1.atMs }
        guard !pending.isEmpty else { return 0 }

        var written = 0
        var calls = 0
        var index = 0
        while index < pending.count, calls < Self.maxCallsPerPass {
            try Task.checkCancellation()
            let batch = Array(pending[index..<min(index + Self.maxPerCall, pending.count)])
            index += batch.count
            let contexts = batch.compactMap(contextFor)
            guard !contexts.isEmpty else { continue }
            calls += 1
            written += try await runBatch(router, contexts)
        }
        return written
    }

    private func runBatch(
        _ router: AiModeRouter, _ contexts: [BoundaryReviewContext]
    ) async throws -> Int {
        let byId = Dictionary(
            uniqueKeysWithValues: contexts.map { ($0.candidate.newStartSegmentId, $0) })
        let body = Self.render(contexts)
        let result: RoutedAiResult
        do {
            result = try await router.run(
                AiRunRequest(
                    requestId: "boundaries-\(contexts.map(\.candidate.newStartSegmentId).joined(separator: ","))",
                    prompt: BoundaryPromptTemplates.boundaryReview,
                    transcripts: [
                        TranscriptExcerpt(
                            segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
                    ],
                    metadata: [
                        AiRunRequest.requiresStructuredOutputKey: "1"
                    ]))
        } catch let error where error is CancellationError {
            throw error
        } catch {
            // A boundary we could not ask about stays where it is — the recording remains one
            // conversation, which is what it was. What changed is that the failure is REMEMBERED:
            // this used to record nothing, so the next pass (seconds later, in the foreground)
            // re-sent the same ~20 KB, forever. Now each candidate in the batch backs off.
            await recordFailure(Array(byId.keys), because: storedFailureMessage(error))
            return 0
        }
        guard let verdicts = BoundaryVerdictParser.parse(raw: result.text) else {
            await recordFailure(Array(byId.keys), because: "reply was not the agreed JSON")
            return 0
        }

        let now = nowMs()
        let rows: [BoundaryReview] = verdicts.compactMap { verdict in
            guard let context = byId[verdict.id] else { return nil }
            return BoundaryReview(
                segmentId: verdict.id,
                isBoundary: verdict.isBoundary,
                quietMs: context.candidate.quietMs,
                reason: verdict.isBoundary ? verdict.reason : nil,
                provider: result.providerId,
                model: result.modelUsed,
                createdAtMs: now
            )
        }
        try await reviews.save(rows)
        try? await attempts?.clear(segmentIds: rows.map(\.segmentId))
        // A candidate the model skipped is as unanswered as one in a failed call, and asking
        // again on the next pass would get the same reply.
        let answered = Set(rows.map(\.segmentId))
        await recordFailure(
            byId.keys.filter { !answered.contains($0) }, because: "reply omitted this gap")
        return rows.count
    }

    private func recordFailure(_ segmentIds: [String], because reason: String) async {
        try? await attempts?.recordFailure(
            segmentIds: segmentIds, error: reason, nowMs: nowMs(),
            backoffMs: Self.retryDelayMs(afterAttempts:))
    }

    /// One block per candidate: how long the silence was, then the words either side of it.
    static func render(_ contexts: [BoundaryReviewContext]) -> String {
        contexts.map { context in
            let quiet = Self.durationPhrase(context.candidate.quietMs)
            let nature = context.candidate.lossFraction > 0.5
                ? "\(quiet), most of it audio the app never received"
                : "\(quiet) with nothing said"
            return """
                --- gap id: \(context.candidate.newStartSegmentId) (\(nature)) ---
                BEFORE THE GAP:
                \(context.before)

                AFTER THE GAP:
                \(context.after)
                """
        }.joined(separator: "\n\n")
    }

    static func durationPhrase(_ ms: Int64) -> String {
        let minutes = max(1, Int(ms / 60_000))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// Builds the reading context for one candidate.
    ///
    /// It reads the members that actually hold the words either side of the silence, NOT the
    /// two members touching the join. A stretch long enough to be a candidate usually swallows
    /// whole rotations, and those are by definition the ones with no text in them; taking the
    /// adjacent members would have handed the model two empty strings and asked it to guess.
    /// Falls back to the join's own members where the stretch is short enough that they are the
    /// same thing.
    ///
    /// Returns nil when there is nothing to read on EITHER side, which drops the candidate from
    /// the batch rather than paying for a call that cannot be answered.
    public static func context(
        for candidate: BoundaryCandidate,
        transcriptOf: (String) -> SegmentTranscript?
    ) -> BoundaryReviewContext? {
        func text(_ segmentId: String?) -> String {
            guard let segmentId else { return "" }
            return transcriptOf(segmentId)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var before = text(candidate.lastSpokenSegmentId)
        if before.isEmpty { before = text(candidate.previousEndSegmentId) }
        var after = text(candidate.nextSpokenSegmentId)
        if after.isEmpty { after = text(candidate.newStartSegmentId) }
        guard !before.isEmpty, !after.isEmpty else { return nil }
        return BoundaryReviewContext(
            candidate: candidate,
            before: String(before.suffix(contextChars)),
            after: String(after.prefix(contextChars))
        )
    }
}
