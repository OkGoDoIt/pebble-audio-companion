import Foundation

// How much of the archive one Ask question gets to read.
//
// The retrieval this replaces picked twelve segments and hoped they were the right twelve. For
// a question about a moment ("what did the plumber quote?") top-k is fine. For a question about
// a LIFE ("do I have any travel booked?", "how often do I mention my back?") it is structurally
// wrong: the answer is a property of the whole archive, and no top-k can prove the absence of
// something it never looked at. The failure mode is the worst kind — a confident "nothing found"
// drawn from 2% of the recordings.
//
// So the order of preference here is:
//   1. READ EVERYTHING IN SCOPE. A quarter of a year of continuous capture is a few hundred
//      thousand tokens; modern context windows hold that whole. When it fits, there is no
//      retrieval step at all, and therefore nothing for retrieval to get wrong.
//   2. When it does not fit, SWEEP: cut the scope into context-sized batches, read each one,
//      then synthesize. Slower and dearer, but it still reads every word, so "nothing found"
//      keeps meaning what it says.
//   3. Only when even a bounded sweep cannot cover the scope does relevance choose what to drop
//      — and then the answer SAYS what it could not read.
//
// Every path reports its `AskCoverage`, and the prompt carries it. An answer drawn from part of
// the archive must never sound like an answer drawn from all of it — the same honesty rule the
// rest of the app applies to missing audio.

/// The room one model call has for transcript text.
public struct AskBudget: Equatable, Sendable {
    /// Characters of transcript that fit in one call.
    public let transcriptChars: Int
    /// Batches a sweep may run before it has to start dropping content.
    public let maxBatches: Int

    public init(transcriptChars: Int, maxBatches: Int = AskBudget.defaultMaxBatches) {
        self.transcriptChars = max(0, transcriptChars)
        self.maxBatches = max(1, maxBatches)
    }

    /// A sweep costs one model call per batch, serially in wall-clock terms. Twelve is about
    /// where a thorough answer stops being worth the wait; past it we tell the truth about the
    /// shortfall instead of spending another minute.
    public static let defaultMaxBatches = 12

    /// Sweep ceiling when an on-device model is answering. See `forMode`.
    public static let localSweepBatches = 3

    /// Conversational English runs near four characters per token. Three is deliberately
    /// pessimistic: overshooting the window fails the whole call, undershooting only reads a
    /// little less than it could.
    public static let charsPerToken = 3

    /// Reserved from the window for everything in the prompt that is not transcript — the
    /// system prompt, the time anchor, the thread so far, the question — plus the answer.
    public static let overheadTokens = 12_000

    /// The budget for a model with `contextTokens` of input window.
    public static func forContext(
        tokens contextTokens: Int, maxBatches: Int = defaultMaxBatches
    ) -> AskBudget {
        let usable = max(0, contextTokens - overheadTokens)
        return AskBudget(transcriptChars: usable * charsPerToken, maxBatches: maxBatches)
    }

    /// The budget for the model the user has selected.
    public static func forModel(id: String?, maxBatches: Int = defaultMaxBatches) -> AskBudget {
        forContext(tokens: AiModels.byId(id).contextTokens, maxBatches: maxBatches)
    }

    /// The budget for the provider that will actually answer, which is not always the remote
    /// one. On-device models hold a few thousand characters, not a few million: planning a
    /// whole-archive read for a LocalFirst user would have the provider truncate it to a
    /// fraction while the prompt still claimed to have been shown everything. Sized to the
    /// provider that runs FIRST, so a fallback can only ever be handed less than it can take.
    public static func forMode(
        _ mode: AiProcessingMode,
        modelId: String?,
        onDeviceMaxInputChars: Int = OnDeviceAiProvider.defaultMaxInputChars,
        maxBatches: Int = defaultMaxBatches
    ) -> AskBudget {
        switch mode {
        case .localOnly, .localFirst:
            // The on-device cap is a character count already; the same overhead reserve applies,
            // and the prompt framing is a much larger share of a small window.
            let reserve = min(onDeviceMaxInputChars / 4, overheadTokens * charsPerToken)
            return AskBudget(
                transcriptChars: max(0, onDeviceMaxInputChars - reserve),
                // On-device passes are serial and slow, and each one holds a few thousand
                // characters — a full twelve of them spends minutes to reach a few percent of a
                // large archive and still has to report partial coverage. Three arrives quickly
                // and says the same true thing, which is the more useful answer: a whole-archive
                // question needs a narrower scope or the cloud model, and the sooner the person
                // is told that the better.
                maxBatches: min(maxBatches, localSweepBatches))
        case .remoteOnly, .remoteFirst:
            return forModel(id: modelId, maxBatches: maxBatches)
        }
    }
}

