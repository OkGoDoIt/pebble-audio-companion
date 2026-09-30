import AppDB
import Foundation
import SegmentStore
import Transcription

// Port of `app/.../SegmentEnrichmentWorker.kt`, retargeted from segment to CONVERSATION
// granularity (plan Part 3): same prompts and gates, input = the combined member transcripts,
// output = one row in the AppDB `annotations` table per conversation.

/// One conversation due for consideration this pass: its id, whether it is still live, and
/// its ordered member segments with the PIECE of each it owns (from `conversations` +
/// `conversation_segments`).
///
/// A conversation is a list of pieces, not of segments (`ConversationUnits.swift`): it usually
/// owns only the end of its first segment and the start of its last, and the rest of each
/// belongs to its neighbours. Everything the AI layer reads about a conversation therefore goes
/// through `parts` — a worker that read a member's whole transcript would title ten minutes
/// from a quarter of an hour, and hand two conversations the same sentences.
public struct EnrichmentConversation: Sendable {
    public var conversationId: String
    /// True while the conversation is live (`conversations.state == "live"`). Not derivable
    /// from the members alone: a conversation stays live through the 5-minute join window
    /// after its last segment closes.
    public var isOpen: Bool
    /// Ordered member segment metas (conversation_segments ordinal order).
    public private(set) var members: [SegmentMeta]
    /// The range of each member's stored audio this conversation owns — parallel to `members`,
    /// always the same length.
    public private(set) var pieces: [ConversationMember]

    /// - Parameter pieces: parallel to `members`. Omitted — or, for any member, missing or
    ///   naming another segment — the conversation owns that member whole, which is what a
    ///   conversation made of whole segments is and what the tests of everything that is not
    ///   about ranges construct.
    public init(
        conversationId: String, isOpen: Bool, members: [SegmentMeta],
        pieces: [ConversationMember]? = nil
    ) {
        self.conversationId = conversationId
        self.isOpen = isOpen
        self.members = members
        self.pieces = members.enumerated().map { index, meta in
            if let pieces, index < pieces.count, pieces[index].segmentId == meta.segmentId {
                return pieces[index]
            }
            return ConversationMember(segmentId: meta.segmentId)
        }
    }

    /// Each member with the piece of it this conversation owns, in order.
    public var parts: Zip2Sequence<[SegmentMeta], [ConversationMember]> { zip(members, pieces) }

    /// Which pieces this conversation is made of (`ConversationSourceKey`) — what an annotation
    /// records beside its title so a title cannot follow the id onto different audio.
    public var sourceKey: String { ConversationSourceKey.key(of: pieces) }

    /// Wall-clock time of `mediaMs` into `meta`'s stored audio: through the segment's gap
    /// records where they add up, and as a plain offset where they do not — the convention
    /// `ConversationRunPlanner` places turns by. Offset 0 is the segment's own start without
    /// consulting the clock, so a whole piece with no timings is dated as it always was.
    public static func wallMs(ofMedia mediaMs: Int64, in meta: SegmentMeta) -> Int64 {
        guard mediaMs > 0 else { return meta.startWallMs }
        let clock = SegmentMediaClock(meta)
        return meta.startWallMs + (clock.isExact ? clock.wall(fromMedia: mediaMs) : mediaMs)
    }

    /// When a piece's talk starts on the wall clock: its first turn where the transcript has
    /// timings, the piece's own start where it has none.
    ///
    /// Not the segment's start. A conversation cut out of the middle of a segment began up to
    /// fifteen minutes after that, and this is the time the model is told the talk happened at
    /// — what "tomorrow" inside it resolves against.
    public static func startWallMs(
        of piece: ConversationMember, in meta: SegmentMeta, firstTurnMediaMs: Int64?
    ) -> Int64 {
        wallMs(ofMedia: firstTurnMediaMs ?? piece.startMediaMs ?? 0, in: meta)
    }
}

