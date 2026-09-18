import Foundation

// The measured half of Ask's semantic recall.
//
// The semantic signal is allowed into the planner under one rule (`AskRecallPolicy`): it may
// rescue a conversation, never cost one. A rule like that is only worth having if it can be
// SEEN working — so every time the drop stage engages, the two signals are compared on the
// real question and the outcome is written down: how many conversations each found, how many
// both did, how many only semantic vouched for and were kept, how many only keyword vouched
// for and were dropped anyway. One log line per question, and the newest twenty kept for the
// Diagnostics screen. Never a silent reranking.

/// The per-segment relevance the planner is handed, and the per-conversation facts the
/// experiment needs afterwards, from one pair of index passes.
public struct AskRecallSignals: Sendable {
    /// Segment id → both scores. Absent means no evidence from either.
    public let scores: [String: AskRelevance]
    /// Conversation ids the keyword (FTS) pass hit, restricted to the scope.
    public let keywordConversations: Set<String>
    /// Conversation ids the semantic pass hit, restricted to the scope.
    public let semanticConversations: Set<String>

    public init(
        scores: [String: AskRelevance],
        keywordConversations: Set<String>,
        semanticConversations: Set<String>
    ) {
        self.scores = scores
        self.keywordConversations = keywordConversations
        self.semanticConversations = semanticConversations
    }

    /// The closure shape the planner takes.
    public var relevance: @Sendable (String) -> AskRelevance {
        let scores = self.scores
        return { scores[$0] ?? .none }
    }

    /// Resolve index hits to per-segment scores. Both indexes key on CONVERSATION ids
    /// (`conv-<firstMemberSegmentId>`); `members` maps each to its segments, and only segments
    /// in `scope` count — neither index is date-scoped, so a hit on last month's conversation
    /// during a "Today" question resolves to nothing and is ignored. A hit id absent from
    /// `members` is taken as a segment id (callers whose index keys on segments). The first hit
    /// for a segment wins on each signal, as the retriever has always done.
    public static func resolve(
        keyword: [AskIndexHit],
        semantic: [AskIndexHit],
        members: [String: [String]],
        scope: Set<String>
    ) -> AskRecallSignals {
        var scores: [String: AskRelevance] = [:]
        func expand(_ id: String) -> [String] {
            (members[id] ?? [id]).filter { scope.contains($0) }
        }
        /// Applies one signal's hits; returns the conversation ids that reached a segment.
        func apply(
            _ hits: [AskIndexHit], _ assign: (inout AskRelevance, Double) -> Void
        ) -> Set<String> {
            var taken = Set<String>()
            var conversations = Set<String>()
            for hit in hits {
                var reached = false
                for segmentId in expand(hit.id) where taken.insert(segmentId).inserted {
                    assign(&scores[segmentId, default: .none], Double(hit.score))
                    reached = true
                }
                if reached { conversations.insert(hit.id) }
            }
            return conversations
        }
        let keywordConversations = apply(keyword) { $0.keyword = $1 }
        let semanticConversations = apply(semantic) { $0.semantic = $1 }
        return AskRecallSignals(
            scores: scores,
            keywordConversations: keywordConversations,
            semanticConversations: semanticConversations)
    }
}

/// One question's recall experiment, as persisted for Diagnostics and as logged.
public struct AskRecallRecord: Codable, Equatable, Sendable {
    public var atMs: Int64
    /// The user's own question, clipped — never transcript text. Shown on the Diagnostics
    /// row so a record can be read as "that question, that outcome".
    public var question: String
    /// Conversations in the scope the question was asked over.
    public var scopeConversations: Int
    /// Batches the scope packed into, and how many survived the ceiling.
    public var packedBatches: Int
    public var keptBatches: Int
    /// Conversations each pass hit, and their overlap.
    public var keyword: Int
    public var semantic: Int
    public var both: Int
    /// Conversations only semantic vouched for that were read — the rescues.
    public var semanticOnlyKept: Int
    /// Conversations only keyword vouched for that were dropped anyway (the ceiling was
    /// tighter than the keyword evidence; never the semantic signal's doing under
    /// `.keywordFirst`).
    public var keywordOnlyDropped: Int
    public var policy: AskRecallPolicy
    /// Wall time of the two index passes together.
    public var ms: Int
    /// Whether the semantic pass ran at all (the setting was on and a semantic index was
    /// wired). `semantic == 0` means something different when it did not.
    public var semanticRan: Bool

