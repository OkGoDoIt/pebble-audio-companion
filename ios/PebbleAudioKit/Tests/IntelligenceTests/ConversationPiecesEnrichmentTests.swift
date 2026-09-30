import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription
import WireProtocol

@testable import Intelligence

// A conversation is a list of PIECES — a range of each of its segments — and its id stays with
// its first part when it is cut (`ConversationUnits.swift`). Two things follow for titles and
// summaries, and these tests pin both:
//
//  - what the model reads is the piece, never the whole segment: two conversations that share
//    a segment must not see each other's turns;
//  - an annotation belongs to the pieces it was written from (`ConversationSourceKey`). On the
//    first run after conversations became topic-sized every id in the library names a smaller
//    conversation than it did, and "a final annotation is never regenerated" would have left
//    ten minutes of talk wearing the title of the ten hours they were cut from.

/// Records every request, so a test can read what each conversation was shown.
private final class RecordingProvider: AiProvider, @unchecked Sendable {
    let id = "recording"
    private let lock = NSLock()
    private var _requests: [AiRunRequest] = []
    private var _error: Error?
    private var _response: String

    init(response: String = "TITLE: Team sync\nSUMMARY: Discussed the plan.\nTAGS: work") {
        _response = response
    }

    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var runCount: Int { lock.withLock { _requests.count } }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var response: String {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let (error, response): (Error?, String) = lock.withLock {
            _requests.append(request)
            return (_error, _response)
        }
        if let error { throw error }
        return AiProviderResult(text: response, modelUsed: "recording-model")
    }

    /// The words one conversation's request carried.
    func text(for conversationId: String) -> String {
        requests.filter { $0.requestId.contains("-\(conversationId)-final")
            || $0.requestId.contains("-\(conversationId)-live") }
            .flatMap { $0.transcripts.map(\.text) }.joined(separator: "\n")
    }
}

private struct Broken: LocalizedError {
    var errorDescription: String? { "the model returned nothing usable" }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// When the recordings below start.
private let recordedAtMs: Int64 = 1_788_193_700_000

/// A closed, transcribed segment holding `heldSeconds` of audio. `gaps` are wall time with no
/// stored audio; the sample extents grow by them, which is what makes the two clocks differ.
private func segment(
    _ id: String, startMs: Int64 = recordedAtMs, heldSeconds: Int64 = 900,
    gapSeconds: Int64 = 0, gapAfterSeconds: Int64 = 0, open: Bool = false,
    state: TranscriptionState = .complete
) -> SegmentMeta {
    var gaps: [GapMeta] = []
    if gapSeconds > 0 {
        gaps.append(
            GapMeta(
                firstMissingSequence: UInt32(gapAfterSeconds * 50),
                missingFrameCount: UInt32(gapSeconds * 50),
                firstMissingSampleIndex: UInt64(gapAfterSeconds * 16_000),
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.silenceSuppressed.rawValue)))
    }
    return SegmentMeta(
        segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
        frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
        startTimeMs: UInt64(startMs), startMonotonicMs: 1, receivedAtMs: startMs,
        firstSampleIndex: 0,
        lastSampleIndexExclusive: UInt64((heldSeconds + gapSeconds) * 16_000),
        frameCount: heldSeconds * 50, gaps: gaps, closeReason: open ? nil : .rotated,
        transcriptionState: state)
}

private func turn(_ text: String, at seconds: Int64, speaker: String = "1") -> TranscriptSegment {
    TranscriptSegment(
        text: text, startMs: seconds * 1_000, endMs: seconds * 1_000 + 4_000, speaker: speaker)
}

/// One segment, two subjects: the fence for its first ten minutes, the match after that.
private let fenceAndMatch: [TranscriptSegment] = [
    turn("We should repaint the fence this weekend.", at: 10),
    turn("I will buy the primer tomorrow.", at: 20),
    turn("Did you see the match last night?", at: 605),
    turn("The keeper saved two penalties.", at: 615),
]