/// What the answer was actually allowed to read. Carried into the prompt so the model cannot
/// overclaim, and shown to the user so a partial answer never looks complete.
public struct AskCoverage: Equatable, Sendable {
    /// Conversations whose transcripts reached the model.
    public let conversationsRead: Int
    /// Conversations the scope contains.
    public let conversationsInScope: Int
    /// Model calls the answer was built from (1 = single pass, >1 = a sweep).
    public let passes: Int

    public init(conversationsRead: Int, conversationsInScope: Int, passes: Int) {
        self.conversationsRead = conversationsRead
        self.conversationsInScope = conversationsInScope
        self.passes = max(1, passes)
    }

    /// True when every conversation in scope was read. Only then may an answer say "nothing".
    public var isComplete: Bool { conversationsRead >= conversationsInScope }

    public var conversationsSkipped: Int {
        max(0, conversationsInScope - conversationsRead)
    }

    /// The line the model sees. It is instructed (see `Prompts.ask`) to trust "all" as licence
    /// to state an absence, and to hedge otherwise.
    public var promptLine: String {
        if isComplete {
            return "COVERAGE: you are being shown ALL \(conversationsInScope) "
                + "\(Self.noun(conversationsInScope)) in this range, in full. If something is "
                + "not here, it was not recorded — you may say so plainly."
        }
        return "COVERAGE: you are being shown \(conversationsRead) of "
            + "\(conversationsInScope) \(Self.noun(conversationsInScope)) in this range — "
            + "\(conversationsSkipped) could not be included. Answer from what is here, and "
            + "say that you could not read the whole range rather than claiming something is "
            + "absent from it."
    }

    /// The line the user sees under the answer. Nil when coverage was complete and
    /// unremarkable — a note on every answer is noise, and the interesting case is shortfall.
    public var displayNote: String? {
        guard !isComplete else { return nil }
        return "Read \(conversationsRead) of \(conversationsInScope) "
            + "\(Self.noun(conversationsInScope)) — this range was too large to read in full."
    }

    /// Appended to the stored scope description, so Recent says how much each answer saw.
    public var scopeSuffix: String {
        isComplete
            ? "\(conversationsRead) \(Self.noun(conversationsRead)) read"
            : "\(conversationsRead) of \(conversationsInScope) \(Self.noun(conversationsInScope)) read"
    }

    static func noun(_ count: Int) -> String {
        count == 1 ? "conversation" : "conversations"
    }
}

/// The reading plan for one question: which stretches to send, cut into model-sized batches,
/// and how much of the scope that adds up to.
public struct AskCorpusPlan: Equatable, Sendable {
    /// Chronological batches of stretches. One batch is one model call's worth of transcript.
    /// A single batch is the ordinary case and needs no synthesis pass.
    public let batches: [[CitableExcerpt]]
    public let coverage: AskCoverage

    public init(batches: [[CitableExcerpt]], coverage: AskCoverage) {
        self.batches = batches
        self.coverage = coverage
    }

    public var isSinglePass: Bool { batches.count <= 1 }
    public var stretches: [CitableExcerpt] { batches.flatMap { $0 } }
}