/// Generates the AI title + summary + proposed tags shown on Today/Library rows.
///
/// What it reads is each conversation's PIECES, never its members' whole transcripts, and a
/// title the person typed (`titleEditedAtMs`) is theirs: every pass below may rewrite the
/// summary and tags around it, none replaces it.
///
/// Two passes per conversation:
///  - **Live/provisional**: while the conversation is still live, summarize the rolling
///    combined text (closed members' durable transcripts + the open member's live preview).
///    The first provisional appears once there is enough text (`liveMinChars`); it is then
///    refreshed only when the text has grown meaningfully (`liveRefreshMinGrowthChars`) AND a
///    minimum interval has elapsed (`liveRefreshMinIntervalMs`) so a long conversation does
///    not hammer the provider.
///  - **Final/authoritative**: once the conversation is closed and every member is fully
///    transcribed, regenerate from the complete durable transcripts and mark the annotation
///    final, overriding any provisional. This runs exactly once on success (tagless finals
///    get one structured backfill) — once FOR THE PIECES IT READ: the annotation records
///    them (`ConversationAnnotation.sourceKey`), and one whose conversation has since been
///    cut differently is due again. Failures follow `AiRetryPolicy`: only a failure on the
///    input spends one of `maxAttempts`, the world's failures back off in time, and a spent
///    budget rests six hours before one more try — so a broken provider cannot spin, and an
///    afternoon offline cannot cost a conversation its title for good. A fallback that read
///    only part of the conversation is shown but kept provisional (`RoutedAiResult
///    .isProvisional`) until the preferred provider redoes it.
///
/// Runs strictly under the user's AI settings: when no router is configured or the configured
/// mode has no available provider (e.g. remote consent off), it does nothing and rows fall
/// back to transcript snippets.
public final class EnrichmentWorker: @unchecked Sendable {
    /// Final-pass failures ON THE INPUT before a conversation rests (`AiRetryPolicy
    /// .exhaustedRetryMs`). Shared with the library's "waiting" count, which stops counting at
    /// the same number.
    public static let maxAttempts = AnnotationPolicy.maxFinalAttempts

    /// Conversations actually SENT to the provider in one `enrich` call.
    ///
    /// This loop used to run the entire backlog in a single invocation, and that made the whole
    /// pipeline pass as long as the backlog: with 145 unenriched conversations the pass did not
    /// return for many minutes, so nothing after it ran and nothing before it ran again — the
    /// grouping went stale and the user's Library, Today list, live row and Recording-now screen
    /// all froze at whatever moment the backfill began, while recording continued. The backlog
    /// still drains; it just yields the pass between mouthfuls.
    public static let maxPerPass = 3

    /// Minimum combined-text length before the first provisional annotation is worthwhile.
    public static let liveMinChars = 120

    /// Combined text must grow at least this much before a provisional refresh.
    public static let liveRefreshMinGrowthChars = 280

    /// Minimum time between provisional refreshes for one live conversation.
    public static let liveRefreshMinIntervalMs: Int64 = 45_000

    private let annotations: AnnotationStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64
    private let transcriptVersionOf: @Sendable (String) -> String?

    /// Finished conversations whose members' transcripts held no text, by membership key. A
    /// transcript is loaded and decoded — every word of it — to learn that, and without this
    /// memo every pass re-learned it for every such conversation in the library. Keyed so a
    /// change to any member (a new segment, a re-transcription, a rewritten file) drops the
    /// entry and the next pass looks again.
    private let emptyFinals = TranscriptMemo<String>()

    /// - Parameter transcriptVersionOf: something that changes whenever a segment's transcript
    ///   file changes (size and modification time will do). Nil means "unknown", and an unknown
    ///   version disables the memo for that conversation — so a test that swaps `transcriptOf`
    ///   under the same segment id still sees the new text.
    public init(
        annotations: AnnotationStore, router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64,
        transcriptVersionOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.annotations = annotations
        self.router = router
        self.nowMs = nowMs
        self.transcriptVersionOf = transcriptVersionOf
    }

