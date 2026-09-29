import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// The AI workers' retry budgets (`AiRetryPolicy`).
//
// Before: three final attempts with no time between them and nothing that ever reset them
// (titles), two for follow-ups, three for curation with candidates left `pending` forever once
// spent. An afternoon offline — or one rate-limited minute — cost a conversation its title and
// its follow-ups for the life of the database. And a fallback that read the first stretch of a
// four-hour conversation was saved as its final, authoritative title.

private final class Scripted: AiProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _text: String
    private var _error: Error?
    private var _truncated: Bool
    private var _calls = 0

    init(_ id: String, text: String, error: Error? = nil, truncated: Bool = false) {
        self.id = id
        _text = text
        _error = error
        _truncated = truncated
    }

    var calls: Int { lock.withLock { _calls } }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var text: String {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let (error, text, truncated): (Error?, String, Bool) = lock.withLock {
            _calls += 1
            return (_error, _text, _truncated)
        }
        if let error { throw error }
        return AiProviderResult(text: text, modelUsed: "\(id)-model", inputTruncated: truncated)
    }
}

/// The world's failure: the provider had trouble (a parenthesised 5xx).
private let outage = AiError.providerFailed("OpenAI responses request failed (503): overloaded")
private let annotationReply = "TITLE: Team sync\nSUMMARY: Discussed the plan.\nTAGS: work"

private func meta(_ id: String) -> SegmentMeta {
    SegmentMeta(
        segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
        frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
        startTimeMs: 1_788_193_700_000, startMonotonicMs: 1, receivedAtMs: 1_788_193_700_000,
        closeReason: .rotated, transcriptionState: .complete)
}

private func transcript(_ id: String, _ text: String) -> SegmentTranscript {
    SegmentTranscript(
        segmentId: id, text: text, modeUsed: .localOnly, providerId: "local", createdAtMs: 0)
}

private let finished = [
    EnrichmentConversation(conversationId: "conv-1", isOpen: false, members: [meta("seg-1")])
]

@Suite("AI retry budgets — spend attempts on the input, time on the world")
struct AiRetryBudgetTests {
    private let clock = TestWallClock(ms: 1_788_193_751_778)

    private func enrichment(
        local: Scripted?, remote: Scripted?, mode: AiProcessingMode
    ) throws -> (EnrichmentWorker, AnnotationStore) {
        let clock = self.clock
        let store = try AnnotationStore(db: try AppDatabase.inMemory(), nowMs: { clock.now })
        let worker = EnrichmentWorker(
            annotations: store,
            router: AiModeRouter(local: local, remote: remote, mode: { mode }),
            nowMs: { clock.now })
        return (worker, store)
    }

    private func enrich(_ worker: EnrichmentWorker) async throws {
        _ = try await worker.enrich(
            finished, transcriptOf: { transcript($0, "We agreed on the plan for the launch.") })
    }

    // MARK: Titles

    @Test func anOutageSpendsNoAttemptAndBacksOffInTime() async throws {
        let cloud = Scripted("cloud", text: annotationReply, error: outage)
        let (worker, store) = try enrichment(local: nil, remote: cloud, mode: .remoteOnly)

        try await enrich(worker)
        var record = try #require(try await store.load("conv-1"))
        #expect(record.finalAttempts == 0)
        #expect(record.transientFailures == 1)
        #expect(record.nextAttemptAtMs == clock.now + AiRetryPolicy.firstTransientRetryMs)

        // Every pass inside the backoff costs nothing.
        for _ in 0..<10 {
            clock.advance(byMs: 60_000)
            try await enrich(worker)
        }
        #expect(cloud.calls == 1)

        // Then once more, and the next wait doubles.
        clock.advance(byMs: AiRetryPolicy.firstTransientRetryMs)
        try await enrich(worker)
        #expect(cloud.calls == 2)
        record = try #require(try await store.load("conv-1"))
        #expect(record.transientFailures == 2)
        #expect(record.nextAttemptAtMs == clock.now + 2 * AiRetryPolicy.firstTransientRetryMs)

        // A whole day of outage never spends the budget: the title arrives when it ends.
        for _ in 0..<24 {
            clock.advance(byMs: 60 * 60_000)
            try await enrich(worker)
        }
        #expect(try await store.load("conv-1")?.finalAttempts == 0)
        cloud.error = nil
        clock.advance(byMs: AiRetryPolicy.maxRetryMs)
        try await enrich(worker)
        let titled = try #require(try await store.load("conv-1"))
        #expect(titled.isFinal)
        #expect(titled.title == "Team sync")
        #expect(titled.nextAttemptAtMs == nil)
    }