private func transcript(_ id: String, _ turns: [TranscriptSegment]) -> SegmentTranscript {
    SegmentTranscript(
        segmentId: id, text: turns.map(\.text).joined(separator: " "), modeUsed: .localOnly,
        providerId: "local", createdAtMs: 0, segments: turns)
}

private func piece(_ id: String, from: Int64? = nil, to: Int64? = nil) -> ConversationMember {
    ConversationMember(segmentId: id, startMediaMs: from, endMediaMs: to)
}

private func key(_ pieces: ConversationMember...) -> String {
    ConversationSourceKey.key(of: pieces)
}

/// The two conversations that share `seg-a`: cut at ten minutes.
private let fence = EnrichmentConversation(
    conversationId: "conv-seg-a", isOpen: false, members: [segment("seg-a")],
    pieces: [piece("seg-a", to: 600_000)])
private let match = EnrichmentConversation(
    conversationId: "conv-seg-a-m600000", isOpen: false, members: [segment("seg-a")],
    pieces: [piece("seg-a", from: 600_000)])

@Suite("titles and summaries read a conversation's pieces, and belong to them")
struct ConversationPiecesEnrichmentTests {
    private let clock = TestWallClock(ms: recordedAtMs + 3_600_000)
    private let store: AnnotationStore
    private let tags: TagStore

    init() throws {
        let db = try AppDatabase.inMemory()
        let clock = self.clock
        store = try AnnotationStore(db: db, nowMs: { clock.now })
        tags = TagStore(db: db)
    }

