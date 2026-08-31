import Foundation
import SegmentStore
import Transcription

// Port of `app/.../SegmentEnrichmentWorker.kt`, retargeted from segment to CONVERSATION
// granularity (plan Part 3): same prompts and gates, input = the combined member transcripts,
// output = one row in the AppDB `annotations` table per conversation.

/// One conversation due for consideration this pass: its id, whether it is still live, and
/// its ordered member segments (from `conversations` + `conversation_segments`).
public struct EnrichmentConversation: Sendable {
    public var conversationId: String
    /// True while the conversation is live (`conversations.state == "live"`). Not derivable
    /// from the members alone: a conversation stays live through the 5-minute join window
    /// after its last segment closes.
    public var isOpen: Bool
    /// Ordered member segment metas (conversation_segments ordinal order).
    public var members: [SegmentMeta]

    public init(conversationId: String, isOpen: Bool, members: [SegmentMeta]) {
        self.conversationId = conversationId
        self.isOpen = isOpen
        self.members = members
    }
}

/// Generates the AI title + summary + proposed tags shown on Today/Library rows.
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
///    get one structured backfill) and is bounded to `maxAttempts` final attempts so a broken
///    provider cannot spin.
///
/// Runs strictly under the user's AI settings: when no router is configured or the configured
/// mode has no available provider (e.g. remote consent off), it does nothing and rows fall
/// back to transcript snippets.
public final class EnrichmentWorker: @unchecked Sendable {
    /// Bounds the authoritative final pass so a persistently failing provider cannot spin.
    public static let maxAttempts = 3

    /// Minimum combined-text length before the first provisional annotation is worthwhile.
    public static let liveMinChars = 120

    /// Combined text must grow at least this much before a provisional refresh.
    public static let liveRefreshMinGrowthChars = 280

    /// Minimum time between provisional refreshes for one live conversation.
    public static let liveRefreshMinIntervalMs: Int64 = 45_000

    private let annotations: AnnotationStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64

    public init(
        annotations: AnnotationStore, router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64
    ) {
        self.annotations = annotations
        self.router = router
        self.nowMs = nowMs
    }

    /// What, if anything, the worker should do for one conversation this pass.
    private enum Plan {
        case none
        case generate(excerpts: [TranscriptExcerpt], combinedLength: Int, isFinal: Bool)
    }

    /// Annotates conversations that are due for a live refresh or a final pass.
    /// `transcriptOf` returns the durable transcript of a closed segment; `liveTextOf`
    /// returns the rolling live preview of a still-open segment. Returns the conversation ids
    /// that received fresh content this pass.
    public func enrich(
        _ conversations: [EnrichmentConversation],
        transcriptOf: (String) -> SegmentTranscript?,
        liveTextOf: (String) -> String? = { _ in nil }
    ) async throws -> [String] {
        guard let activeRouter = router else { return [] }
        guard await activeRouter.isAvailable() else { return [] }

        let now = nowMs()
        var annotated: [String] = []
        for conversation in conversations {
            let existing = try await annotations.load(conversation.conversationId)
            let plan = planFor(
                conversation, existing: existing, transcriptOf: transcriptOf,
                liveTextOf: liveTextOf, now: now)
            guard case .generate = plan else { continue }
            if try await runPlan(activeRouter, conversation, existing: existing, plan: plan) {
                annotated.append(conversation.conversationId)
            }
        }
        return annotated
    }

