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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

@Suite struct EnrichmentWorkerTests {
    private let clock = TestWallClock(ms: 50_000)
    private let store: AnnotationStore
    private let tags: TagStore

    init() throws {
        let db = try AppDatabase.inMemory()
        let clock = self.clock
        store = try AnnotationStore(db: db, nowMs: { clock.now })
        tags = TagStore(db: db)
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

    // Every pass used to read and JSON-decode the transcripts of every finished conversation in
    // the library before noticing it was already annotated — a quarter of a CPU core,
    // continuously, on 2026-09-09. The decision has to come from the annotation record alone.
    @Test func finishedAnnotatedConversationsDoNotOpenTheirTranscripts() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)
        let convs = conversations([meta("seg-1")])
        _ = try await worker.enrich(convs, transcriptOf: { transcript($0) })
        #expect(provider.runCount == 1)

        let loads = Counter()
        _ = try await worker.enrich(
            convs,
            transcriptOf: {
                loads.increment()
                return transcript($0)
            })
        #expect(provider.runCount == 1)
        #expect(loads.value == 0, "an annotated final conversation is decided without I/O")
    }

    // A finished conversation with nothing transcribable is decided by decoding its transcripts;
    // with a transcript version to key on, that answer is remembered until a member changes.
    @Test func emptyFinalConversationsAreRememberedByTranscriptVersion() async throws {
        let provider = FakeAiProvider()
        let clock = self.clock
        let worker = EnrichmentWorker(
            annotations: store,
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { clock.now },
            transcriptVersionOf: { _ in "v1" }
        )
        let convs = conversations([meta("seg-1")])
        let empty = SegmentTranscript(
            segmentId: "seg-1", text: "   ", modeUsed: .localOnly, providerId: "local",
            createdAtMs: 0)
        let loads = Counter()
        let transcriptOf: (String) -> SegmentTranscript? = { _ in
            loads.increment()
            return empty
        }
        _ = try await worker.enrich(convs, transcriptOf: transcriptOf)
        #expect(loads.value == 1)
        _ = try await worker.enrich(convs, transcriptOf: transcriptOf)
        #expect(loads.value == 1, "same members, same version: the empty verdict is reused")
        #expect(provider.runCount == 0)

        // Without a version nothing is assumed, and the transcript is read again.
        let unversioned = self.worker(provider)
        _ = try await unversioned.enrich(convs, transcriptOf: transcriptOf)
        _ = try await unversioned.enrich(convs, transcriptOf: transcriptOf)
        #expect(loads.value == 3)
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
        // The generated tags have to REACH the Library: its chip row, its tag filter and the
        // Search "Tags" section all read `conversation_tags`, and for as long as the pass wrote
        // only `annotations.tagsJson` every library was untagged and the chip row never
        // appeared.
        #expect(
            try await tags.tags(forConversation: "conv-seg-1").map(\.name) == ["planning", "work"])
        #expect(try await tags.listTags().map(\.name).sorted() == ["planning", "work"])
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

    /// A failure nobody can name spends an attempt (`AiFailureKind.blamesTheInput`), attempts
    /// are spaced by `AiRetryPolicy.contentRetryMs` rather than spent in three back-to-back
    /// passes, and a spent budget RESTS instead of being abandoned for the life of the database.
    @Test func failuresAreBoundedToMaxAttempts() async throws {
        let provider = FakeAiProvider(error: FakeFailure(message: "provider down"))
        let worker = worker(provider)

        for _ in 0..<5 {
            _ = try await worker.enrich(
                conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
            clock.advance(byMs: AiRetryPolicy.contentRetryMs)
        }

        #expect(provider.runCount == EnrichmentWorker.maxAttempts)
        let annotation = try await store.load("conv-seg-1")
        #expect(annotation?.attempts == EnrichmentWorker.maxAttempts)
        #expect(annotation?.lastError == "provider down")
        #expect(annotation?.hasContent == false)

        // The provider works again. The spent budget still rests for its six hours…
        provider.error = nil
        _ = try await worker.enrich(
            conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        #expect(provider.runCount == EnrichmentWorker.maxAttempts)

        // …and is then tried again, and titled. It used to stay untitled forever.
        clock.advance(byMs: AiRetryPolicy.exhaustedRetryMs)
        _ = try await worker.enrich(
            conversations([meta("seg-1")]), transcriptOf: { transcript($0) })
        #expect(provider.runCount == EnrichmentWorker.maxAttempts + 1)
        #expect(try await store.load("conv-seg-1")?.isFinal == true)
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

    /// Inside the 45-second refresh interval a live conversation is decided by the clock alone.
    /// It used to decode every closed member's transcript on every pass — every five seconds
    /// while the watch records — before finding the gate closed.
    @Test func aLiveConversationInsideItsRefreshIntervalOpensNoTranscript() async throws {
        let provider = FakeAiProvider()
        let worker = worker(provider)
        let open = conversations([meta("seg-closed"), meta("seg-open", open: true)], open: true)
        _ = try await worker.enrich(
            open, transcriptOf: { transcript($0) }, liveTextOf: { _ in longLive })
        #expect(provider.runCount == 1)

        let reads = Counter()
        for _ in 0..<5 {
            clock.advance(byMs: 5_000)
            _ = try await worker.enrich(
                open,
                transcriptOf: {
                    reads.increment()
                    return transcript($0)
                },
                liveTextOf: { _ in
                    reads.increment()
                    return longLive
                })
        }
        #expect(reads.value == 0)
        #expect(provider.runCount == 1)
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

    // MARK: - Backlog pacing

    /// Regression: this loop used to run the ENTIRE backlog in one invocation. With 145
    /// unenriched conversations the pipeline pass did not return for many minutes, so the
    /// grouping stage never ran again — Library, Today's list, the live row and the
    /// Recording-now screen all froze at the moment the backfill began, while recording
    /// continued. The backlog still drains; it just yields the pass between mouthfuls.
    @Test func aLargeBacklogIsBoundedToAFewProviderCallsPerPass() async throws {
        let provider = FakeAiProvider()
        let backlog = (0..<50).map { index in
            EnrichmentConversation(
                conversationId: "conv-\(index)", isOpen: false,
                members: [meta("seg-\(index)")])
        }

        let annotated = try await worker(provider).enrich(
            backlog, transcriptOf: { transcript($0) })

        #expect(provider.runCount == EnrichmentWorker.maxPerPass)
        #expect(annotated.count == EnrichmentWorker.maxPerPass)
    }

    /// A migrated user waited for 145 months-old conversations before today's got a title.
    /// Newest first, so the conversation that just happened is annotated in the first pass.
    @Test func theNewestConversationIsAnnotatedBeforeAnOlderBacklog() async throws {
        let provider = FakeAiProvider()
        let old = (0..<10).map { index in
            EnrichmentConversation(
                conversationId: "conv-old-\(index)", isOpen: false,
                members: [metaAt("seg-old-\(index)", startTimeMs: UInt64(1_000 + index))])
        }
        let newest = EnrichmentConversation(
            conversationId: "conv-today", isOpen: false,
            members: [metaAt("seg-today", startTimeMs: 9_000_000)])

        let annotated = try await worker(provider).enrich(
            old + [newest], transcriptOf: { transcript($0) })

        #expect(annotated.first == "conv-today")
    }

    /// A budget counted on conversations EXAMINED rather than provider calls would be eaten by
    /// an already-annotated library before ever reaching the one that needs work.
    @Test func alreadyAnnotatedConversationsDoNotConsumeTheBudget() async throws {
        let provider = FakeAiProvider()
        for index in 0..<20 {
            try await store.save(
                ConversationAnnotation(
                    conversationId: "conv-done-\(index)", title: "Done", summary: "Done",
                    tags: ["work"], isFinal: true, finalAttempts: 1))
        }
        let settled = (0..<20).map { index in
            EnrichmentConversation(
                conversationId: "conv-done-\(index)", isOpen: false,
                members: [metaAt("seg-done-\(index)", startTimeMs: UInt64(9_000_000 + index))])
        }
        let pending = EnrichmentConversation(
            conversationId: "conv-pending", isOpen: false,
            members: [metaAt("seg-pending-1", startTimeMs: 1_000)])

        let annotated = try await worker(provider).enrich(
            settled + [pending], transcriptOf: { transcript($0) })

        #expect(annotated == ["conv-pending"])
        #expect(provider.runCount == 1)
    }

    /// `receivedAtMs` moves with the start, because it has to: `SegmentMeta.startWallMs` —
    /// which is what "newest" is now measured on — is clamped by it, on the ground that audio
    /// cannot have been recorded after the phone received it. Leaving the base fixture's
    /// `receivedAtMs: 1_000` here described a recording that arrived in 1970 and started two
    /// and a half hours later, and every segment then collapsed onto the same anchor.
    private func metaAt(_ segmentId: String, startTimeMs: UInt64) -> SegmentMeta {
        var value = meta(segmentId)
        value.startTimeMs = startTimeMs
        value.receivedAtMs = Int64(startTimeMs) + 1_200
        return value
    }
}