    /// The identity of a conversation's transcribed inputs: its pieces (segment AND range),
    /// their transcription state and their transcript file versions. Nil when any member's
    /// version is unknown.
    ///
    /// The range is part of it because a cut can move while the segments stay the same: the
    /// conversation then reads different turns of the same files, and a key made of segment ids
    /// alone would answer from what the old range held.
    static func membershipKey(
        _ conversation: EnrichmentConversation,
        transcriptVersionOf: (String) -> String?
    ) -> String? {
        var parts: [String] = []
        parts.reserveCapacity(conversation.members.count)
        for (member, piece) in conversation.parts {
            guard let version = transcriptVersionOf(member.segmentId) else { return nil }
            parts.append(
                "\(ConversationSourceKey.key(of: [piece]))|"
                    + "\(member.transcriptionState.rawValue)|\(version)")
        }
        return parts.joined(separator: ";")
    }

    /// What, if anything, the worker should do for one conversation this pass.
    private enum Plan {
        case none
        case generate(excerpts: [TranscriptExcerpt], combinedLength: Int, isFinal: Bool)
        /// The stored annotation was written from other audio and the pieces this conversation
        /// now owns hold no words to write a new one from: what is stored has to go.
        case withdraw
        /// The stored annotation still stands, but the conversation has lost its leading pieces
        /// since it was written (retention, or a deleted segment). Nothing is asked of a model;
        /// the key is brought up to date and the conversation reported as changed, so that what
        /// search holds for it is rebuilt from the pieces that are left — the delete cascade
        /// takes a trimmed conversation's index row away, and until this existed nothing ever
        /// put one back for a conversation whose title was final.
        case rekey
    }

    /// What one piece contributes to a prompt: its words, and where its first turn starts in
    /// the segment's stored audio (nil where the source has no timings — live text).
    private struct PieceText {
        var text: String
        var firstTurnMediaMs: Int64?
    }

    /// Checks a held cloud AI account when its schedule says to (see
    /// `OpenAiChatAiProvider.probeHeldAccountIfDue`). Runs at the top of the AI stage, BEFORE the
    /// availability check below — a held account is exactly what makes the router unavailable,
    /// so this is the one place that can notice it has been topped up. Cheap and silent when
    /// nothing is held, which is always the ordinary case.
    public func probeHeldAccountIfDue(foreground: Bool) async {
        _ = await router?.probeHeldRemoteAccountIfDue(foreground: foreground)
    }

    /// Annotates conversations that are due for a live refresh or a final pass.
    /// `transcriptOf` returns the durable transcript of a closed segment, which is cut to each
    /// conversation's piece of it here (`SegmentTranscript.piece`); `liveTextOf` returns the
    /// rolling live preview of a still-open segment. Returns the conversation ids whose
    /// annotation changed this pass.
    public func enrich(
        _ conversations: [EnrichmentConversation],
        transcriptOf: (String) -> SegmentTranscript?,
        liveTextOf: (String) -> String? = { _ in nil }
    ) async throws -> [String] {
        try await enrich(
            conversations, pieceTranscriptOf: { transcriptOf($0.segmentId)?.piece($0) },
            liveTextOf: liveTextOf)
    }

