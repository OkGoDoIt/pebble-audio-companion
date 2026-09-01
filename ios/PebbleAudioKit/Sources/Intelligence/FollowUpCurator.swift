import AppDB
import Foundation

// Pass two of two: decide which proposals become things a person actually sees.
//
// The first pass reads one conversation and cannot see any other. That is where the old
// feature's worst symptom came from — nine sentences of one sitting arriving as nine separate
// rows, the same errand landing twice because it was mentioned on two days, and no answer at
// all to "which of these matter most". None of that is visible from inside a single
// conversation, and all of it is obvious when you lay the proposals side by side.
//
// It is also a genuine second opinion, and deliberately a harsher one. Curation is shown the
// task, the quote and the date — NOT the transcript. If a proposal only makes sense with the
// surrounding conversation in front of you, it will not make sense to the person reading it
// tomorrow either, and the honest thing is to drop it here.
public final class FollowUpCurator: @unchecked Sendable {
    /// Candidates weighed in one call. Small enough that the whole batch fits comfortably, big
    /// enough that duplicates across a day's conversations land in the same batch.
    public static let batchSize = 12

    /// Open items shown as context, so curation can recognise a duplicate of something already
    /// on the list.
    public static let openContextLimit = 30

    /// An open, AI-proposed, untouched item with no deadline leaves the working list after
    /// this long. Archived, never deleted, and one tap from coming back.
    ///
    /// This is deliberately arithmetic rather than a judgement call. A model deciding what to
    /// file away is a model quietly removing things a person may have been relying on; a clock
    /// is predictable, explainable in one sentence on screen, and cannot surprise anybody.
    public static let staleAfterMs: Int64 = 14 * 24 * 60 * 60 * 1000

    public static let modelId = FollowUpWorker.modelId
    public static let reasoningEffort = "medium"

    private let candidates: FollowUpCandidateStore
    private let followUps: FollowUpStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64
    private let timeZone: @Sendable () -> TimeZone
    private let titleOf: @Sendable (String) async -> String?

    public init(
        candidates: FollowUpCandidateStore,
        followUps: FollowUpStore,
        router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        titleOf: @escaping @Sendable (String) async -> String? = { _ in nil }
    ) {
        self.candidates = candidates
        self.followUps = followUps
        self.router = router
        self.nowMs = nowMs
        self.timeZone = timeZone
        self.titleOf = titleOf
    }

    /// Files away open items that have gone quiet. Runs whether or not AI is configured — it is
    /// arithmetic, and a person who turns remote AI off should still stop seeing a three-week
    /// old proposal at the top of their list.
    @discardableResult
    public func archiveStale() async throws -> Int {
        try await followUps.archiveStale(olderThanMs: Self.staleAfterMs, nowMs: nowMs())
    }