    private func planFor(
        _ conversation: EnrichmentConversation,
        existing: ConversationAnnotation?,
        transcriptOf: (String) -> SegmentTranscript?,
        liveTextOf: (String) -> String?,
        now: Int64
    ) -> Plan {
        // Final/authoritative pass takes precedence: a closed conversation whose members are
        // all terminal (Complete/NoSpeech — the KMP per-segment "closed + Complete" gate,
        // widened per plan Part 3's "final pass when all members are terminal").
        if !conversation.isOpen, !conversation.members.isEmpty,
            conversation.members.allSatisfy({ !$0.isOpen && $0.isFullyTranscribed })
        {
            let excerpts = memberExcerpts(conversation) { member in
                guard member.transcriptionState == .complete else { return nil }
                return transcriptOf(member.segmentId)?.text
            }
            let combinedLength = combinedLength(excerpts)
            if combinedLength == 0 { return .none }
            // Older final annotations were title/summary only. Treat tagless finals as due
            // for one structured final pass so library tags backfill automatically.
            if let existing, existing.isFinal, !existing.tags.isEmpty { return .none }
            if (existing?.finalAttempts ?? 0) >= Self.maxAttempts { return .none }
            return .generate(excerpts: excerpts, combinedLength: combinedLength, isFinal: true)
        }

        // Live/provisional pass: the conversation is still live.
        if conversation.isOpen {
            // A final annotation should never exist while live, but never downgrade it if it
            // does.
            if existing?.isFinal == true { return .none }
            let excerpts = memberExcerpts(conversation) { member in
                member.isOpen
                    ? liveTextOf(member.segmentId)
                    : transcriptOf(member.segmentId)?.text
            }
            let combinedLength = combinedLength(excerpts)
            if combinedLength < Self.liveMinChars { return .none }
            guard let existing else {
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

    /// One excerpt per member with non-blank text, in member order.
    private func memberExcerpts(
        _ conversation: EnrichmentConversation, textOf: (SegmentMeta) -> String?
    ) -> [TranscriptExcerpt] {
        conversation.members.compactMap { member in
            guard
                let text = textOf(member)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { return nil }
            return TranscriptExcerpt(
                segmentId: member.segmentId,
                text: text,
                startTimeMs: Int64(member.startTimeMs)
            )
        }
    }

    /// Length of the combined member text — the KMP `plan.text.length` growth-gate input,
    /// counting the member texts joined by blank lines.
    private func combinedLength(_ excerpts: [TranscriptExcerpt]) -> Int {
        guard !excerpts.isEmpty else { return 0 }
        let joined = excerpts.map { $0.text }.joined(separator: "\n\n")
        return joined.count
    }

    /// Runs one generation. Returns true when fresh content was produced and stored.
    private func runPlan(
        _ activeRouter: AiModeRouter,
        _ conversation: EnrichmentConversation,
        existing: ConversationAnnotation?,
        plan: Plan
    ) async throws -> Bool {
        guard case .generate(let excerpts, let combinedLength, let isFinal) = plan else {
            return false
        }
        let attempts = (existing?.attempts ?? 0) + 1
        let finalAttempts = (existing?.finalAttempts ?? 0) + (isFinal ? 1 : 0)
        do {
            let result = try await activeRouter.run(
                AiRunRequest(
                    requestId:
                        "annotate-\(conversation.conversationId)-\(isFinal ? "final" : "live")-\(attempts)",
                    prompt: SegmentAnnotationPrompt.forPass(live: !isFinal),
                    transcripts: excerpts
                ))
            let parsed = SegmentAnnotationPrompt.parse(result.text)
            try await annotations.save(
                ConversationAnnotation(
                    conversationId: conversation.conversationId,
                    title: parsed.title,
                    summary: parsed.summary,
                    tags: parsed.tags,
                    modeUsed: result.modeUsed,
                    providerId: result.providerId,
                    modelUsed: result.modelUsed,
                    attempts: attempts,
                    isFinal: isFinal,
                    sourceCharCount: combinedLength,
                    finalAttempts: finalAttempts
                ))
            return true
        } catch let error where error is CancellationError {
            throw error
        } catch {
            // Preserve any existing (provisional) content so the row does not blank out on a
            // transient failure; record the error and bump the relevant counters. The
            // interval gate (anchored on updatedAtMs, which the store rewrites here)
            // throttles live retries.
            var record =
                existing ?? ConversationAnnotation(conversationId: conversation.conversationId)
            record.attempts = attempts
            record.finalAttempts = finalAttempts
            record.lastError = Self.errorMessage(error)
            try await annotations.save(record)
            return false
        }
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