    /// The same, for a caller that prepares each piece's transcript itself.
    ///
    /// `EnrichmentService` does: it collapses transcriber loops and withholds stretches judged
    /// to hold no conversation, and both leave a NOTE in the text where turns were taken out.
    /// `SegmentTranscript.piece` rebuilds a partial piece's text from its turns, so cutting
    /// after cleaning would drop the notes — and nearly every piece is partial. Cutting first
    /// and cleaning the piece keeps them.
    public func enrich(
        _ conversations: [EnrichmentConversation],
        pieceTranscriptOf: (ConversationMember) -> SegmentTranscript?,
        liveTextOf: (String) -> String? = { _ in nil }
    ) async throws -> [String] {
        guard let activeRouter = router else { return [] }
        guard await activeRouter.isAvailable() else { return [] }

        let now = nowMs()
        var annotated: [String] = []
        var calls = 0
        // Every annotation in one read. This was one query per conversation per pass — every
        // finished conversation in the library, every few seconds while a segment is open —
        // to learn, almost always, that it was already titled.
        let stored = try await annotations.all()
        // NEWEST FIRST. A migrated library hands this loop a whole backlog at once, and in
        // arrival order the conversation happening RIGHT NOW is last — a migrated user waited
        // for 145 months-old conversations before today's got a title. Recency is the max member
        // start time; a live conversation is by construction the most recent thing there is.
        //
        // The same order, and the same `maxPerPass`, carry the one-off re-titling of a library
        // whose conversations were re-cut: every conversation is due at once (`sourceKey`), so
        // the pass takes today's three, returns, and comes back for the next three.
        for conversation in conversations.sorted(by: Self.newestFirst) {
            // Check between conversations so backgrounding or shutdown stops the backlog at the
            // next boundary instead of running it out.
            try Task.checkCancellation()
            if calls >= Self.maxPerPass { break }
            let existing = stored[conversation.conversationId]
            let plan = planFor(
                conversation, existing: existing, pieceTranscriptOf: pieceTranscriptOf,
                liveTextOf: liveTextOf, now: now)
            if case .withdraw = plan, let existing {
                // No provider call, so nothing is spent from the pass's budget.
                try await withdraw(existing, sourceKey: conversation.sourceKey)
                annotated.append(conversation.conversationId)
                continue
            }
            if case .rekey = plan, var existing {
                existing.sourceKey = conversation.sourceKey
                try await annotations.save(existing)
                annotated.append(conversation.conversationId)
                continue
            }
            guard case .generate = plan else { continue }
            // Counted on the PROVIDER call, not on the conversation examined: a library of
            // already-annotated conversations must not eat the budget before reaching the one
            // that needs work.
            calls += 1
            switch try await runPlan(activeRouter, conversation, existing: existing, plan: plan) {
            case .annotated:
                annotated.append(conversation.conversationId)
            case .failedOnTheInput:
                break
            case .failedOnTheWorld:
                // The provider is down, busy or out of reach, and the next conversation in this
                // pass would be sent to the same one. Each conversation keeps its own backoff,
                // so without this an outage is met one conversation at a time — three failing
                // calls a pass until every conversation in the backlog has failed once — and a
                // freshly re-cut library is a backlog of several hundred. One is enough to
                // know; the rest wait for a later pass with their budgets and clocks untouched.
                return annotated
            }
        }
        return annotated
    }

    /// How one generation ended.
    private enum RunOutcome {
        /// Fresh content was produced and stored.
        case annotated
        /// It failed, and the failure blames what was sent (`AiRetryPolicy.spendsAttempt`).
        case failedOnTheInput
        /// It failed for a reason that is not this conversation's: network, a busy or broke
        /// account, a model still loading.
        case failedOnTheWorld
    }

    /// Most recent conversation first; a conversation with no members sorts last. Ties break on
    /// the id so the order is TOTAL — Swift's sort is not stable, and a per-pass budget handed a
    /// non-deterministic order would pick a different few conversations every pass.
    ///
    /// "Most recent" is each member's OWN start (`startWallMs`), not the raw `startTimeMs` —
    /// that field anchors sample index 0 of the stream, so a conversation made of rotation
    /// successors sorts by when its stream was born. Over the 2026-09-08 backup the two differ
    /// on 602 of 774 segments, 594 by more than a minute, and this comparator decides which
    /// three conversations a pass spends its provider calls on.
    static func newestFirst(_ a: EnrichmentConversation, _ b: EnrichmentConversation) -> Bool {
        let left = a.members.map(\.startWallMs).max() ?? 0
        let right = b.members.map(\.startWallMs).max() ?? 0
        if left != right { return left > right }
        return a.conversationId < b.conversationId
    }