    private func worker(
        _ provider: RecordingProvider,
        transcriptVersionOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> EnrichmentWorker {
        let clock = self.clock
        return EnrichmentWorker(
            annotations: store,
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { clock.now }, transcriptVersionOf: transcriptVersionOf)
    }

    private let read: @Sendable (String) -> SegmentTranscript? = {
        transcript($0, fenceAndMatch)
    }

    // MARK: What the model reads

    @Test("two conversations sharing a segment are each titled from their own turns only")
    func sharedSegmentIsNotSharedText() async throws {
        let provider = RecordingProvider()
        let annotated = try await worker(provider).enrich([fence, match], transcriptOf: read)

        #expect(Set(annotated) == ["conv-seg-a", "conv-seg-a-m600000"])
        #expect(provider.runCount == 2)
        let fenceText = provider.text(for: "conv-seg-a")
        #expect(fenceText.contains("repaint the fence") && fenceText.contains("primer"))
        #expect(!fenceText.contains("match") && !fenceText.contains("penalties"))
        let matchText = provider.text(for: "conv-seg-a-m600000")
        #expect(matchText.contains("the match") && matchText.contains("penalties"))
        #expect(!matchText.contains("fence") && !matchText.contains("primer"))
    }

    @Test("an excerpt is dated from the piece's first turn, through the segment's gap records")
    func excerptStartsWhereThePieceDoes() async throws {
        // No gaps: media offset and wall offset are the same thing.
        let provider = RecordingProvider()
        _ = try await worker(provider).enrich([match], transcriptOf: read)
        let excerpt = try #require(provider.requests.first?.transcripts.first)
        #expect(excerpt.startTimeMs == recordedAtMs + 605_000)
        #expect(excerpt.timeLabel != nil)

        // A minute of skipped silence before the cut: the same turn is a minute later on the
        // wall clock than its offset into the stored audio says.
        let gapped = segment("seg-g", gapSeconds: 60, gapAfterSeconds: 100)
        let conversation = EnrichmentConversation(
            conversationId: "conv-seg-g-m600000", isOpen: false, members: [gapped],
            pieces: [piece("seg-g", from: 600_000)])
        let second = RecordingProvider()
        _ = try await worker(second).enrich([conversation], transcriptOf: read)
        #expect(
            second.requests.first?.transcripts.first?.startTimeMs == recordedAtMs + 665_000)

        // No timings to take a first turn from: the piece's own start, and for a piece that
        // starts with its segment, the segment's.
        #expect(
            EnrichmentConversation.startWallMs(
                of: piece("seg-g", from: 600_000), in: gapped, firstTurnMediaMs: nil)
                == recordedAtMs + 660_000)
        #expect(
            EnrichmentConversation.startWallMs(
                of: piece("seg-g"), in: gapped, firstTurnMediaMs: nil) == recordedAtMs)
    }

    @Test("pieces are parallel to members, and a member with no piece is owned whole")
    func piecesStayParallel() {
        let members = [segment("seg-a"), segment("seg-b")]
        let whole = EnrichmentConversation(conversationId: "c", isOpen: false, members: members)
        #expect(whole.pieces == [piece("seg-a"), piece("seg-b")])
        // A piece list that does not line up with the members cannot mis-assign a range.
        let ragged = EnrichmentConversation(
            conversationId: "c", isOpen: false, members: members,
            pieces: [piece("seg-b", from: 5_000)])
        #expect(ragged.pieces == [piece("seg-a"), piece("seg-b")])
        let cut = EnrichmentConversation(
            conversationId: "c", isOpen: false, members: members,
            pieces: [piece("seg-a", from: 600_000), piece("seg-b", to: 30_000)])
        #expect(cut.sourceKey == "seg-a@600000-;seg-b@0-30000")
        #expect(cut.sourceKey != whole.sourceKey)
    }

    // MARK: Stale finals

    @Test("a final annotation written from other pieces is written again, once")
    func staleFinalIsRegenerated() async throws {
        // The id used to name the whole segment (and the one before it).
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, finalAttempts: 1,
                sourceKey: key(piece("seg-a"))))
        let provider = RecordingProvider(
            response: "TITLE: Repainting the fence\nSUMMARY: Primer first.\nTAGS: fence")
        let worker = worker(provider)

        #expect(try await worker.enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        let annotation = try #require(try await store.load("conv-seg-a"))
        #expect(annotation.title == "Repainting the fence")
        #expect(annotation.tags == ["fence"])
        #expect(annotation.isFinal)
        #expect(annotation.sourceKey == fence.sourceKey)
        // The tags the old title brought with it go with it.
        #expect(try await tags.tags(forConversation: "conv-seg-a").map(\.name) == ["fence"])

        // Now it describes the conversation: nothing more to do.
        #expect(try await worker.enrich([fence], transcriptOf: read).isEmpty)
        #expect(provider.runCount == 1)
    }

    @Test("a final annotation from before the key was recorded counts as written from elsewhere")
    func legacyFinalIsRegenerated() async throws {
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, finalAttempts: 1))
        let provider = RecordingProvider()
        #expect(try await worker(provider).enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        #expect(try await store.load("conv-seg-a")?.sourceKey == fence.sourceKey)
    }

    @Test("what is left after retention took a conversation's first segments is not re-titled")
    func aFrontTrimmedConversationKeepsItsTitle() async throws {
        // Written when the conversation began in the segment before this one. That segment has
        // since been deleted; what remains is exactly the tail it was written from.
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "Repainting the fence", summary: "Primer.",
                tags: ["fence"], isFinal: true, finalAttempts: 1,
                sourceKey: key(piece("seg-0", from: 400_000), piece("seg-a", to: 600_000))))
        let provider = RecordingProvider()
        #expect(try await worker(provider).enrich([fence], transcriptOf: read).isEmpty)
        #expect(provider.runCount == 0)

        // Losing a TRAILING piece is a different conversation, and is.
        #expect(
            !ConversationSourceKey.describes(
                stored: key(piece("seg-a", to: 600_000), piece("seg-b")),
                current: key(piece("seg-a", to: 600_000))))
        #expect(!ConversationSourceKey.describes(stored: nil, current: fence.sourceKey))
        #expect(!ConversationSourceKey.describes(stored: "", current: fence.sourceKey))
    }

    @Test("a stale title over pieces with nothing said in them is taken back, not kept")
    func staleAnnotationOverSilenceIsWithdrawn() async throws {
        // seg-a from 5 to 9:50 holds no turn at all.
        let quiet = EnrichmentConversation(
            conversationId: "conv-seg-a-m300000", isOpen: false, members: [segment("seg-a")],
            pieces: [piece("seg-a", from: 300_000, to: 590_000)])
        try await store.save(
            ConversationAnnotation(
                conversationId: quiet.conversationId, title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, finalAttempts: 1, sourceKey: key(piece("seg-a"))))
        try await tags.addTag(
            conversationId: quiet.conversationId, name: "mine", source: TagSource.user)
        let provider = RecordingProvider()
        let worker = worker(provider)

        #expect(try await worker.enrich([quiet], transcriptOf: read) == [quiet.conversationId])
        #expect(provider.runCount == 0)
        #expect(try await store.load(quiet.conversationId) == nil)
        // The model's tag goes with its title; the person's stays.
        #expect(try await tags.tags(forConversation: quiet.conversationId).map(\.name) == ["mine"])
        #expect(try await worker.enrich([quiet], transcriptOf: read).isEmpty)
    }

    @Test("a live conversation that inherited a final title has it refreshed")
    func aStaleFinalOnALiveConversationIsNotFrozen() async throws {
        let open = segment("seg-open", startMs: recordedAtMs + 900_000, open: true, state: .pending)
        let live = EnrichmentConversation(
            conversationId: "conv-seg-a", isOpen: true, members: [segment("seg-a"), open])
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "Repainting the fence", summary: "Primer.",
                tags: ["fence"], isFinal: true, sourceKey: key(piece("seg-a"))))
        clock.advance(byMs: EnrichmentWorker.liveRefreshMinIntervalMs)
        let provider = RecordingProvider()
        let worker = worker(provider)
        let liveText: @Sendable (String) -> String? = { _ in
            String(repeating: "and now we are talking about the holiday. ", count: 4)
        }

        #expect(
            try await worker.enrich([live], transcriptOf: read, liveTextOf: liveText)
                == ["conv-seg-a"])
        let annotation = try #require(try await store.load("conv-seg-a"))
        #expect(!annotation.isFinal)
        #expect(annotation.sourceKey == live.sourceKey)

        // One written from the pieces it has is still never downgraded.
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "Final", summary: "Final.", tags: ["x"],
                isFinal: true, sourceKey: live.sourceKey))
        clock.advance(byMs: EnrichmentWorker.liveRefreshMinIntervalMs)
        #expect(try await worker.enrich([live], transcriptOf: read, liveTextOf: liveText).isEmpty)
    }

    // MARK: Budgets

    @Test("a budget spent on other pieces is not this conversation's")
    func theBudgetBelongsToTheSource() async throws {
        // Three failed final passes — about the conversation the id used to name.
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", lastError: "nope",
                finalAttempts: EnrichmentWorker.maxAttempts, sourceKey: key(piece("seg-a"))))
        let provider = RecordingProvider()
        #expect(try await worker(provider).enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        let annotation = try #require(try await store.load("conv-seg-a"))
        #expect(annotation.isFinal && annotation.finalAttempts == 1)

        // The same record about the SAME pieces rests, as it always did.
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a-m600000", lastError: "nope",
                finalAttempts: EnrichmentWorker.maxAttempts, sourceKey: match.sourceKey))
        #expect(try await worker(provider).enrich([match], transcriptOf: read).isEmpty)
        #expect(provider.runCount == 1)
    }

    @Test("a failed re-title keeps the old words on screen, unfinished, under the new key")
    func aFailedRetitleIsNotFinal() async throws {
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, finalAttempts: 1, sourceKey: key(piece("seg-a"))))
        let provider = RecordingProvider()
        provider.error = Broken()
        let worker = worker(provider)

        #expect(try await worker.enrich([fence], transcriptOf: read).isEmpty)
        let failed = try #require(try await store.load("conv-seg-a"))
        #expect(failed.title == "A long day")
        #expect(!failed.isFinal)
        #expect(failed.sourceKey == fence.sourceKey)
        #expect(failed.nextAttemptAtMs != nil)

        // It waits out its backoff like any other unfinished conversation, then is done.
        provider.error = nil
        #expect(try await worker.enrich([fence], transcriptOf: read).isEmpty)
        clock.advance(byMs: AiRetryPolicy.maxRetryMs)
        #expect(try await worker.enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        #expect(try await store.load("conv-seg-a")?.isFinal == true)
    }

    // MARK: The person's own title

    @Test("a title the person typed survives regeneration; the summary and tags do not")
    func aTypedTitleIsKept() async throws {
        try await store.save(
            ConversationAnnotation(
                conversationId: "conv-seg-a", title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, finalAttempts: 1, sourceKey: key(piece("seg-a"))))
        let renamed = try await store.setUserTitle("Saturday jobs", conversationId: "conv-seg-a")
        #expect(renamed.title == "Saturday jobs" && renamed.titleEditedAtMs != nil)
        // A rename changes the title and its mark and nothing else.
        #expect(renamed.summary == "Everything." && renamed.isFinal && renamed.tags == ["day"])

        let provider = RecordingProvider(
            response: "TITLE: Repainting the fence\nSUMMARY: Primer first.\nTAGS: fence")
        #expect(try await worker(provider).enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        let annotation = try #require(try await store.load("conv-seg-a"))
        #expect(annotation.title == "Saturday jobs")
        #expect(annotation.titleEditedAtMs == renamed.titleEditedAtMs)
        #expect(annotation.summary == "Primer first." && annotation.tags == ["fence"])
        #expect(annotation.isFinal && annotation.sourceKey == fence.sourceKey)
    }

    @Test("naming a conversation that has no annotation yet gives it one, and the pass fills it in")
    func aTypedTitleCanComeFirst() async throws {
        let renamed = try await store.setUserTitle("Saturday jobs", conversationId: "conv-seg-a")
        #expect(renamed.summary == nil && !renamed.isFinal)
        let provider = RecordingProvider(
            response: "TITLE: Repainting the fence\nSUMMARY: Primer first.\nTAGS: fence")
        #expect(try await worker(provider).enrich([fence], transcriptOf: read) == ["conv-seg-a"])
        let annotation = try #require(try await store.load("conv-seg-a"))
        #expect(annotation.title == "Saturday jobs" && annotation.summary == "Primer first.")
    }

    @Test("a save that does not know about a typed title cannot overwrite it")
    func anUnmarkedSaveKeepsAMarkedTitle() async throws {
        // The worker reads, waits on the provider, saves. A rename in between must win.
        let before = try await store.save(
            ConversationAnnotation(conversationId: "conv-seg-a", title: "Provisional"))
        try await store.setUserTitle("Saturday jobs", conversationId: "conv-seg-a")
        var late = before
        late.title = "Repainting the fence"
        late.summary = "Primer first."
        try await store.save(late)

        let stored = try #require(try await store.load("conv-seg-a"))
        #expect(stored.title == "Saturday jobs" && stored.titleEditedAtMs != nil)
        #expect(stored.summary == "Primer first.")
        // The person can still rename it again.
        try await store.setUserTitle("Fence", conversationId: "conv-seg-a")
        #expect(try await store.load("conv-seg-a")?.title == "Fence")
    }

    @Test("a typed title over pieces with nothing said in them stays, alone")
    func aTypedTitleSurvivesAWithdrawal() async throws {
        let quiet = EnrichmentConversation(
            conversationId: "conv-seg-a-m300000", isOpen: false, members: [segment("seg-a")],
            pieces: [piece("seg-a", from: 300_000, to: 590_000)])
        try await store.save(
            ConversationAnnotation(
                conversationId: quiet.conversationId, title: "A long day", summary: "Everything.",
                tags: ["day"], isFinal: true, sourceKey: key(piece("seg-a"))))
        try await store.setUserTitle("The quiet bit", conversationId: quiet.conversationId)
        let worker = worker(RecordingProvider())

        #expect(try await worker.enrich([quiet], transcriptOf: read) == [quiet.conversationId])
        let annotation = try #require(try await store.load(quiet.conversationId))
        #expect(annotation.title == "The quiet bit" && annotation.titleEditedAtMs != nil)
        #expect(annotation.summary == nil && annotation.tags.isEmpty)
        #expect(try await tags.tags(forConversation: quiet.conversationId).isEmpty)
        #expect(try await worker.enrich([quiet], transcriptOf: read).isEmpty)
    }

    // MARK: Memo keys

    @Test("a cut that moves is seen even though no segment and no transcript file changed")
    func aRangeOnlyChangeIsSeen() async throws {
        let provider = RecordingProvider()
        let loads = LoadCounter()
        let worker = worker(provider, transcriptVersionOf: { _ in "v1" })
        let counted: (String) -> SegmentTranscript? = {
            loads.increment()
            return transcript($0, fenceAndMatch)
        }
        func conversation(to end: Int64) -> EnrichmentConversation {
            EnrichmentConversation(
                conversationId: "conv-seg-a-m300000", isOpen: false, members: [segment("seg-a")],
                pieces: [piece("seg-a", from: 300_000, to: end)])
        }

        // Nothing said before 9:50: learned once, remembered against the pieces' key.
        #expect(try await worker.enrich([conversation(to: 590_000)], transcriptOf: counted).isEmpty)
        let learned = loads.value
        #expect(learned >= 1)
        #expect(try await worker.enrich([conversation(to: 590_000)], transcriptOf: counted).isEmpty)
        #expect(loads.value == learned)

        // The cut moves past the first words of the match. Same segment, same file.
        #expect(
            try await worker.enrich([conversation(to: 700_000)], transcriptOf: counted)
                == ["conv-seg-a-m300000"])
        #expect(provider.text(for: "conv-seg-a-m300000").contains("the match"))
        #expect(
            EnrichmentWorker.membershipKey(conversation(to: 590_000)) { _ in "v1" }
                != EnrichmentWorker.membershipKey(conversation(to: 700_000)) { _ in "v1" })
    }

    // MARK: Pacing

    @Test("a re-cut library is re-titled newest first, a few conversations a pass")
    func aRecutLibraryDoesNotStampede() async throws {
        // Twelve conversations, every one carrying a final title from before the re-cut.
        var library: [EnrichmentConversation] = []
        for index in 0..<12 {
            let id = "seg-\(String(format: "%02d", index))"
            library.append(
                EnrichmentConversation(
                    conversationId: "conv-\(id)", isOpen: false,
                    members: [segment(id, startMs: recordedAtMs + Int64(index) * 900_000)],
                    pieces: [piece(id, to: 600_000)]))
            try await store.save(
                ConversationAnnotation(
                    conversationId: "conv-\(id)", title: "Old", summary: "Old.", tags: ["old"],
                    isFinal: true, finalAttempts: 1))
        }
        let provider = RecordingProvider()
        let worker = worker(provider)

        let first = try await worker.enrich(library.shuffled(), transcriptOf: read)
        #expect(first == ["conv-seg-11", "conv-seg-10", "conv-seg-09"])
        #expect(provider.runCount == EnrichmentWorker.maxPerPass)
        let second = try await worker.enrich(library.shuffled(), transcriptOf: read)
        #expect(second == ["conv-seg-08", "conv-seg-07", "conv-seg-06"])

        var passes = 2
        while try await !worker.enrich(library, transcriptOf: read).isEmpty { passes += 1 }
        #expect(passes == 4)
        #expect(provider.runCount == 12)
        #expect(try await store.list().allSatisfy { $0.title == "Team sync" && $0.isFinal })
    }
}
