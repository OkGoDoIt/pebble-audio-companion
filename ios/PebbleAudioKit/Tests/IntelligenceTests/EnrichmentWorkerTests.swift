import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// Port of `app/src/commonTest/.../SegmentEnrichmentWorkerTest.kt` — all 11 cases, same names,
// retargeted to CONVERSATION granularity (plan Part 3): each KMP single-segment case becomes a
// single-member conversation, and one extra case pins the member-combining behavior. The KMP
// file-backed store is replaced by the DB-backed AnnotationStore (AppDB `annotations` table).

private final class FakeAiProvider: AiProvider, @unchecked Sendable {
    let id = "fake"

    private let lock = NSLock()
    private var _response: String
    private var _error: Error?
    private var _runCount = 0
    private var _lastRequest: AiRunRequest?

    init(
        response: String = "TITLE: Team sync\nSUMMARY: Discussed the plan.\nTAGS: work, planning",
        error: Error? = nil
    ) {
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
    var runCount: Int { lock.withLock { _runCount } }
    var lastRequest: AiRunRequest? { lock.withLock { _lastRequest } }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let error: Error? = lock.withLock {
            _runCount += 1
            _lastRequest = request
            return _error
        }
        if let error { throw error }
        return AiProviderResult(text: response, modelUsed: "fake-model")
    }
}

private struct FakeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Suite struct EnrichmentWorkerTests {
    private let clock = TestWallClock(ms: 50_000)
    private let store: AnnotationStore

    init() throws {
        let db = try AppDatabase.inMemory()
        let clock = self.clock
        store = try AnnotationStore(db: db, nowMs: { clock.now })
    }