    private func planFor(
        _ conversation: EnrichmentConversation,
        existing: ConversationAnnotation?,
        pieceTranscriptOf: (ConversationMember) -> SegmentTranscript?,
        liveTextOf: (String) -> String?,
        now: Int64
    ) -> Plan {
        // Whether what is stored was written from the pieces this conversation owns NOW. An id
        // stays with a conversation's first part when it is cut, so without this test the ten
        // minutes that inherit a ten-hour conversation's id keep its title, final and
        // untouchable. A row from before the key was recorded describes nothing, which is what
        // re-titles an existing library once after conversations became topic-sized.
        let describesThese = ConversationSourceKey.describes(
            stored: existing?.sourceKey, current: conversation.sourceKey)
        // Final/authoritative pass takes precedence: a closed conversation whose members are
        // all terminal (Complete/NoSpeech — the KMP per-segment "closed + Complete" gate,
        // widened per plan Part 3's "final pass when all members are terminal").
        if !conversation.isOpen, !conversation.members.isEmpty,
            conversation.members.allSatisfy({ !$0.isOpen && $0.isFullyTranscribed })
        {
            // Decide from the annotation record BEFORE touching a transcript. These checks used
            // to come after the excerpts were built, so every finished, already-annotated
            // conversation in the library had all of its transcripts read and JSON-decoded on
            // every pipeline pass — one pass every few seconds while a segment is open — just to
            // return `.none`. Profiled on 2026-09-09 at a quarter of a CPU core, continuously:
            // the whole of the phone's "CPU budget exceeded" afternoon.
            //
            // Older final annotations were title/summary only. Treat tagless finals as due
            // for one structured final pass so library tags backfill automatically.
            //
            // A final annotation is only final FOR THE PIECES IT WAS WRITTEN FROM. One whose
            // key no longer describes the conversation is due again like any other.
            if let existing, existing.isFinal, !existing.tags.isEmpty, describesThese {
                return existing.sourceKey == conversation.sourceKey ? .none : .rekey
            }
            // Waiting out a backoff (`AiRetryPolicy`): a failure, a spent budget or a
            // provisional answer all set one. This used to be "three final attempts, no time
            // between them, never reset" — three passes during a flight cost a conversation its
            // title for good.
            if let next = existing?.nextAttemptAtMs, now < next { return .none }
            // A budget spent before backoffs existed rests from its last failure, then gets a
            // retry, instead of being abandoned forever. (A budget spent on OTHER pieces is not
            // this conversation's: `runPlan` starts it over.)
            if let existing, describesThese, existing.finalAttempts >= Self.maxAttempts,
                existing.nextAttemptAtMs == nil,
                now - existing.updatedAtMs < AiRetryPolicy.exhaustedRetryMs
            {
                return .none
            }
            let key = Self.membershipKey(conversation, transcriptVersionOf: transcriptVersionOf)
            if let key, emptyFinals.contains(conversation.conversationId, key: key) {
                return .none
            }
            let excerpts = pieceExcerpts(conversation) { member, piece in
                guard member.transcriptionState == .complete else { return nil }
                return pieceTranscriptOf(piece).map {
                    PieceText(text: $0.text, firstTurnMediaMs: $0.segments.first?.startMs)
                }
            }
            let combinedLength = combinedLength(excerpts)
            if combinedLength == 0 {
                // Nothing was said in these pieces. If what is stored was written from other
                // audio — the conversation this one's id came from — it must not stay: a quiet
                // ten minutes would carry the title of the talk it was cut away from, forever,
                // because there is nothing here to write a new one from.
                if let existing, !describesThese, Self.hasGeneratedContent(existing) {
                    return .withdraw
                }
                if let key { emptyFinals.remember(conversation.conversationId, key: key) }
                return .none
            }
            emptyFinals.forget(conversation.conversationId)
            return .generate(excerpts: excerpts, combinedLength: combinedLength, isFinal: true)
        }

        // Live/provisional pass: the conversation is still live.
        if conversation.isOpen {
            // A final annotation should never exist while live, but never downgrade it if it
            // does — unless it was written from other pieces. A closed conversation joined onto
            // the live one hands the live one its id, and its final title with it; that title
            // is about a part of what the conversation now is, and is refreshed like a
            // provisional one.
            let staleFinal = existing?.isFinal == true && !describesThese
            if existing?.isFinal == true, !staleFinal { return .none }
            // The clock first, and only then the transcripts. This used to decode every closed
            // member of the live conversation — every pass, every five seconds while the watch
            // records — and only then find the 45-second refresh gate closed. The interval half
            // of the gate needs nothing but the stored annotation.
            if let existing, now - existing.updatedAtMs < Self.liveRefreshMinIntervalMs {
                return .none
            }
            let excerpts = pieceExcerpts(conversation) { member, piece in
                // The open member has no durable transcript to cut: its rolling text stands for
                // the whole of it. (A cut is only ever placed between the turns of a SETTLED
                // member, so the live conversation owns the open segment from its first frame.)
                if member.isOpen {
                    return liveTextOf(member.segmentId).map {
                        PieceText(text: $0, firstTurnMediaMs: nil)
                    }
                }
                return pieceTranscriptOf(piece).map {
                    PieceText(text: $0.text, firstTurnMediaMs: $0.segments.first?.startMs)
                }
            }
            let combinedLength = combinedLength(excerpts)
            if combinedLength < Self.liveMinChars { return .none }
            // The growth gate compares against what the stored text was written from; for a
            // title inherited from other pieces that number is about something else.
            guard let existing, !staleFinal else {
                return .generate(
                    excerpts: excerpts, combinedLength: combinedLength, isFinal: false)
            }
            let grownEnough =
                combinedLength >= existing.sourceCharCount + Self.liveRefreshMinGrowthChars
            let intervalElapsed = now - existing.updatedAtMs >= Self.liveRefreshMinIntervalMs
            return grownEnough && intervalElapsed
                ? .generate(excerpts: excerpts, combinedLength: combinedLength, isFinal: false)
                : .none
        }

        // Closed but not yet fully transcribed (members Running/Uploading/Pending/Failed/…):
        // keep any provisional annotation and wait for the final pass.
        return .none
    }

