import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// Pass one: propose candidates from one finished conversation.
//
// The properties that make this safe to leave running unattended:
//   - a finished conversation with a transcript produces candidates, one provider call;
//   - a conversation with nothing actionable settles and is never asked about again;
//   - a re-run duplicates nothing;
//   - an item whose quote is not in the recording never lands, whatever the model claimed;
//   - the whole thing stops at the freshness window rather than mining a year of archive.

private final class ScriptedAiProvider: AiProvider, @unchecked Sendable {
    let id = "scripted"

    private let lock = NSLock()
    private var _response: String
    private var _error: Error?
    private var _requests: [AiRunRequest] = []

    init(response: String, error: Error? = nil) {
        self._response = response
        self._error = error
    }

    var response: String {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var runCount: Int { lock.withLock { _requests.count } }
    var requests: [AiRunRequest] { lock.withLock { _requests } }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let error: Error? = lock.withLock {
            _requests.append(request)
            return _error
        }
        if let error { throw error }
        return AiProviderResult(text: response, modelUsed: "scripted-model")
    }
}

private struct ScriptedFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Suite struct FollowUpWorkerTests {
    private let clock = TestWallClock(ms: 1_788_193_751_778)
    private let db: AppDatabase
    private let candidates: FollowUpCandidateStore
    private let state: FollowUpExtractionStore

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        candidates = FollowUpCandidateStore(db: db)
        state = try FollowUpExtractionStore(db: db)
    }

    // MARK: Harness

    private func meta(
        _ segmentId: String,
        startTimeMs: UInt64 = 1_788_193_700_000,
        state: TranscriptionState = .complete,
        open: Bool = false
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId,
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: startTimeMs,
            startMonotonicMs: 1,
            receivedAtMs: Int64(startTimeMs),
            closeReason: open ? nil : .rotated,
            transcriptionState: state
        )
    }

    private func conversation(
        _ id: String, members: [SegmentMeta], open: Bool = false
    ) -> EnrichmentConversation {
        EnrichmentConversation(conversationId: id, isOpen: open, members: members)
    }

    /// Comfortably past `FollowUpWorker.minChars`, and containing the two sentences the
    /// scripted responses quote, so the locator has something real to find.
    private static let longText =
        String(repeating: "We talked about the week and what is left to do. ", count: 5)
        + "I got to take Theo at 7:00. "
        + "We have to return the van by 11:00. "
        + String(repeating: "Then the conversation moved on to other things. ", count: 5)

    private func transcript(_ segmentId: String, text: String = longText) -> SegmentTranscript {
        SegmentTranscript(
            segmentId: segmentId, text: text, modeUsed: .localOnly, providerId: "local",
            createdAtMs: 0)
    }

    private func worker(_ provider: ScriptedAiProvider?) -> FollowUpWorker {
        let clock = self.clock
        return FollowUpWorker(
            candidates: candidates,
            state: state,
            router: provider.map { AiModeRouter(local: $0, remote: nil, mode: { .localOnly }) },
            nowMs: { clock.now },
            timeZone: { TimeZone(identifier: "America/New_York")! }
        )
    }

    private static let twoItems = """
        {"items": [
          {"task": "Take Theo to the airport at 7:00",
           "quote": "I got to take Theo at 7:00.",
           "ifForgotten": "Theo misses his ride", "dueDate": "2026-09-01", "confidence": "high"},
          {"task": "Return the van to the depot by 11:00",
           "quote": "We have to return the van by 11:00.",
           "ifForgotten": "the van goes back late", "dueDate": "",
           "confidence": "medium"}
        ]}
        """

    // MARK: Cases

    @Test func aFinishedConversationProducesGroundedCandidates() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let written = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })

        #expect(written == 2)
        #expect(provider.runCount == 1)
        #expect(
            provider.requests.first?.prompt.id == AiPromptTemplates.followUpExtraction.id)

        let rows = try await candidates.list(conversationId: "conv-1")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.state == .pending })
        #expect(rows.allSatisfy { $0.segmentId == "seg-1" })
        #expect(Set(rows.map(\.task)) == [
            "Take Theo to the airport at 7:00", "Return the van to the depot by 11:00",
        ])
        // Nothing reaches the person from this pass. Curation decides.
        #expect(try await FollowUpStore(db: db).list(scope: .all).isEmpty)
    }

    /// A model may name a stronger model for one job. Follow-ups do — this is the seam that
    /// stops the cheapest model from deciding what a person sees on a list they trust.
    @Test func asksForTheStrongerModelAndMoreThinking() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        let metadata = provider.requests.first?.metadata
        #expect(metadata?[AiRunRequest.modelKey] == FollowUpWorker.modelId)
        #expect(metadata?[AiRunRequest.reasoningEffortKey] == FollowUpWorker.reasoningEffort)
    }

    /// The whole conversation goes in, with real local times and speaker turns — not
    /// `epoch ms 1788193751778` and not one flattened paragraph.
    @Test func sendsARealDateAndSpeakerTurns() async throws {
        let provider = ScriptedAiProvider(response: #"{"items":[]}"#)
        let turned = SegmentTranscript(
            segmentId: "seg-1", text: Self.longText, modeUsed: .localOnly, providerId: "local",
            createdAtMs: 0,
            segments: [
                TranscriptSegment(
                    text: Self.longText, startMs: 0, endMs: 9_000, speaker: "2")
            ])
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { _ in turned })
        let body = provider.requests.first?.transcripts.first?.text ?? ""
        #expect(body.contains("Recorded: Monday, 2026-08-31"))
        #expect(body.contains("S2: "))
        #expect(!body.contains("epoch ms"))
        #expect(
            provider.requests.first?.transcripts.first?.segmentId
                == AiTranscriptFormatting.prebuiltSegmentId)
    }

    /// The check a schema cannot make: the model claimed words the recording does not contain.
    @Test func dropsAnItemWhoseQuoteIsNotInTheRecording() async throws {
        let provider = ScriptedAiProvider(
            response: """
                {"items":[
                  {"task":"File the quarterly report",
                   "quote":"I will file the quarterly report on Monday",
                   "ifForgotten":"the filing is late","dueDate":"","confidence":"high"},
                  {"task":"Take Theo to the airport at 7:00",
                   "quote":"I got to take Theo at 7:00.",
                   "ifForgotten":"Theo misses his ride","dueDate":"","confidence":"high"}]}
                """)
        let written = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })

        #expect(written == 1)
        let rows = try await candidates.list(conversationId: "conv-1")
        #expect(rows.map(\.task) == ["Take Theo to the airport at 7:00"])
    }

    @Test func anEmptyAnswerSettlesAndIsNeverAskedAgain() async throws {
        let provider = ScriptedAiProvider(response: #"{"items":[]}"#)
        let worker = worker(provider)
        for _ in 0..<3 {
            _ = try await worker.extract(
                [conversation("conv-1", members: [meta("seg-1")])],
                transcriptOf: { self.transcript($0) })
        }
        #expect(provider.runCount == 1)
        let settled = try await state.load("conv-1")
        #expect(settled?.settled == true)
        #expect(settled?.itemCount == 0)
    }

    @Test func aShortTranscriptSettlesWithoutACall() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0, text: "Hi. Bye.") })
        #expect(provider.runCount == 0)
        #expect(try await state.load("conv-1")?.settled == true)
    }

    /// A commitment nobody has thought about in a month is history, not a follow-up — and it
    /// is the difference between one call and one call per conversation in the archive.
    @Test func aConversationOlderThanTheWindowSettlesWithoutACall() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let old = meta(
            "seg-old",
            startTimeMs: UInt64(clock.now - FollowUpWorker.freshnessWindowMs - 60_000))
        _ = try await worker(provider).extract(
            [conversation("conv-old", members: [old])],
            transcriptOf: { self.transcript($0) })
        #expect(provider.runCount == 0)
        #expect(try await state.load("conv-old")?.settled == true)
    }

    @Test func reRunningOnAGrownTranscriptDoesNotDuplicate() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0, text: Self.longText + " And a little more.") })

        #expect(provider.runCount == 2)
        #expect(try await candidates.list(conversationId: "conv-1").count == 2)
    }

    /// A candidate curation has already ruled on must not slide back into the queue, or the
    /// same batch is judged forever.
    @Test func aDecidedCandidateStaysDecidedAcrossAReRun() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        let first = try await candidates.list(conversationId: "conv-1")[0]
        try await candidates.decide(
            id: first.id, state: .dropped, reason: "already done", nowMs: clock.now)

        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0, text: Self.longText + " More words here.") })

        let after = try await candidates.list(conversationId: "conv-1").first { $0.id == first.id }
        #expect(after?.state == .dropped)
        #expect(after?.reason == "already done")
        #expect(try await candidates.pending(limit: 10).count == 1)
    }

    @Test func aFailingProviderIsBounded() async throws {
        let provider = ScriptedAiProvider(
            response: "", error: ScriptedFailure(message: "provider exploded"))
        let worker = worker(provider)
        for _ in 0..<5 {
            _ = try await worker.extract(
                [conversation("conv-1", members: [meta("seg-1")])],
                transcriptOf: { self.transcript($0) })
        }
        #expect(provider.runCount == FollowUpWorker.maxAttempts)
        let settled = try await state.load("conv-1")
        #expect(settled?.settled == false)
        #expect(settled?.lastError == "provider exploded")
    }

    /// Prose where JSON was promised is a failed call, not a lenient one. This is the shape
    /// that used to put "Here are the action items I found:" on somebody's list.
    @Test func proseIsAFailedCallAndWritesNothing() async throws {
        let provider = ScriptedAiProvider(
            response: "Here are the action items I found:\n- Send Dana the measurements")
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        #expect(try await candidates.list(conversationId: "conv-1").isEmpty)
        #expect(try await state.load("conv-1")?.settled == false)
    }

    @Test func onlyClosedFullyTranscribedConversationsAreCandidates() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        _ = try await worker.extract(
            [conversation("live", members: [meta("s1")], open: true)],
            transcriptOf: { self.transcript($0) })
        _ = try await worker.extract(
            [conversation("pending", members: [meta("s2", state: .pending)])],
            transcriptOf: { self.transcript($0) })
        _ = try await worker.extract(
            [conversation("empty", members: [])], transcriptOf: { self.transcript($0) })
        #expect(provider.runCount == 0)
    }

    @Test func aBacklogIsCappedPerPassNewestFirst() async throws {
        let provider = ScriptedAiProvider(response: #"{"items":[]}"#)
        let conversations = (0..<20).map { index in
            conversation(
                "conv-\(index)",
                members: [
                    meta("seg-\(index)", startTimeMs: UInt64(1_788_193_700_000 + index * 1_000))
                ])
        }
        _ = try await worker(provider).extract(
            conversations, transcriptOf: { self.transcript($0) })
        #expect(provider.runCount == FollowUpWorker.maxPerPass)
        let settled = try await state.all()
        #expect(Set(settled.keys) == ["conv-19", "conv-18", "conv-17"])
    }

    /// Two passes during a revoked key or a flight used to cost those conversations their
    /// follow-ups for the life of the database — the budget only reset when the transcript's
    /// length changed, and nothing else re-enabled them.
    @Test func aConversationComesBackAfterTheProviderRecovers() async throws {
        let provider = ScriptedAiProvider(
            response: "", error: ScriptedFailure(message: "no key"))
        let worker = worker(provider)
        for _ in 0..<4 {
            _ = try await worker.extract(
                [conversation("conv-1", members: [meta("seg-1")])],
                transcriptOf: { self.transcript($0) })
        }
        #expect(provider.runCount == FollowUpWorker.maxAttempts)

        clock.advance(byMs: FollowUpWorker.retryAfterMs + 1_000)
        provider.error = nil
        provider.response = Self.twoItems
        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })

        #expect(provider.runCount == FollowUpWorker.maxAttempts + 1)
        #expect(try await candidates.list(conversationId: "conv-1").count == 2)
    }

    /// The answer is only meaningful in the schema the prompt names, so the request says so —
    /// otherwise the mode router quietly hands it to a model that enforces none.
    @Test func theCallDemandsTheSchemaItNeeds() async throws {
        let provider = ScriptedAiProvider(response: #"{"items":[]}"#)
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        #expect(
            provider.requests.first?.metadata[AiRunRequest.requiresStructuredOutputKey] == "1")
    }

    /// Curation resolves "tomorrow" against the day the conversation happened, so the
    /// candidate has to carry it.
    @Test func aCandidateRemembersWhenTheConversationHappened() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let started: UInt64 = 1_788_100_000_000
        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1", startTimeMs: started)])],
            transcriptOf: { self.transcript($0) })
        let rows = try await candidates.list(conversationId: "conv-1")
        #expect(rows.allSatisfy { $0.recordedAtMs == Int64(started) })
        #expect(rows.allSatisfy { $0.recordedAtMs != $0.createdAtMs })
    }

    @Test func withoutARouterNothingIsWrittenAndNothingIsSettled() async throws {
        _ = try await worker(nil).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        #expect(try await candidates.list(conversationId: "conv-1").isEmpty)
        #expect(try await state.load("conv-1") == nil)
    }

    @Test func forgettingAConversationClearsBothItsTables() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        _ = try await worker.extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { self.transcript($0) })
        await worker.forgetExtraction(conversationId: "conv-1")
        #expect(try await state.load("conv-1") == nil)
        #expect(try await candidates.list(conversationId: "conv-1").isEmpty)
    }

    /// A due date is a DAY in the capture zone. Stamping midnight UTC is how an item shows as
    /// overdue on the morning it is actually due.
    @Test func aDueDateBecomesTheStartOfThatDayLocally() {
        let zone = TimeZone(identifier: "America/New_York")!
        let ms = FollowUpWorker.dueAtMs("2026-09-04", timeZone: zone)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        #expect(
            formatter.string(from: Date(timeIntervalSince1970: Double(ms!) / 1000))
                == "2026-09-04 00:00")
        #expect(FollowUpWorker.dueAtMs("", timeZone: zone) == nil)
        #expect(FollowUpWorker.dueAtMs("sometime", timeZone: zone) == nil)
    }
}
