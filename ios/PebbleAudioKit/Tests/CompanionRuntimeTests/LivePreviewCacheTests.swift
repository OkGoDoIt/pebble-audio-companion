import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import LiveAudio
import SegmentStore
import Testing
import Transcription

// The bridge between the live transcribers (actors) and `EnrichmentService.liveTextOf` (a
// synchronous seam). Before it existed the seam was never supplied, so a LIVE conversation's
// open member always yielded nil: combined length 0, no provisional title, no summary, and a
// blank "Recording now" row for however long the conversation lasted.

private final class FakeLocalProvider: TranscriptionProvider, @unchecked Sendable {
    let id = "fake-local"
    private let lock = NSLock()
    private var _texts: [String]

    init(texts: [String] = ["hello from the open segment"]) { _texts = texts }

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        for try await _ in pcmChunks {}
        let text = lock.withLock { _texts.isEmpty ? "words" : _texts.removeFirst() }
        return TranscriptionResult(text: text, providerId: id, modelUsed: "fake-model")
    }
}

@Suite struct LivePreviewCacheTests {

    private func openMeta(_ segmentId: String, frameCount: Int64) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId,
            streamId: 3,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 0,
            startMonotonicMs: 0,
            receivedAtMs: 1_000,
            frameCount: frameCount
        )
    }

    private func frames(_ count: Int) -> [FrameRecord] {
        (0..<count).map {
            FrameRecord(
                sequence: UInt32($0), sampleIndex: UInt64($0 * 320),
                payload: [UInt8](repeating: 0, count: 25))
        }
    }

    /// The seam under test: one live pass, and the open segment's rolling text is readable
    /// synchronously by anything that cannot await an actor.
    @Test func aLivePassMirrorsTheOpenSegmentsTextIntoTheCache() async throws {
        let root = Fixture.temporaryDirectory("live-preview")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LivePreviewCache()
        let transcribed = Box(false)
        let transcriber = LiveTranscriber(
            openSegmentId: { "seg-live" },
            readMeta: { [self] id in id == "seg-live" ? openMeta(id, frameCount: 200) : nil },
            readFrames: { [self] _ in frames(200) },
            router: TranscriptionModeRouter(
                local: FakeLocalProvider(), remote: nil, mode: { .localOnly }),
            nowMs: { 5_000 },
            minChunkFrames: 100
        )
        let service = LiveAudioService(
            store: SegmentStore(root: root, nowMs: { 5_000 }),
            localLive: transcriber,
            hasDurableTranscript: { _ in transcribed.value },
            automaticWavExportEnabled: { false },
            previewCache: cache
        )

        #expect(cache.text(for: "seg-live") == nil, "nothing recognized yet reads as nil")
        #expect(try await service.localLivePass())
        #expect(cache.text(for: "seg-live") == "hello from the open segment")

        // …and it never outlives the audio it describes: once the durable transcript lands, the
        // prune empties the mirror too, so no enrichment pass can be handed stale live text for a
        // segment that now has a real transcript.
        transcribed.value = true
        _ = try await service.localLivePass()
        #expect(cache.text(for: "seg-live") == nil)
        #expect(cache.segmentIds.isEmpty)
    }

    /// The other end of the seam, over the real grouping and the real annotation store: a LIVE
    /// conversation gets its provisional title from the mirrored preview. The first half is the
    /// defect itself — with nothing in the mirror (which is what the unsupplied `{ _ in nil }`
    /// default guaranteed) the conversation's combined length is 0 and the pass does nothing at
    /// all, however long the person keeps talking.
    @Test func aLiveConversationIsAnnotatedFromTheMirroredPreview() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store, close: false)
        let clock = fixture.clock
        let provider = FakeAnnotationProvider()
        let enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: fixture.annotations,
                router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
                nowMs: { clock.nowMs }
            ),
            followUps: FollowUpWorker(
                items: ActionItemStore(db: fixture.database, nowMs: { clock.nowMs }),
                state: try FollowUpExtractionStore(db: fixture.database),
                router: nil,
                nowMs: { clock.nowMs }
            ),
            annotations: fixture.annotations,
            store: fixture.store,
            database: fixture.database,
            pauseJournal: fixture.pauseJournal,
            transcriptOf: { _ in nil },
            liveTextOf: { fixture.livePreviews.text(for: $0) },
            clock: clock
        )
        try await enrichment.regroupPass()

        #expect(try await enrichment.enrichPass().isEmpty)
        #expect(provider.runCount == 0, "nothing to summarize while the mirror is empty")

        fixture.livePreviews.replaceAll([
            segmentId: String(repeating: "and then we talked about the roof. ", count: 8)
        ])
        let annotated = try await enrichment.enrichPass()

        #expect(annotated.count == 1)
        let annotation = try await fixture.annotations.load(try #require(annotated.first))
        #expect(annotation?.title == "The roof")
        #expect(
            annotation?.isFinal == false,
            "a live annotation is provisional; the final pass runs when the segment closes")
    }

    @Test func blankPreviewTextIsNeverStored() {
        let cache = LivePreviewCache()
        cache.replaceAll(["seg-a": "   \n ", "seg-b": " real words "])
        #expect(cache.text(for: "seg-a") == nil)
        #expect(cache.text(for: "seg-b") == "real words")
    }

    @Test func replacingDropsSegmentsThatAreNoLongerPreviewed() {
        let cache = LivePreviewCache()
        cache.replaceAll(["seg-a": "one", "seg-b": "two"])
        cache.replaceAll(["seg-b": "two"])
        #expect(cache.segmentIds == ["seg-b"])
    }
}

private final class FakeAnnotationProvider: AiProvider, @unchecked Sendable {
    let id = "fake-ai"
    private let lock = NSLock()
    private var _runCount = 0
    var runCount: Int { lock.withLock { _runCount } }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _runCount += 1 }
        return AiProviderResult(
            text: "TITLE: The roof\nSUMMARY: Talked about the roof.\nTAGS: home",
            modelUsed: "fake-model"
        )
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