    /// One excerpt per PIECE with non-blank text, in member order: only the turns the
    /// conversation owns, so two conversations that share a segment never read each other's.
    ///
    /// Three corrections to what the model is told about WHEN, the first two the same bug the
    /// follow-up renderer already fixed on its side:
    ///  - the anchor is `startWallMs`, this segment's own start. The raw `startTimeMs` is the
    ///    stream's birth clock, which on the 2026-09-08 backup is a different instant for 602
    ///    of 774 segments — 594 by more than a minute, median 1 h 59 m, worst 24 h 21 m.
    ///  - it carries a real local time. Without a `timeLabel`,
    ///    `AiTranscriptFormatting.buildUserContent` falls back to "(starts at epoch ms
    ///    1788193751778)", which is a unit nothing else in these prompts uses and which the
    ///    model has to guess at — the same reason `FollowUpTranscriptRenderer` prints days and
    ///    clock times. Formatted in the zone the audio was RECORDED in (Q16).
    ///  - it is the time of the piece's first turn, not of its segment: a conversation that
    ///    starts twelve minutes into a segment happened twelve minutes later than the segment
    ///    did (`EnrichmentConversation.startWallMs(of:in:firstTurnMediaMs:)`).
    private func pieceExcerpts(
        _ conversation: EnrichmentConversation,
        textOf: (SegmentMeta, ConversationMember) -> PieceText?
    ) -> [TranscriptExcerpt] {
        let now = nowMs()
        return conversation.parts.compactMap { member, piece in
            guard let source = textOf(member, piece) else { return nil }
            let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let startMs = EnrichmentConversation.startWallMs(
                of: piece, in: member, firstTurnMediaMs: source.firstTurnMediaMs)
            return TranscriptExcerpt(
                segmentId: member.segmentId,
                text: text,
                startTimeMs: startMs,
                timeLabel: askWhenLabel(
                    startMs: startMs, endMs: nil,
                    timeZoneID: member.recordedTimeZone ?? TimeZone.current.identifier,
                    nowMs: now)
            )
        }
    }

