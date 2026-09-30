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
    ///
    /// `FollowUpWorker.freshnessWindowMs` matches it on purpose: there is no point reading a
    /// conversation old enough that anything found in it would be filed away on arrival.
    public static let staleAfterMs: Int64 = FollowUpWorker.freshnessWindowMs

    public static let modelId = FollowUpWorker.modelId
    public static let reasoningEffort = "medium"

    /// Curation calls that failed ON THE INPUT before a batch's candidates rest. Extraction has
    /// had a budget from the start; without one here, a batch the provider could not answer
    /// stayed pending and — because `pending(limit:)` is deterministic — the identical twelve
    /// candidates were re-sent on every pass, forever, on the expensive model.
    ///
    /// Spent budgets used to be permanent too: the candidates stayed `pending`, excluded from
    /// every batch, with nothing that would ever look at them again. They now rest
    /// `AiRetryPolicy.exhaustedRetryMs` and are tried again; a failure that was the world's
    /// (offline, a busy or broke account) spends nothing and pauses curation instead.
    public static let maxAttempts = 3

    private let candidates: FollowUpCandidateStore
    private let followUps: FollowUpStore
    private let router: AiModeRouter?
    private let nowMs: @Sendable () -> Int64
    /// The device's zone: what "today" is for the person reading the list.
    private let timeZone: @Sendable () -> TimeZone
    private let titleOf: @Sendable (String) async -> String?
    /// The zone a candidate's recording was made in (by its segment id), which is what the day
    /// it was said and the day it is due are dates IN. Nil falls back to `timeZone`.
    private let recordedZoneOf: @Sendable (String) -> TimeZone?

    /// After a failure that was not the input's: no curation call before this. In memory — a
    /// relaunch costs at most one small call, and the batch itself is never charged for it.
    private let pause = NSLock()
    private var pausedUntilMs: Int64?
    private var transientFailures = 0

    public init(
        candidates: FollowUpCandidateStore,
        followUps: FollowUpStore,
        router: AiModeRouter?,
        nowMs: @escaping @Sendable () -> Int64,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        titleOf: @escaping @Sendable (String) async -> String? = { _ in nil },
        recordedZoneOf: @escaping @Sendable (String) -> TimeZone? = { _ in nil }
    ) {
        self.candidates = candidates
        self.followUps = followUps
        self.router = router
        self.nowMs = nowMs
        self.timeZone = timeZone
        self.titleOf = titleOf
        self.recordedZoneOf = recordedZoneOf
    }

    /// The zone a candidate's words were recorded in, falling back to the device's.
    func zone(of candidate: FollowUpCandidate) -> TimeZone {
        candidate.segmentId.flatMap(recordedZoneOf) ?? timeZone()
    }

    /// Files away open items that have gone quiet. Runs whether or not AI is configured — it is
    /// arithmetic, and a person who turns remote AI off should still stop seeing a three-week
    /// old proposal at the top of their list.
    @discardableResult
    public func archiveStale() async throws -> Int {
        try await followUps.archiveStale(olderThanMs: Self.staleAfterMs, nowMs: nowMs())
    }

    /// Every candidate's curation budget, and any pause, start over — the AI configuration
    /// changed, so a batch the old one could not decide may now be decided.
    public func resetRetryBudgets() async {
        pause.withLock {
            pausedUntilMs = nil
            transientFailures = 0
        }
        try? await candidates.resetAttempts()
    }

    /// Weighs one batch of pending candidates. Returns the follow-ups newly written.
    @discardableResult
    public func curate() async throws -> [FollowUp] {
        guard let router else { return [] }
        let now = nowMs()
        if let until = pause.withLock({ pausedUntilMs }), now < until { return [] }
        let batch = try await candidates.pending(
            limit: Self.batchSize, maxAttempts: Self.maxAttempts,
            retryAfterMs: AiRetryPolicy.exhaustedRetryMs, nowMs: now)
        guard !batch.isEmpty else { return [] }
        guard await router.isAvailable() else { return [] }

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

        // Only a failure on the input spends an attempt from the batch's budget — a batch that
        // keeps failing on its own content has to stop costing a call every five minutes. A
        // failure that was the world's pauses curation instead (15 minutes, doubling), and the
        // batch keeps its budget for when the provider is back.
        let result: RoutedAiResult
        do {
            result = try await router.run(
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
                        AiRunRequest.requiresStructuredOutputKey: "1",
                    ]))
        } catch let error where error is CancellationError {
            throw error
        } catch {
            if AiRetryPolicy.spendsAttempt(error) {
                try await candidates.recordAttempt(ids: batch.map(\.id), nowMs: now)
            } else {
                pause.withLock {
                    transientFailures += 1
                    pausedUntilMs =
                        now + AiRetryPolicy.transientRetryMs(consecutive: transientFailures)
                }
            }
            throw error
        }
        pause.withLock {
            pausedUntilMs = nil
            transientFailures = 0
        }
        guard let decisions = FollowUpCurationParser.parse(raw: result.text) else {
            try await candidates.recordAttempt(ids: batch.map(\.id), nowMs: now)
            throw AiError.providerFailed(
                "Follow-up curation did not return the agreed JSON", underlying: nil)
        }

        var byIndex: [Int: CurationDecision] = [:]
        for decision in decisions where decision.index >= 1 && decision.index <= batch.count {
            byIndex[decision.index] = decision
        }

        var written: [FollowUp] = []
        for (offset, candidate) in batch.enumerated() {
            // A candidate the model did not rule on is DROPPED, not left pending. Leaving it
            // pending would put it back at the front of the very next batch, forever, and a
            // dropped candidate is still visible in Diagnostics with its reason.
            //
            // Unless the model never SAW it: a reply drawn from a cut list says nothing about
            // the candidates past the cut. Those spend an attempt and stay pending.
            guard let decision = byIndex[offset + 1] else {
                if result.inputTruncated {
                    try await candidates.recordAttempt(ids: [candidate.id], nowMs: now)
                    continue
                }
                try await candidates.decide(
                    id: candidate.id, state: .dropped,
                    reason: "curation returned no decision", nowMs: now)
                continue
            }
            switch decision.decision.lowercased() {
            case "keep":
                // The due date is a day in the zone the words were SAID in (Q16), not wherever
                // the phone happens to be when curation runs.
                let item = followUp(
                    from: candidate, decision: decision, zone: zone(of: candidate), now: now)
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
        let proposed =
            FollowUpExtractionParser.isoDate(decision.dueDate)
            .flatMap { FollowUpWorker.dueAtMs($0, timeZone: zone) }
            ?? (decision.dueDate.trimmingCharacters(in: .whitespaces).isEmpty
                ? candidate.dueAtMs : nil)
        // A recording is read days after it was made, so a "tomorrow" spoken inside it is
        // routinely already behind us. The item may still be perfectly live — the prompt is
        // told to re-anchor rather than drop it — but a date that has gone by must never
        // reach the list: it would arrive pre-filed under Overdue, shouting, on its first day.
        // Belt and braces, because this is arithmetic and does not need a model to get right.
        let due = proposed.flatMap { $0 < startOfToday(now, zone) ? nil : $0 }
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
            origin: .ai,
            // The model that FOUND it — the provenance card's answer to "which model decided
            // this belongs on my list".
            model: candidate.model,
            // When the words were said, computed when the quote was located. Carried, never
            // recomputed here: curation has no segment clock in hand.
            sourceWall: candidate.sourceWall)
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
            // The conversation's own day, not the day extraction happened to read it — the
            // whole date section of the prompt resolves "tomorrow" against this line.
            let recordedMs = candidate.recordedAtMs ?? candidate.createdAtMs
            let recorded = Date(timeIntervalSince1970: Double(recordedMs) / 1000)
            // In the zone it was recorded in: "tomorrow" said in Tokyo is a Tokyo day.
            let recordedZone = zone(of: candidate)
            out += "   recorded: \(dayLabel(recorded, in: recordedZone))"
            if let title = titles[candidate.conversationId], !title.isEmpty {
                out += " during \"\(title)\""
            }
            out += "\n"
            if let due = candidate.dueAtMs {
                let dueDate = Date(timeIntervalSince1970: Double(due) / 1000)
                out += "   proposed due: \(dayLabel(dueDate, in: recordedZone))\n"
            }
            out += "   how sure the reader was: \(candidate.confidence.rawValue)\n"
        }
        return out
    }

    /// Midnight today in the capture zone — the earliest instant a due date may still name.
    func startOfToday(_ nowMs: Int64, _ zone: TimeZone) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        return Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
    }

    private func dayLabel(_ date: Date, in zone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone ?? timeZone()
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}