    private func meta(
        _ segmentId: String,
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
            startTimeMs: 1_000,
            startMonotonicMs: 1,
            receivedAtMs: 1_000,
            closeReason: open ? nil : .rotated,
            transcriptionState: state
        )
    }

    /// Single conversation per member set; live when any member is still open (the KMP
    /// per-segment cases map onto single-member conversations).
    private func conversations(
        _ members: [SegmentMeta], open: Bool? = nil
    ) -> [EnrichmentConversation] {
        [
            EnrichmentConversation(
                conversationId: "conv-\(members.first?.segmentId ?? "empty")",
                isOpen: open ?? members.contains { $0.isOpen },
                members: members
            )
        ]
    }

    private func transcript(_ segmentId: String) -> SegmentTranscript {
        SegmentTranscript(
            segmentId: segmentId,
            text: "We agreed on the plan.",
            modeUsed: .localOnly,
            providerId: "local",
            createdAtMs: 0
        )
    }

    private func worker(_ provider: FakeAiProvider?) -> EnrichmentWorker {
        let clock = self.clock
        return EnrichmentWorker(
            annotations: store,
            router: provider.map { AiModeRouter(local: $0, remote: nil, mode: { .localOnly }) },
            nowMs: { clock.now }
        )
    }

    @Test func annotatesTranscribedSegments() async throws {
        let provider = FakeAiProvider()

        let annotated = try await worker(provider)
            .enrich(conversations([meta("seg-1")]), transcriptOf: { transcript($0) })

        #expect(annotated == ["conv-seg-1"])
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation?.title == "Team sync")
        #expect(annotation?.summary == "Discussed the plan.")
        #expect(annotation?.tags == ["work", "planning"])
        #expect(annotation?.modeUsed == .localOnly)
        #expect(annotation?.providerId == "fake")
    }

    @Test func finalizedAnnotationWithoutTagsIsBackfilled() async throws {
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-1",
                title: "Old title",
                summary: "Old summary",
                tags: [],
                attempts: 1,
                isFinal: true,
                finalAttempts: 1
            ))
        let provider = FakeAiProvider(
            response: "TITLE: Team sync\nSUMMARY: Discussed the plan.\nTAGS: work, planning")

        let annotated = try await worker(provider)
            .enrich(conversations([meta("seg-1")]), transcriptOf: { transcript($0) })

        #expect(annotated == ["conv-seg-1"])
        #expect(provider.runCount == 1)
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation?.isFinal == true)
        #expect(annotation?.tags == ["work", "planning"])
        #expect(annotation?.finalAttempts == 2)
    }

    @Test func skipsOpenUntranscribedAndAlreadyAnnotatedSegments() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)

        _ = try await worker.enrich(
            conversations([meta("seg-open", open: true)])
                + conversations([meta("seg-pending", state: .pending)])
                + conversations([meta("seg-nospeech", state: .noSpeech)]),
            transcriptOf: { transcript($0) }
        )
        #expect(provider.runCount == 0)

        // Annotate once, then a second pass must not re-run the provider.
        _ = try await worker.enrich(
            conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        _ = try await worker.enrich(
            conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        #expect(provider.runCount == 1)
    }

    @Test func noRouterMeansNoAnnotationsAndNoErrors() async throws {
        let annotated = try await worker(nil)
            .enrich(conversations([meta("seg-1")]), transcriptOf: { transcript($0) })

        #expect(annotated.isEmpty)
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation == nil)
    }

    @Test func failuresAreBoundedToMaxAttempts() async throws {
        let provider = FakeAiProvider(error: FakeFailure(message: "provider down"))
        let worker = worker(provider)

        for _ in 0..<5 {
            _ = try await worker.enrich(
                conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        }

        #expect(provider.runCount == EnrichmentWorker.maxAttempts)
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation?.attempts == EnrichmentWorker.maxAttempts)
        #expect(annotation?.lastError == "provider down")
        #expect(annotation?.hasContent == false)

        // Recovery: provider works again, the next pass overwrites the failure record... but
        // only if attempts allow; bounded retries are intentional, so it stays failed.
        provider.error = nil
        _ = try await worker.enrich(
            conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        #expect(provider.runCount == EnrichmentWorker.maxAttempts)
    }

    private var longLive: String { String(repeating: "a ", count: EnrichmentWorker.liveMinChars) }

    @Test func livePassAnnotatesOpenSegmentFromPreview() async throws {
        let provider = FakeAiProvider()

        let annotated = try await worker(provider).enrich(
            conversations([meta("seg-open", open: true)]),
            transcriptOf: { _ in nil },
            liveTextOf: { _ in longLive }
        )

        #expect(annotated == ["conv-seg-open"])
        let annotation = try await store.load("conv-seg-open")
        #expect(annotation?.title == "Team sync")
        #expect(annotation?.isFinal == false)
        let trimmedCount = longLive.trimmingCharacters(in: .whitespacesAndNewlines).count
        #expect(annotation?.sourceCharCount == trimmedCount)
    }

    @Test func livePassSkipsTooShortPreviewAndMissingPreview() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)

        _ = try await worker.enrich(
            conversations([meta("seg-open", open: true)]),
            transcriptOf: { _ in nil },
            liveTextOf: { _ in "too short" }
        )
        _ = try await worker.enrich(
            conversations([meta("seg-open", open: true)]),
            transcriptOf: { _ in nil },
            liveTextOf: { _ in nil }
        )

        #expect(provider.runCount == 0)
        let annotation = try await store.load("conv-seg-open")
        #expect(annotation == nil)
    }

    @Test func liveRefreshNeedsGrowthAndInterval() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)
        let open = conversations([meta("seg-open", open: true)])
        func text(_ n: Int) -> String { String(repeating: "x", count: n) }
        let base = EnrichmentWorker.liveMinChars + 10
        let grown = base + EnrichmentWorker.liveRefreshMinGrowthChars + 10

        // First provisional.
        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in text(base) })
        #expect(provider.runCount == 1)

        // Grown enough but the refresh interval has not elapsed yet: no new call.
        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in text(grown) })
        #expect(provider.runCount == 1)

        // Interval elapsed but barely grown: still no new call.
        clock.advance(byMs: EnrichmentWorker.liveRefreshMinIntervalMs + 1_000)
        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in text(base + 5) })
        #expect(provider.runCount == 1)

        // Interval elapsed and grown enough: refresh.
        clock.advance(byMs: EnrichmentWorker.liveRefreshMinIntervalMs + 1_000)
        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in text(grown) })
        #expect(provider.runCount == 2)
    }

    @Test func finalPassOverridesProvisionalThenStops() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)

        // Provisional from the live preview while recording.
        _ = try await worker.enrich(
            conversations([meta("seg-1", open: true)]),
            transcriptOf: { _ in nil },
            liveTextOf: { _ in longLive }
        )
        let provisional = try await store.load("conv-seg-1")
        #expect(provisional?.isFinal == false)
        #expect(provider.runCount == 1)

        // Conversation closes and finishes transcribing: authoritative final pass overrides.
        provider.response =
            "TITLE: Final title\nSUMMARY: The authoritative summary.\nTAGS: work, plan"
        _ = try await worker.enrich(
            conversations([meta("seg-1", state: .complete)]),
            transcriptOf: { transcript($0) }
        )
        let finalAnnotation = try await store.load("conv-seg-1")
        #expect(finalAnnotation?.isFinal == true)
        #expect(finalAnnotation?.title == "Final title")
        #expect(finalAnnotation?.summary == "The authoritative summary.")
        #expect(finalAnnotation?.tags == ["work", "plan"])
        #expect(provider.runCount == 2)

        // The final pass runs exactly once.
        _ = try await worker.enrich(
            conversations([meta("seg-1", state: .complete)]),
            transcriptOf: { transcript($0) }
        )
        #expect(provider.runCount == 2)
    }

    @Test func liveRefreshErrorPreservesProvisionalContent() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)
        let open = conversations([meta("seg-1", open: true)])

        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in longLive })
        let provisional = try await store.load("conv-seg-1")
        #expect(provisional?.title == "Team sync")

        provider.error = FakeFailure(message: "boom")
        clock.advance(byMs: EnrichmentWorker.liveRefreshMinIntervalMs + 1_000)
        let grown = String(
            repeating: "y ",
            count: EnrichmentWorker.liveMinChars + EnrichmentWorker.liveRefreshMinGrowthChars)
        _ = try await worker.enrich(
            open, transcriptOf: { _ in nil }, liveTextOf: { _ in grown })

        let after = try await store.load("conv-seg-1")
        #expect(after?.title == "Team sync", "transient live error must not blank the row")
        #expect(after?.lastError == "boom")
        #expect(after?.isFinal == false)
        #expect(provider.runCount == 2)
    }

    @Test func closedButNotCompleteKeepsProvisionalAndDefersFinal() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)

        _ = try await worker.enrich(
            conversations([meta("seg-1", open: true)]),
            transcriptOf: { _ in nil },
            liveTextOf: { _ in longLive }
        )
        #expect(provider.runCount == 1)

        // Closed but still transcribing (Running/Uploading/Pending): no final yet, keep
        // provisional.
        _ = try await worker.enrich(
            conversations([meta("seg-1", state: .running)]), transcriptOf: { transcript($0) })
        _ = try await worker.enrich(
            conversations([meta("seg-1", state: .uploading)]), transcriptOf: { transcript($0) })
        #expect(provider.runCount == 1)
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation?.title == "Team sync")
        #expect(annotation?.isFinal == false)
    }

    // NEW (not in the KMP suite): pins the conversation retarget — one annotation per
    // conversation, built from ALL member transcripts.
    @Test func finalPassCombinesMemberTranscriptsIntoOneAnnotation() async throws {
        let provider = FakeAiProvider()
        let members = [meta("seg-a"), meta("seg-b")]
        let convo = [
            EnrichmentConversation(conversationId: "conv-ab", isOpen: false, members: members)
        ]

        let annotated = try await worker(provider).enrich(
            convo,
            transcriptOf: { id in
                SegmentTranscript(
                    segmentId: id, text: "Part from \(id).", modeUsed: .localOnly,
                    providerId: "local", createdAtMs: 0)
            }
        )

        #expect(annotated == ["conv-ab"])
        let request = try #require(provider.lastRequest)
        #expect(request.transcripts.map { $0.segmentId } == ["seg-a", "seg-b"])
        #expect(request.transcripts.map { $0.text } == ["Part from seg-a.", "Part from seg-b."])
        let annotation = try await store.load("conv-ab")
        #expect(annotation?.isFinal == true)
        #expect(annotation?.title == "Team sync")
    }
}