    /// Length of the combined piece text — the KMP `plan.text.length` growth-gate input,
    /// counting the piece texts joined by blank lines. It is measured over what the pieces
    /// hold, so a cut that moves changes it even when no segment joined or left.
    private func combinedLength(_ excerpts: [TranscriptExcerpt]) -> Int {
        guard !excerpts.isEmpty else { return 0 }
        let joined = excerpts.map { $0.text }.joined(separator: "\n\n")
        return joined.count
    }

    /// Runs one generation.
    private func runPlan(
        _ activeRouter: AiModeRouter,
        _ conversation: EnrichmentConversation,
        existing: ConversationAnnotation?,
        plan: Plan
    ) async throws -> RunOutcome {
        guard case .generate(let excerpts, let combinedLength, let isFinal) = plan else {
            return .failedOnTheInput
        }
        let attempts = (existing?.attempts ?? 0) + 1
        let sourceKey = conversation.sourceKey
        // A budget is spent on an INPUT. What failed three times was the conversation the id
        // used to name; these pieces have not been tried.
        let sameSource = ConversationSourceKey.describes(
            stored: existing?.sourceKey, current: sourceKey)
        let priorFinalAttempts = sameSource ? (existing?.finalAttempts ?? 0) : 0
        // The person's own title is not the model's to replace, whatever else is rewritten.
        let userTitle = existing?.titleEditedAtMs != nil ? existing?.title : nil
        let now = nowMs()
        do {
            let result = try await activeRouter.run(
                AiRunRequest(
                    requestId:
                        "annotate-\(conversation.conversationId)-\(isFinal ? "final" : "live")-\(attempts)",
                    prompt: SegmentAnnotationPrompt.forPass(live: !isFinal),
                    transcripts: excerpts
                ))
            let parsed = SegmentAnnotationPrompt.parse(result.text)
            // A fallback that read only part of a finished conversation wrote a title for its
            // first stretch. Better than a blank row, so it is SHOWN — but it is provisional:
            // not final, and the final pass comes back for it once the preferred provider can
            // read the whole thing (sooner if a held account takes work again, which resets
            // every backoff). A truncated answer from the provider the mode PREFERS is the best
            // there will be, and is final like any other.
            let provisional = isFinal && result.isProvisional
            let transientFailures = provisional ? (existing?.transientFailures ?? 0) + 1 : 0
            try await annotations.save(
                ConversationAnnotation(
                    conversationId: conversation.conversationId,
                    title: userTitle ?? parsed.title,
                    summary: parsed.summary,
                    tags: parsed.tags,
                    modeUsed: result.modeUsed,
                    providerId: result.providerId,
                    modelUsed: result.modelUsed,
                    attempts: attempts,
                    lastError: provisional
                        ? "provisional: \(result.providerId) read part of this conversation"
                        : nil,
                    isFinal: isFinal && !provisional,
                    sourceCharCount: combinedLength,
                    finalAttempts: priorFinalAttempts + (isFinal && !provisional ? 1 : 0),
                    nextAttemptAtMs: provisional
                        ? now
                            + max(
                                AiRetryPolicy.provisionalRetryMs,
                                AiRetryPolicy.transientRetryMs(consecutive: transientFailures))
                        : nil,
                    transientFailures: transientFailures,
                    sourceKey: sourceKey,
                    titleEditedAtMs: existing?.titleEditedAtMs
                ))
            return .annotated
        } catch let error where error is CancellationError {
            throw error
        } catch {
            // Preserve any existing (provisional) content so the row does not blank out on a
            // failure, and record why. The live pass is throttled by its interval gate
            // (anchored on updatedAtMs, which the store rewrites here). The final pass follows
            // `AiRetryPolicy`: only a failure on the input spends an attempt; one that was the
            // world's backs off in time; a spent budget rests six hours and then gets one more
            // try at a time, never abandoned.
            var record =
                existing ?? ConversationAnnotation(conversationId: conversation.conversationId)
            record.attempts = attempts
            record.lastError = Self.errorMessage(error)
            let blamesTheInput = AiRetryPolicy.spendsAttempt(error)
            if isFinal {
                // The bookkeeping below is about THESE pieces from here on. Content written
                // from other pieces stays on screen — better than a blank row — but it is no
                // longer final, so the budget and backoff that follow apply to it like any
                // other unfinished conversation.
                if !sameSource { record.isFinal = false }
                record.sourceKey = sourceKey
                if blamesTheInput {
                    record.finalAttempts = priorFinalAttempts + 1
                    record.transientFailures = 0
                    record.nextAttemptAtMs =
                        now
                        + (record.finalAttempts >= Self.maxAttempts
                            ? AiRetryPolicy.exhaustedRetryMs : AiRetryPolicy.contentRetryMs)
                } else {
                    record.finalAttempts = priorFinalAttempts
                    record.transientFailures = (existing?.transientFailures ?? 0) + 1
                    record.nextAttemptAtMs =
                        now + AiRetryPolicy.transientRetryMs(consecutive: record.transientFailures)
                }
            }
            try await annotations.save(record)
            return blamesTheInput ? .failedOnTheInput : .failedOnTheWorld
        }
    }