    /// Remote first, the cloud is down, and the on-device fallback can only read the first
    /// stretch of the conversation. Its title is SHOWN — better than a blank row — but it is not
    /// final, and the preferred provider writes the real one once it is back.
    @Test func aFallbackThatReadPartOfAConversationIsShownButNeverFinal() async throws {
        let cloud = Scripted("cloud", text: "TITLE: The whole day\nSUMMARY: All of it.", error: outage)
        let phone = Scripted("phone", text: "TITLE: The first hour\nSUMMARY: Part.", truncated: true)
        let (worker, store) = try enrichment(local: phone, remote: cloud, mode: .remoteFirst)

        try await enrich(worker)
        let provisional = try #require(try await store.load("conv-1"))
        #expect(provisional.title == "The first hour")
        #expect(provisional.isFinal == false)
        #expect(provisional.lastError?.hasPrefix("provisional") == true)
        #expect(provisional.finalAttempts == 0)
        #expect(provisional.nextAttemptAtMs == clock.now + AiRetryPolicy.provisionalRetryMs)

        clock.advance(byMs: AiRetryPolicy.provisionalRetryMs / 2)
        try await enrich(worker)
        #expect(cloud.calls == 1)

        cloud.error = nil
        clock.advance(byMs: AiRetryPolicy.provisionalRetryMs)
        try await enrich(worker)
        let final = try #require(try await store.load("conv-1"))
        #expect(final.title == "The whole day")
        #expect(final.isFinal)
    }

    /// Local only on a long conversation: the on-device model's cut is the best there will ever
    /// be, and it is final.
    @Test func thePreferredProvidersOwnCutIsFinal() async throws {
        let phone = Scripted("phone", text: annotationReply, truncated: true)
        let (worker, store) = try enrichment(local: phone, remote: nil, mode: .localOnly)
        try await enrich(worker)
        #expect(try await store.load("conv-1")?.isFinal == true)
    }

    @Test func aConfigurationChangeStartsEveryBudgetOver() async throws {
        let cloud = Scripted("cloud", text: annotationReply, error: AiError.providerFailed("???"))
        let (worker, store) = try enrichment(local: nil, remote: cloud, mode: .remoteOnly)
        for _ in 0..<EnrichmentWorker.maxAttempts {
            try await enrich(worker)
            clock.advance(byMs: AiRetryPolicy.contentRetryMs)
        }
        #expect(cloud.calls == EnrichmentWorker.maxAttempts)
        try await enrich(worker)
        #expect(cloud.calls == EnrichmentWorker.maxAttempts, "a spent budget rests")

        cloud.error = nil
        await worker.resetRetryBudgets()
        try await enrich(worker)
        #expect(cloud.calls == EnrichmentWorker.maxAttempts + 1)
        #expect(try await store.load("conv-1")?.isFinal == true)
    }

    // MARK: Follow-ups

    private static let longText =
        String(repeating: "We talked about the week and what is left to do. ", count: 5)
        + "I got to take Theo at 7:00. "

    private func followUps(
        local: Scripted?, remote: Scripted?, mode: AiProcessingMode
    ) throws -> (FollowUpWorker, FollowUpExtractionStore, FollowUpCandidateStore) {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let state = try FollowUpExtractionStore(db: db)
        let clock = self.clock
        let worker = FollowUpWorker(
            candidates: candidates, state: state,
            router: AiModeRouter(local: local, remote: remote, mode: { mode }),
            nowMs: { clock.now })
        return (worker, state, candidates)
    }

    private static let oneItem = """
        {"items": [{"task": "Take Theo at 7:00", "quote": "I got to take Theo at 7:00.",
          "ifForgotten": "Theo misses his ride", "dueDate": "", "confidence": "high"}]}
        """

    @Test func aFollowUpOutageSpendsNoAttempt() async throws {
        let cloud = Scripted("cloud", text: Self.oneItem, error: outage)
        let (worker, state, _) = try followUps(local: nil, remote: cloud, mode: .remoteOnly)
        for _ in 0..<5 {
            _ = try await worker.extract(finished, transcriptOf: { transcript($0, Self.longText) })
            clock.advance(byMs: AiRetryPolicy.firstTransientRetryMs)
        }
        let record = try #require(try await state.load("conv-1"))
        #expect(record.attempts == 0)
        #expect(record.settled == false)
        #expect(record.transientFailures >= 2)
        // Backed off: five passes 15 minutes apart are not five calls.
        #expect(cloud.calls < 5)
    }

    /// A fallback that read part of the conversation found real items in that part — they are
    /// kept — but it cannot say the rest holds none, so the conversation is not settled.
    @Test func aProvisionalExtractionKeepsItsItemsButDoesNotSettle() async throws {
        let cloud = Scripted("cloud", text: Self.oneItem, error: outage)
        let phone = Scripted("phone", text: Self.oneItem, truncated: true)
        let (worker, state, candidates) = try followUps(
            local: phone, remote: cloud, mode: .remoteFirst)

        _ = try await worker.extract(finished, transcriptOf: { transcript($0, Self.longText) })

        #expect(try await candidates.list(conversationId: "conv-1").count == 1)
        let record = try #require(try await state.load("conv-1"))
        #expect(record.settled == false)
        #expect(record.lastError?.hasPrefix("provisional") == true)
        #expect(record.nextAttemptAtMs == clock.now + AiRetryPolicy.provisionalRetryMs)

        cloud.error = nil
        clock.advance(byMs: AiRetryPolicy.provisionalRetryMs)
        _ = try await worker.extract(finished, transcriptOf: { transcript($0, Self.longText) })
        #expect(try await state.load("conv-1")?.settled == true)
        #expect(try await candidates.list(conversationId: "conv-1").count == 1, "no duplicate")
    }