    /// Weighs one batch of pending candidates. Returns the follow-ups newly written.
    @discardableResult
    public func curate() async throws -> [FollowUp] {
        guard let router else { return [] }
        let batch = try await candidates.pending(limit: Self.batchSize)
        guard !batch.isEmpty else { return [] }
        guard await router.isAvailable() else { return [] }

        let now = nowMs()
        let open = try await followUps.list(scope: .open, nowMs: now)
        var titles: [String: String] = [:]
        for candidate in batch where titles[candidate.conversationId] == nil {
            if let title = await titleOf(candidate.conversationId), !title.isEmpty {
                titles[candidate.conversationId] = title
            }
        }
        let body = prompt(
            batch: batch, open: Array(open.prefix(Self.openContextLimit)), titles: titles,
            now: now)

        let result = try await router.run(
            AiRunRequest(
                requestId: "followup-curation-\(now)",
                prompt: AiPromptTemplates.followUpCuration,
                transcripts: [
                    TranscriptExcerpt(
                        segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
                ],
                metadata: [
                    AiRunRequest.modelKey: Self.modelId,
                    AiRunRequest.reasoningEffortKey: Self.reasoningEffort,
                ]))
        guard let decisions = FollowUpCurationParser.parse(raw: result.text) else {
            throw AiError.providerFailed(
                "Follow-up curation did not return the agreed JSON", underlying: nil)
        }

        var byIndex: [Int: CurationDecision] = [:]
        for decision in decisions where decision.index >= 1 && decision.index <= batch.count {
            byIndex[decision.index] = decision
        }

        var written: [FollowUp] = []
        let zone = timeZone()
        for (offset, candidate) in batch.enumerated() {
            // A candidate the model did not rule on is DROPPED, not left pending. Leaving it
            // pending would put it back at the front of the very next batch, forever, and a
            // dropped candidate is still visible in Diagnostics with its reason.
            guard let decision = byIndex[offset + 1] else {
                try await candidates.decide(
                    id: candidate.id, state: .dropped,
                    reason: "curation returned no decision", nowMs: now)
                continue
            }
            switch decision.decision.lowercased() {
            case "keep":
                let item = followUp(from: candidate, decision: decision, zone: zone, now: now)
                try await followUps.upsertExtracted(item)
                try await candidates.decide(
                    id: candidate.id, state: .kept, reason: trimmed(decision.reason), nowMs: now)
                written.append(item)
            case "duplicate":
                try await candidates.decide(
                    id: candidate.id, state: .merged, reason: trimmed(decision.reason),
                    nowMs: now)
            default:
                try await candidates.decide(
                    id: candidate.id, state: .dropped, reason: trimmed(decision.reason),
                    nowMs: now)
            }
        }
        return written
    }

    /// The follow-up row a kept candidate becomes. The candidate's id carries straight over, so
    /// re-curating the same proposal lands on the same row instead of a second copy of it.
    func followUp(
        from candidate: FollowUpCandidate, decision: CurationDecision, zone: TimeZone, now: Int64
    ) -> FollowUp {
        let rewritten = FollowUpExtractionParser.tidy(decision.task)
        let text = rewritten.isEmpty ? candidate.task : rewritten
        let due =
            FollowUpExtractionParser.isoDate(decision.dueDate)
            .flatMap { FollowUpWorker.dueAtMs($0, timeZone: zone) }
            ?? (decision.dueDate.trimmingCharacters(in: .whitespaces).isEmpty
                ? candidate.dueAtMs : nil)
        return FollowUp(
            id: candidate.id,
            text: text,
            done: false,
            sourceConversationId: candidate.conversationId,
            sourceSegmentId: candidate.segmentId,
            createdAtMs: candidate.createdAtMs,
            quote: candidate.quote,
            why: candidate.why,
            dueAtMs: due,
            priority: FollowUpCurationParser.priority(decision.priority),
            sourceStartMs: candidate.startMs,
            sourceEndMs: candidate.endMs,
            origin: .ai)
    }

    // MARK: - Prompt body

    func prompt(
        batch: [FollowUpCandidate], open: [FollowUp], titles: [String: String], now: Int64
    ) -> String {
        var out = "Today is \(dayLabel(Date(timeIntervalSince1970: Double(now) / 1000))).\n\n"
        if open.isEmpty {
            out += "This person's follow-up list is currently empty.\n\n"
        } else {
            out += "ALREADY ON THIS PERSON'S LIST:\n"
            for item in open {
                out += "- \(item.text)"
                if let due = item.dueAtMs {
                    out += " (due \(dayLabel(Date(timeIntervalSince1970: Double(due) / 1000))))"
                }
                out += "\n"
            }
            out += "\n"
        }
        out += "CANDIDATES:\n"
        for (offset, candidate) in batch.enumerated() {
            out += "\(offset + 1). \(candidate.task)\n"
            if let quote = candidate.quote, !quote.isEmpty {
                out += "   heard: \"\(quote)\"\n"
            }
            if let why = candidate.why, !why.isEmpty {
                out += "   if forgotten: \(why)\n"
            }
            let recorded = Date(timeIntervalSince1970: Double(candidate.createdAtMs) / 1000)
            out += "   recorded: \(dayLabel(recorded))"
            if let title = titles[candidate.conversationId], !title.isEmpty {
                out += " during \"\(title)\""
            }
            out += "\n"
            if let due = candidate.dueAtMs {
                out +=
                    "   proposed due: \(dayLabel(Date(timeIntervalSince1970: Double(due) / 1000)))\n"
            }
            out += "   how sure the reader was: \(candidate.confidence.rawValue)\n"
        }
        return out
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone()
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}
