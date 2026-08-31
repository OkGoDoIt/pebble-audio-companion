import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// The stage that was missing: `FollowUps.swift` was ported whole and called by nothing, so
// every conversation truthfully reported "All caught up.". These pin the four properties that
// make automatic extraction safe to leave running unattended:
//   - a finished conversation with a transcript produces follow-ups;
//   - one with nothing actionable produces none AND never asks again;
//   - a re-run duplicates nothing;
//   - a user's `done` survives a re-extraction (`follow_ups` is AUTHORITATIVE, plan 6.5).

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
    private let clock = TestWallClock(ms: 100_000)
    private let db: AppDatabase
    private let items: ActionItemStore
    private let state: FollowUpExtractionStore

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        let clock = self.clock
        items = ActionItemStore(db: db, nowMs: { clock.now })
        state = try FollowUpExtractionStore(db: db)
    }

    // MARK: Harness

    private func meta(
        _ segmentId: String,
        startTimeMs: UInt64 = 1_000,
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

    /// Comfortably past `FollowUpWorker.minChars`, so the char gate is never the thing under
    /// test unless a case says so.
    private static let longText = String(
        repeating: "We agreed on the plan and someone will follow up. ", count: 6)

    private func transcript(_ segmentId: String, text: String = longText) -> SegmentTranscript {
        SegmentTranscript(
            segmentId: segmentId, text: text, modeUsed: .localOnly, providerId: "local",
            createdAtMs: 0)
    }

    private func worker(_ provider: ScriptedAiProvider?) -> FollowUpWorker {
        let clock = self.clock
        return FollowUpWorker(
            items: items,
            state: state,
            router: provider.map { AiModeRouter(local: $0, remote: nil, mode: { .localOnly }) },
            nowMs: { clock.now }
        )
    }

    private static let twoItems = """
        {"items": [
          {"task": "Send Dana the measurements", "owner": "Roger", "due": "", "sourceSegmentId": ""},
          {"task": "Book the electrician", "owner": "", "due": "Friday", "sourceSegmentId": ""}
        ]}
        """

    // MARK: Cases

    @Test func aFinishedConversationWithATranscriptProducesFollowUps() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)

        let written = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { transcript($0) })

        #expect(written.count == 2)
        #expect(provider.runCount == 1)
        // The strict structured-output path: the template id is what providers key the
        // `action_items` json_schema off.
        #expect(provider.requests.first?.prompt.id == AiPromptTemplates.actionItems.id)

        let stored = try await items.list()
        #expect(
            Set(stored.map(\.text)) == [
                "Send Dana the measurements. Owner: Roger",
                "Book the electrician. Due: Friday",
            ])
        // Without this the conversation view's Follow-ups sheet — which reads
        // `FollowUpStore.list(conversationId:)` — stays empty however many items exist.
        #expect(stored.allSatisfy { $0.sourceConversationId == "conv-1" })
        #expect(stored.allSatisfy { $0.sourceSegmentId == "seg-1" })

        let followUps = try await FollowUpStore(db: db).list(conversationId: "conv-1")
        #expect(followUps.count == 2)
    }

    @Test func nothingActionableSettlesAndIsNeverAskedAgain() async throws {
        let provider = ScriptedAiProvider(response: "No action items found.")
        let worker = worker(provider)
        let input = [conversation("conv-1", members: [meta("seg-1")])]

        #expect(try await worker.extract(input, transcriptOf: { transcript($0) }).isEmpty)
        #expect(provider.runCount == 1)
        #expect(try await items.list().isEmpty)

        // Passes 2 and 3 must not cost a provider call. A conversation that legitimately yields
        // nothing is the COMMON case (the old app produced 55 items over 331 annotations), so
        // "found nothing" has to be a settled answer, not a question re-asked forever.
        _ = try await worker.extract(input, transcriptOf: { transcript($0) })
        _ = try await worker.extract(input, transcriptOf: { transcript($0) })
        #expect(provider.runCount == 1)

        let record = try await state.load("conv-1")
        #expect(record?.settled == true)
        #expect(record?.itemCount == 0)
    }

    @Test func aTranscriptTooShortToBeWorthACallSettlesForFree() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)

        _ = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { transcript($0, text: "Okay.") })

        #expect(provider.runCount == 0)
        #expect(try await state.load("conv-1")?.settled == true)
    }

    @Test func reRunningProducesNoDuplicates() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        let input = [conversation("conv-1", members: [meta("seg-1")])]

        _ = try await worker.extract(input, transcriptOf: { transcript($0) })
        // Force a re-run the way a reprocess would: the combined transcript changed, so the
        // settled answer no longer applies.
        let grown = Self.longText + "One more sentence entirely."
        let written = try await worker.extract(
            input, transcriptOf: { transcript($0, text: grown) })

        #expect(provider.runCount == 2)
        // Same two tasks, same two rows — content-addressed ids, not positional ones.
        #expect(try await items.list().count == 2)
        #expect(written.isEmpty, "a re-run that finds the same items writes no NEW ones")
    }

    @Test func aUserTickedFollowUpSurvivesReExtraction() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let worker = worker(provider)
        let input = [conversation("conv-1", members: [meta("seg-1")])]

        _ = try await worker.extract(input, transcriptOf: { transcript($0) })
        let ticked = try #require(try await items.list().first)
        try await items.setDone(id: ticked.id, true)

        let grown = Self.longText + "One more sentence entirely."
        _ = try await worker.extract(input, transcriptOf: { transcript($0, text: grown) })

        #expect(try await items.load(id: ticked.id)?.done == true)
        #expect(try await items.list().filter(\.done).count == 1)
    }

    @Test func aFailingProviderIsBoundedByMaxAttempts() async throws {
        let provider = ScriptedAiProvider(
            response: Self.twoItems, error: ScriptedFailure(message: "provider exploded"))
        let worker = worker(provider)
        let input = [conversation("conv-1", members: [meta("seg-1")])]

        for _ in 0..<5 {
            _ = try await worker.extract(input, transcriptOf: { transcript($0) })
        }

        #expect(provider.runCount == FollowUpWorker.maxAttempts)
        let record = try await state.load("conv-1")
        #expect(record?.settled == false)
        #expect(record?.lastError == "provider exploded")
    }

    @Test func onlyClosedFullyTranscribedConversationsAreCandidates() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)

        _ = try await worker(provider).extract(
            [
                conversation("conv-live", members: [meta("seg-open", open: true)], open: true),
                conversation("conv-pending", members: [meta("seg-pending", state: .pending)]),
                conversation("conv-empty", members: []),
            ],
            transcriptOf: { transcript($0) })

        #expect(provider.runCount == 0)
        #expect(try await items.list().isEmpty)
    }

    /// The backfill shape: Roger's migrated library arrives as ~178 finished conversations with
    /// transcripts and no follow-ups. One pass must take a bounded bite, newest first, so a
    /// conversation that just finished is never stuck behind the backlog.
    @Test func aBacklogIsBoundedPerPassAndWorkedNewestFirst() async throws {
        let provider = ScriptedAiProvider(response: Self.twoItems)
        let backlog = (0..<20).map { index in
            conversation(
                "conv-\(index)",
                members: [meta("seg-\(index)", startTimeMs: UInt64(1_000 + index * 1_000))])
        }

        _ = try await worker(provider).extract(backlog, transcriptOf: { transcript($0) })

        #expect(provider.runCount == FollowUpWorker.maxPerPass)
        let settled = Set(
            try await state.all().filter { $0.value.settled }.keys)
        #expect(settled == ["conv-19", "conv-18", "conv-17", "conv-16", "conv-15"])
    }

    @Test func noRouterMeansNoWorkAndNoSettledState() async throws {
        _ = try await worker(nil).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { transcript($0) })

        #expect(try await items.list().isEmpty)
        #expect(try await state.load("conv-1") == nil)
    }

    /// Anti-goal B4 end to end: a text-only provider that answers in markdown must ship nothing
    /// rather than `**Owner:**` fragments, and the conversation still settles.
    @Test func markdownLadenTextOutputYieldsNoItemsRatherThanCleanedOnes() async throws {
        let provider = ScriptedAiProvider(
            response: """
                Here are the action items I found:

                - [ ] **Improve the transcript view** — **Owner:** Roger
                2. **Research timestamps** - **Owner:** Roger
                """)

        let written = try await worker(provider).extract(
            [conversation("conv-1", members: [meta("seg-1")])],
            transcriptOf: { transcript($0) })

        #expect(written.isEmpty)
        #expect(try await items.list().isEmpty)
        #expect(try await state.load("conv-1")?.settled == true)
    }
}