    // MARK: Curation

    private func curation(_ provider: Scripted) throws -> (FollowUpCurator, FollowUpCandidateStore) {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let clock = self.clock
        let curator = FollowUpCurator(
            candidates: candidates, followUps: FollowUpStore(db: db),
            router: AiModeRouter(local: nil, remote: provider, mode: { .remoteOnly }),
            nowMs: { clock.now })
        return (curator, candidates)
    }

    private func seed(_ candidates: FollowUpCandidateStore) async throws {
        try await candidates.save(
            FollowUpCandidate(
                id: "c1", conversationId: "conv-1", segmentId: "seg-1", task: "Call Dana",
                quote: "I have to call Dana tomorrow.", why: "she waits", createdAtMs: clock.now))
    }

    @Test func aCurationOutagePausesCurationAndSpendsNothing() async throws {
        let cloud = Scripted("cloud", text: "", error: outage)
        let (curator, candidates) = try curation(cloud)
        try await seed(candidates)

        _ = try? await curator.curate()
        _ = try? await curator.curate()
        #expect(cloud.calls == 1, "paused, not re-sent on the next pass")
        #expect(try await candidates.pending(limit: 10).first?.attempts == 0)

        clock.advance(byMs: AiRetryPolicy.firstTransientRetryMs)
        _ = try? await curator.curate()
        #expect(cloud.calls == 2)
    }

    /// A spent candidate used to stay `pending` forever, excluded from every batch.
    @Test func aSpentCandidateRestsAndIsThenCuratedAgain() async throws {
        let cloud = Scripted("cloud", text: "I would keep it, probably.")
        let (curator, candidates) = try curation(cloud)
        try await seed(candidates)
        for _ in 0..<(FollowUpCurator.maxAttempts + 2) { _ = try? await curator.curate() }
        #expect(cloud.calls == FollowUpCurator.maxAttempts)

        clock.advance(byMs: AiRetryPolicy.exhaustedRetryMs)
        cloud.text = """
            {"decisions":[{"index":1,"decision":"keep","reason":"real","task":"",
            "priority":"normal","dueDate":""}]}
            """
        let written = try await curator.curate()
        #expect(written.count == 1)
        #expect(try await candidates.pending(limit: 10).isEmpty)
    }

    @Test func aResetGivesSpentCandidatesTheirBudgetBack() async throws {
        let cloud = Scripted("cloud", text: "not json")
        let (curator, candidates) = try curation(cloud)
        try await seed(candidates)
        for _ in 0..<FollowUpCurator.maxAttempts { _ = try? await curator.curate() }
        #expect(try await candidates.pending(limit: 10, maxAttempts: FollowUpCurator.maxAttempts)
            .isEmpty)
        await curator.resetRetryBudgets()
        #expect(
            try await candidates.pending(limit: 10, maxAttempts: FollowUpCurator.maxAttempts)
                .count == 1)
    }

    // MARK: The classification itself

    @Test func onlyAFailureOnTheInputSpendsAnAttempt() {
        let spends: [Error] = [
            AiError.providerFailed("This recording is too long for on-device AI. It would fit…"),
            AiError.providerFailed("On-device AI declined this recording. Cloud AI has…"),
            AiError.providerFailed("OpenAI responses returned an empty completion"),
            AiError.providerFailed("Follow-up extraction did not return the agreed JSON"),
        ]
        let doesNot: [Error] = [
            outage,
            AiError.providerFailed("OpenAI responses request failed (429): slow down"),
            AiError.providerFailed("OpenAI is out of credit (402); no AI request is sent"),
            AiError.providerFailed("OpenAI responses request failed (401): bad key"),
            AiError.providerUnavailable(providerId: "openai-chat"),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            AiError.providerFailed("The on-device model is busy. Try again in a moment."),
        ]
        for error in spends { #expect(AiRetryPolicy.spendsAttempt(error), "\(error)") }
        for error in doesNot { #expect(!AiRetryPolicy.spendsAttempt(error), "\(error)") }
    }

    @Test func theWorldsBackoffDoublesToSixHours() {
        #expect(AiRetryPolicy.transientRetryMs(consecutive: 1) == 15 * 60_000)
        #expect(AiRetryPolicy.transientRetryMs(consecutive: 2) == 30 * 60_000)
        #expect(AiRetryPolicy.transientRetryMs(consecutive: 3) == 60 * 60_000)
        #expect(AiRetryPolicy.transientRetryMs(consecutive: 6) == AiRetryPolicy.maxRetryMs)
        #expect(AiRetryPolicy.transientRetryMs(consecutive: 60) == AiRetryPolicy.maxRetryMs)
    }
}
