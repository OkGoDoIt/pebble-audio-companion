import AppDB
import Foundation
import Testing

@testable import Intelligence

// Pass two: the only place a proposal becomes something a person sees.
//
// What is pinned here is mostly about restraint and about not losing the person's own answers:
// a dropped candidate never reaches the list, a candidate the model forgets to rule on does
// not sit at the front of every future batch, and nothing curation writes can un-tick, un-edit
// or un-archive a row somebody has already dealt with.

private final class ScriptedCurationProvider: AiProvider, @unchecked Sendable {
    let id = "scripted-curation"
    private let lock = NSLock()
    private var _response: String
    private var _requests: [AiRunRequest] = []

    init(response: String) { self._response = response }

    var response: String {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }
    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var runCount: Int { lock.withLock { _requests.count } }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _requests.append(request) }
        return AiProviderResult(text: response, modelUsed: "scripted-model")
    }
}

@Suite struct FollowUpCuratorTests {
    private let clock = TestWallClock(ms: 1_788_193_751_778)
    private let db: AppDatabase
    private let candidates: FollowUpCandidateStore
    private let followUps: FollowUpStore

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        candidates = FollowUpCandidateStore(db: db)
        followUps = FollowUpStore(db: db)
    }

    private func curator(_ provider: ScriptedCurationProvider?) -> FollowUpCurator {
        let clock = self.clock
        return FollowUpCurator(
            candidates: candidates,
            followUps: followUps,
            router: provider.map { AiModeRouter(local: $0, remote: nil, mode: { .localOnly }) },
            nowMs: { clock.now },
            timeZone: { TimeZone(identifier: "America/New_York")! },
            titleOf: { _ in "Walking to the market" })
    }

    @discardableResult
    private func candidate(
        _ id: String, task: String, conversationId: String = "conv-1",
        confidence: FollowUpConfidence = .high
    ) async throws -> FollowUpCandidate {
        let item = FollowUpCandidate(
            id: id, conversationId: conversationId, segmentId: "seg-1", task: task,
            quote: "I got to take \(task)", why: "it does not happen",
            confidence: confidence, createdAtMs: clock.now)
        try await candidates.save(item)
        return item
    }

    @Test func keepsWhatItIsToldToKeepAndWritesTheFollowUp() async throws {
        try await candidate("c1", task: "Theo to the airport at 7:00")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"keep","reason":"dated commitment",
                "task":"Take Theo to the airport at 7:00","priority":"high",
                "dueDate":"2026-09-01"}]}
                """)
        let written = try await curator(provider).curate()

        #expect(written.count == 1)
        #expect(written.first?.text == "Take Theo to the airport at 7:00")
        #expect(written.first?.priority == .high)
        #expect(written.first?.origin == .ai)
        #expect(written.first?.quote == "I got to take Theo to the airport at 7:00")
        #expect(written.first?.dueAtMs != nil)
        #expect(try await candidates.pending(limit: 10).isEmpty)
        // Something the app noticed waits for the person's review; it is not a reminder yet.
        #expect(try await followUps.list(scope: .suggested, nowMs: clock.now).count == 1)
        #expect(try await followUps.list(scope: .open, nowMs: clock.now).isEmpty)
    }

    /// A "tomorrow" spoken inside a recording is routinely behind us by the time it is read.
    /// The item may still be live, but the DATE must not reach the list — an item arriving
    /// pre-filed under Overdue on its first day is a wrong item however right the task is.
    @Test func aDueDateThatHasAlreadyGoneByIsCleared() async throws {
        try await candidate("c1", task: "Take Theo to the airport")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"keep","reason":"still to do",
                "task":"","priority":"normal","dueDate":"2026-08-20"}]}
                """)
        let written = try await curator(provider).curate()
        #expect(written.first?.dueAtMs == nil)
        #expect(written.first?.text == "Take Theo to the airport")
    }

    @Test func aDueDateOfTodayIsKept() async throws {
        try await candidate("c1", task: "Take Theo to the airport")
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(
            from: Date(timeIntervalSince1970: Double(clock.now) / 1000))
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"keep","reason":"today","task":"",
                "priority":"high","dueDate":"\(today)"}]}
                """)
        let written = try await curator(provider).curate()
        #expect(written.first?.dueAtMs != nil)
    }

    @Test func aDroppedCandidateNeverReachesTheList() async throws {
        try await candidate("c1", task: "the bins out")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"drop","reason":"a chore anyone would do",
                "task":"","priority":"normal","dueDate":""}]}
                """)
        #expect(try await curator(provider).curate().isEmpty)
        #expect(try await followUps.list(scope: .all).isEmpty)
        let decided = try await candidates.list(conversationId: "conv-1").first
        #expect(decided?.state == .dropped)
        #expect(decided?.reason == "a chore anyone would do")
    }

    @Test func aDuplicateIsRecordedAsMergedRatherThanWritten() async throws {
        try await candidate("c1", task: "Theo to the airport")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"duplicate","reason":"already on the list",
                "task":"","priority":"normal","dueDate":""}]}
                """)
        #expect(try await curator(provider).curate().isEmpty)
        #expect(try await candidates.list(conversationId: "conv-1").first?.state == .merged)
        #expect(try await followUps.list(scope: .all).isEmpty)
    }

    /// Leaving it pending would put it back at the front of the very next batch, forever.
    @Test func aCandidateWithNoDecisionIsDroppedNotLeftPending() async throws {
        try await candidate("c1", task: "one thing")
        try await candidate("c2", task: "another thing")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"drop","reason":"no","task":"",
                "priority":"normal","dueDate":""}]}
                """)
        _ = try await curator(provider).curate()
        #expect(try await candidates.pending(limit: 10).isEmpty)
        let second = try await candidates.list(conversationId: "conv-1").first { $0.id == "c2" }
        #expect(second?.state == .dropped)
        #expect(second?.reason == "curation returned no decision")
    }

    @Test func theBatchPromptShowsTheOpenListAndTheConversationTitle() async throws {
        try await followUps.add(text: "Call the dentist", nowMs: clock.now)
        try await candidate("c1", task: "Theo to the airport")
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"drop","reason":"no","task":"",
                "priority":"normal","dueDate":""}]}
                """)
        _ = try await curator(provider).curate()
        let body = provider.requests.first?.transcripts.first?.text ?? ""
        #expect(body.contains("ALREADY ON THIS PERSON'S LIST:"))
        #expect(body.contains("Call the dentist"))
        #expect(body.contains("1. Theo to the airport"))
        #expect(body.contains("Walking to the market"))
        // The transcript itself is deliberately NOT here: a proposal that needs it does not
        // survive contact with the person reading the item tomorrow either.
        #expect(!body.contains("Recorded: Monday"))
    }

    @Test func prosewhereJsonWasPromisedFailsRatherThanGuessing() async throws {
        try await candidate("c1", task: "something")
        let provider = ScriptedCurationProvider(response: "I would keep the first one.")
        await #expect(throws: AiError.self) { try await self.curator(provider).curate() }
        #expect(try await candidates.pending(limit: 10).count == 1)
    }

    @Test func withoutARouterNothingIsDecided() async throws {
        try await candidate("c1", task: "something")
        #expect(try await curator(nil).curate().isEmpty)
        #expect(try await candidates.pending(limit: 10).count == 1)
    }

    // MARK: The age rule

    @Test func filesAwayAnUntouchedProposalOnceItGoesQuiet() async throws {
        let old = clock.now - FollowUpCurator.staleAfterMs - 1_000
        try await followUps.upsertExtracted(
            FollowUp(
                id: "old", text: "Something from a fortnight ago", done: false,
                sourceConversationId: "conv-1", sourceSegmentId: "seg-1", createdAtMs: old,
                stage: .suggested))
        #expect(try await curator(nil).archiveStale() == 1)
        #expect(try await followUps.list(scope: .suggested, nowMs: clock.now).isEmpty)
        #expect(try await followUps.list(scope: .archived).count == 1)
    }

    /// Everything here is evidence that a person, not a clock, is in charge of the row.
    @Test func leavesAloneAnythingSomebodyHasTouched() async throws {
        let old = clock.now - FollowUpCurator.staleAfterMs - 1_000
        let handWritten = try await followUps.add(text: "Mine", nowMs: old)
        try await followUps.upsertExtracted(
            FollowUp(
                id: "dated", text: "Has a deadline", done: false, sourceConversationId: nil,
                sourceSegmentId: nil, createdAtMs: old, dueAtMs: clock.now + 86_400_000))
        try await followUps.upsertExtracted(
            FollowUp(
                id: "edited", text: "Reworded by hand", done: false, sourceConversationId: nil,
                sourceSegmentId: nil, createdAtMs: old, editedAtMs: old))
        try await followUps.upsertExtracted(
            FollowUp(
                id: "snoozed", text: "Put off", done: false, sourceConversationId: nil,
                sourceSegmentId: nil, createdAtMs: old,
                snoozedUntilMs: clock.now + 86_400_000))

        #expect(try await curator(nil).archiveStale() == 0)
        #expect(try await followUps.load(id: handWritten.id)?.archivedAtMs == nil)
        #expect(try await followUps.load(id: "dated")?.archivedAtMs == nil)
        #expect(try await followUps.load(id: "edited")?.archivedAtMs == nil)
        #expect(try await followUps.load(id: "snoozed")?.archivedAtMs == nil)
    }

    /// Restore used to be a no-op: un-archiving wrote only `archivedAtMs = NULL`, which left
    /// the row in exactly the state the age rule looks for, so the next pass — thirty seconds
    /// later — filed it away again while the person watched.
    @Test func restoringSomethingKeepsItOffTheAgeRule() async throws {
        let old = clock.now - FollowUpCurator.staleAfterMs - 1_000
        try await followUps.upsertExtracted(
            FollowUp(
                id: "old", text: "Something from a fortnight ago", done: false,
                sourceConversationId: "conv-1", sourceSegmentId: "seg-1", createdAtMs: old,
                stage: .suggested))
        #expect(try await curator(nil).archiveStale() == 1)

        try await followUps.setArchived(id: "old", false, nowMs: clock.now)
        #expect(try await curator(nil).archiveStale() == 0, "a clock does not overrule a person")
        #expect(try await followUps.load(id: "old")?.archivedAtMs == nil)
    }

    /// Same shape, the other way round: un-ticking an old item must not drop it into the
    /// archive on the next pass.
    @Test func unTickingSomethingOldKeepsItOffTheAgeRule() async throws {
        let old = clock.now - FollowUpCurator.staleAfterMs - 1_000
        try await followUps.upsertExtracted(
            FollowUp(
                id: "old", text: "Done a fortnight ago", done: false,
                sourceConversationId: nil, sourceSegmentId: nil, createdAtMs: old))
        try await followUps.setDone(id: "old", true, nowMs: clock.now)
        try await followUps.setDone(id: "old", false, nowMs: clock.now)
        #expect(try await curator(nil).archiveStale() == 0)
    }

    // MARK: Not spinning

    /// A batch the provider cannot answer used to stay pending, and `pending(limit:)` is
    /// deterministic — so the identical twelve candidates were re-sent every five minutes,
    /// forever, on the expensive model.
    @Test func aBatchThatKeepsFailingIsEventuallyLeftAlone() async throws {
        try await candidate("c1", task: "something")
        let provider = ScriptedCurationProvider(response: "I would keep the first one.")
        let curator = curator(provider)
        for _ in 0..<(FollowUpCurator.maxAttempts + 3) {
            _ = try? await curator.curate()
        }
        #expect(provider.runCount == FollowUpCurator.maxAttempts)
        #expect(try await candidates.pending(limit: 10).count == 1, "still visible, just not retried")
    }

    /// The date the model reasons about has to be the day of the CONVERSATION, not the day the
    /// backlog got round to reading it.
    @Test func thePromptDatesACandidateByWhenItWasSaid() async throws {
        let recorded = clock.now - 5 * 24 * 60 * 60 * 1000
        try await candidates.save(
            FollowUpCandidate(
                id: "c1", conversationId: "conv-1", segmentId: "seg-1",
                task: "Take Theo at 7:00", quote: "I got to take Theo at 7:00.",
                why: "Theo misses his ride", createdAtMs: clock.now, recordedAtMs: recorded))
        let provider = ScriptedCurationProvider(
            response: """
                {"decisions":[{"index":1,"decision":"drop","reason":"over","task":"",
                "priority":"normal","dueDate":""}]}
                """)
        _ = try await curator(provider).curate()
        let body = provider.requests.first?.transcripts.first?.text ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        let said = formatter.string(from: Date(timeIntervalSince1970: Double(recorded) / 1000))
        #expect(body.contains("recorded: \(said)"))
    }

    // MARK: The person's answers are authoritative

    /// `follow_ups` is AUTHORITATIVE. A second pass over the same conversation must never
    /// overwrite what somebody did about the item.
    @Test func reCuratingCannotUndoWhatThePersonDid() async throws {
        try await followUps.upsertExtracted(
            FollowUp(
                id: "c1", text: "Original wording", done: false, sourceConversationId: "conv-1",
                sourceSegmentId: "seg-1", createdAtMs: clock.now))
        try await followUps.setText(id: "c1", "My own wording", nowMs: clock.now)
        try await followUps.setDone(id: "c1", true, nowMs: clock.now)

        try await followUps.upsertExtracted(
            FollowUp(
                id: "c1", text: "A model's second thoughts", done: false,
                sourceConversationId: "conv-1", sourceSegmentId: "seg-1",
                createdAtMs: clock.now, priority: .high))

        let row = try await followUps.load(id: "c1")
        #expect(row?.text == "My own wording")
        #expect(row?.done == true)
        #expect(row?.completedAtMs != nil)
        // Editing locks the review details together, including the original normal priority.
        // Re-extraction may refresh provenance, but cannot silently reprioritize an edited item.
        #expect(row?.priority == .normal)
    }
}