public enum AskCorpusPlanner {
    /// Plan how to read `stretches` (chronological, already numbered) under `budget`.
    ///
    /// `relevance` scores a segment id for the question and is consulted ONLY when the scope
    /// cannot be swept inside `budget.maxBatches` — that is, it decides what to sacrifice, never
    /// what to read. Whenever the scope fits, relevance is irrelevant by construction, which is
    /// exactly the property that makes "nothing was recorded about that" trustworthy.
    public static func plan(
        stretches: [CitableExcerpt],
        budget: AskBudget,
        relevance: (String) -> Double = { _ in 0 }
    ) -> AskCorpusPlan {
        let inScope = distinctSegments(stretches)
        guard !stretches.isEmpty, budget.transcriptChars > 0 else {
            return AskCorpusPlan(
                batches: [],
                coverage: AskCoverage(
                    conversationsRead: 0, conversationsInScope: inScope, passes: 1))
        }

        var batches = pack(stretches, limit: budget.transcriptChars)

        // Beyond the sweep ceiling something has to go. Drop whole batches by their best
        // relevance — a batch is a contiguous run of days, so dropping one loses a period the
        // answer can name rather than scattering holes through every day.
        if batches.count > budget.maxBatches {
            let ranked = batches.enumerated()
                .sorted { lhs, rhs in
                    let l = score(lhs.element, relevance)
                    let r = score(rhs.element, relevance)
                    if l != r { return l > r }
                    // Nothing to choose between them on relevance: prefer the recent one. A
                    // question asked today is far more often about this month than about the
                    // first week of the archive.
                    return lhs.offset > rhs.offset
                }
                .prefix(budget.maxBatches)
                .map(\.offset)
                .sorted()
            batches = ranked.map { batches[$0] }
        }

        return AskCorpusPlan(
            batches: batches,
            coverage: AskCoverage(
                conversationsRead: distinctSegments(batches.flatMap { $0 }),
                conversationsInScope: inScope,
                passes: max(1, batches.count)))
    }

    /// Chronological packing. Order is never disturbed: the model reads the archive forwards,
    /// which is what lets it resolve "we decided the opposite last week".
    ///
    /// Filling each batch to the brim leaves a runt at the end — a whole extra model call for
    /// the last few minutes of transcript. So the batch count is worked out first and the
    /// content spread evenly across it: same coverage, fewer calls, and no pass so thin that
    /// its findings have no context around them.
    static func pack(_ stretches: [CitableExcerpt], limit: Int) -> [[CitableExcerpt]] {
        // The framing each stretch carries in the prompt (its `[n]`, the recorded-at line)
        // costs tokens too; charge for it so a batch of many short stretches cannot creep past
        // the window.
        let costs = stretches.map { $0.text.count + Self.stretchOverheadChars }
        let total = costs.reduce(0, +)
        guard total > limit else { return stretches.isEmpty ? [] : [stretches] }

        let count = Int((Double(total) / Double(limit)).rounded(.up))
        let target = max(1, Int((Double(total) / Double(count)).rounded(.up)))
        var batches: [[CitableExcerpt]] = []
        var current: [CitableExcerpt] = []
        var used = 0
        for (stretch, cost) in zip(stretches, costs) {
            // `target` is the goal, `limit` the hard wall: a single stretch larger than target
            // must still not be allowed to push a batch past what the model can hold.
            let wouldExceed = used + cost > (batches.count + 1 < count ? target : limit)
            if !current.isEmpty, wouldExceed, used + cost > limit || used >= target {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(stretch)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Roughly the `[n] (recorded Saturday, 29 August 2026, 9:35 PM – 9:51 PM (yesterday))`
    /// header and the blank line between stretches.
    static let stretchOverheadChars = 80

    private static func score(_ batch: [CitableExcerpt], _ relevance: (String) -> Double) -> Double {
        var seen = Set<String>()
        var total: Double = 0
        var best: Double = 0
        for stretch in batch where seen.insert(stretch.segmentId).inserted {
            let value = relevance(stretch.segmentId)
            total += value
            best = max(best, value)
        }
        // Sum finds the batch that is broadly on-topic; the best single hit keeps a batch that
        // holds one decisive conversation from losing to a batch that is vaguely related
        // throughout.
        return total + best
    }

    private static func distinctSegments(_ stretches: [CitableExcerpt]) -> Int {
        var seen = Set<String>()
        for stretch in stretches { seen.insert(stretch.segmentId) }
        return seen.count
    }
}