    /// Whether an annotation holds anything the MODEL wrote: a summary, tags, or a title the
    /// person did not type.
    public static func hasGeneratedContent(_ annotation: ConversationAnnotation) -> Bool {
        if let summary = annotation.summary, !summary.isBlank { return true }
        if !annotation.tags.isEmpty { return true }
        if annotation.titleEditedAtMs == nil, let title = annotation.title, !title.isBlank {
            return true
        }
        return false
    }

    /// Takes back what the model wrote about other audio. The save with no tags is what also
    /// withdraws the adopted AI tags (`AnnotationStore.save` adopts in its own transaction); a
    /// title the person typed is theirs and stays, as a row holding nothing else.
    public func withdraw(_ existing: ConversationAnnotation, sourceKey: String) async throws {
        try await annotations.save(
            ConversationAnnotation(
                conversationId: existing.conversationId,
                title: existing.titleEditedAtMs != nil ? existing.title : nil,
                sourceKey: sourceKey,
                titleEditedAtMs: existing.titleEditedAtMs))
        if existing.titleEditedAtMs == nil {
            try await annotations.delete(existing.conversationId)
        }
    }

    /// Every conversation's final-pass budget and backoff start over. Called when the AI
    /// configuration changes — a key, a mode, a remote provider or model, a held account taking
    /// work again — because what failed before may now succeed.
    public func resetRetryBudgets() async {
        try? await annotations.resetRetryBudgets()
    }

    /// Kotlin `e.message ?: e::class.simpleName` equivalent.
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

/// A small lock-guarded `conversation id -> key` memo shared by the workers on the pipeline
/// loop, so a decision that needed a transcript decoded is not re-derived every pass.
final class TranscriptMemo<Key: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Key] = [:]

    func contains(_ id: String, key: Key) -> Bool {
        lock.withLock { entries[id] == key }
    }

    func value(_ id: String) -> Key? {
        lock.withLock { entries[id] }
    }

    func remember(_ id: String, key: Key) {
        lock.withLock { entries[id] = key }
    }

    func forget(_ id: String) {
        lock.withLock { _ = entries.removeValue(forKey: id) }
    }
}