    public init(
        atMs: Int64, question: String, scopeConversations: Int, packedBatches: Int,
        keptBatches: Int, keyword: Int, semantic: Int, both: Int, semanticOnlyKept: Int,
        keywordOnlyDropped: Int, policy: AskRecallPolicy, ms: Int, semanticRan: Bool
    ) {
        self.atMs = atMs
        self.question = question
        self.scopeConversations = scopeConversations
        self.packedBatches = packedBatches
        self.keptBatches = keptBatches
        self.keyword = keyword
        self.semantic = semantic
        self.both = both
        self.semanticOnlyKept = semanticOnlyKept
        self.keywordOnlyDropped = keywordOnlyDropped
        self.policy = policy
        self.ms = ms
        self.semanticRan = semanticRan
    }

    /// Questions are clipped to this many characters in the record.
    public static let maxQuestionChars = 80

    /// The experiment line, house style: lowercase `key=value` tokens, counts only.
    public var logLine: String {
        "ask recall: scope=\(scopeConversations) batches=\(packedBatches) kept=\(keptBatches) "
            + "fts=\(keyword) semantic=\(semantic) both=\(both) "
            + "semantic-only-kept=\(semanticOnlyKept) fts-only-dropped=\(keywordOnlyDropped) "
            + "policy=\(policy.rawValue) ms=\(ms) semantic-ran=\(semanticRan)"
    }
}

public enum AskRecallExperiment {
    /// The record for one question, from what the two passes found and what the plan kept.
    ///
    /// `keptSegmentIds` are the segments the plan will read; a conversation is kept when any
    /// of its in-scope members is. `members` is the same conversation → segments map the
    /// signals were resolved with.
    public static func measure(
        atMs: Int64,
        question: String,
        signals: AskRecallSignals,
        members: [String: [String]],
        keptSegmentIds: Set<String>,
        plan: AskCorpusPlan,
        policy: AskRecallPolicy,
        ms: Int,
        semanticRan: Bool
    ) -> AskRecallRecord {
        func kept(_ conversationId: String) -> Bool {
            (members[conversationId] ?? [conversationId]).contains { keptSegmentIds.contains($0) }
        }
        let keyword = signals.keywordConversations
        let semantic = signals.semanticConversations
        let both = keyword.intersection(semantic)
        let semanticOnly = semantic.subtracting(keyword)
        let keywordOnly = keyword.subtracting(semantic)
        return AskRecallRecord(
            atMs: atMs,
            question: clip(question),
            scopeConversations: members.count,
            packedBatches: plan.packedBatches,
            keptBatches: plan.batches.count,
            keyword: keyword.count,
            semantic: semantic.count,
            both: both.count,
            semanticOnlyKept: semanticOnly.filter(kept).count,
            keywordOnlyDropped: keywordOnly.filter { !kept($0) }.count,
            policy: policy,
            ms: ms,
            semanticRan: semanticRan)
    }

    static func clip(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > AskRecallRecord.maxQuestionChars else { return trimmed }
        return String(trimmed.prefix(AskRecallRecord.maxQuestionChars - 1)) + "…"
    }
}

/// The newest `capacity` experiment records, as one small JSON blob in a defaults suite
/// (the App Group's, in production), newest first. Small on purpose: this is a diagnostics
/// window, not a history.
///
/// `@unchecked Sendable` for the reason `UserDefaultsFirmwareHandoffLog` is: `UserDefaults` is
/// documented as thread-safe but is not marked `Sendable`, and nothing else is stored here.
public final class AskRecallLedger: @unchecked Sendable {
    public static let defaultKey = "askRecall.records"
    public static let defaultCapacity = 20

    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int

    public init(
        defaults: UserDefaults, key: String = AskRecallLedger.defaultKey,
        capacity: Int = AskRecallLedger.defaultCapacity
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = max(1, capacity)
    }

    /// Newest first.
    public func records() -> [AskRecallRecord] {
        guard let data = defaults.data(forKey: key),
            let records = try? JSONDecoder().decode([AskRecallRecord].self, from: data)
        else { return [] }
        return records
    }

    public func append(_ record: AskRecallRecord) {
        var records = records()
        records.insert(record, at: 0)
        if records.count > capacity { records.removeLast(records.count - capacity) }
        // A record that cannot be encoded is not worth crashing over; the log line already
        // carried it.
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
