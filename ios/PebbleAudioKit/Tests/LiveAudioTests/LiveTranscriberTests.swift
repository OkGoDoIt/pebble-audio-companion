import Foundation
import SegmentStore
import Testing
import Transcription

@testable import LiveAudio

// Port of `app/src/commonTest/.../LiveTranscriberTest.kt` — all 8 cases, same names.

private final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    var available = true
    var nextError: Error?
    var texts: [String] = []
    private var _transcribeCalls = 0
    var transcribeCalls: Int { lock.withLock { _transcribeCalls } }

    init(id: String = "fake-local") { self.id = id }

    func isAvailable() async -> Bool { available }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        lock.withLock { _transcribeCalls += 1 }
        for try await _ in pcmChunks {}  // drain like a real provider
        if let error = nextError {
            nextError = nil
            throw error
        }
        let text = texts.isEmpty ? "words" : texts.removeFirst()
        return TranscriptionResult(text: text, providerId: id, modelUsed: "fake-model")
    }
}

private func testMeta(_ segmentId: String, frameCount: Int64, open: Bool = true) -> SegmentMeta {
    SegmentMeta(
        segmentId: segmentId,
        streamId: 7,
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
        frameCount: frameCount,
        closeReason: open ? nil : .interrupted
    )
}

private func testFrames(_ count: Int) -> [FrameRecord] {
    (0..<count).map { index in
        FrameRecord(
            sequence: UInt32(index),
            sampleIndex: UInt64(index * 320),
            payload: [UInt8](repeating: 0, count: 25)
        )
    }
}

private final class Harness: @unchecked Sendable {
    /// Named `provider` still: every ported case drives the LOCAL provider, and the harness
    /// defaults to LocalOnly so those cases keep their original meaning.
    let provider = FakeProvider()
    let remote = FakeProvider(id: "fake-remote")
    let openId = Box<String?>("seg-1")
    let frameCount = Box<Int64>(0)
    let nowMs = ClockBox(1_000_000)
    let metaOpen = Box(true)
    let mode: Box<TranscriptionMode>

    let transcriber: LiveTranscriber

    init(
        minChunkFrames: Int = 100,
        maxChunkFrames: Int = 500,
        failureBackoffMs: Int64 = 30_000,
        mode: TranscriptionMode = .localOnly
    ) {
        let openId = self.openId
        let frameCount = self.frameCount
        let nowMs = self.nowMs
        let metaOpen = self.metaOpen
        let modeBox = Box(mode)
        self.mode = modeBox
        transcriber = LiveTranscriber(
            openSegmentId: { openId.value },
            readMeta: { id in
                (id == "seg-1" || id == "seg-2")
                    ? testMeta(id, frameCount: frameCount.value, open: metaOpen.value) : nil
            },
            readFrames: { _ in testFrames(Int(frameCount.value)) },
            router: TranscriptionModeRouter(
                local: provider, remote: remote, mode: { modeBox.value }
            ),
            nowMs: { nowMs.now },
            decodePcm: { _, frames in flowOf(Data(count: frames.count * 2)) },
            minChunkFrames: minChunkFrames,
            maxChunkFrames: maxChunkFrames,
            failureBackoffMs: failureBackoffMs
        )
    }
}

@Suite struct LiveTranscriberTests {

    @Test func waitsForMinimumChunkBeforeTranscribing() async throws {
        let h = Harness()
        h.frameCount.value = 99
        #expect(try await h.transcriber.processOnce() == false)
        #expect(await h.transcriber.hasPendingWork() == false)
        #expect(await h.transcriber.textFor("seg-1") == nil)
        #expect(h.provider.transcribeCalls == 0)
    }

    @Test func transcribesChunkAndAppendsAcrossPasses() async throws {
        let h = Harness()
        h.provider.texts.append(contentsOf: ["hello there", "general kenobi"])

        h.frameCount.value = 150
        #expect(await h.transcriber.hasPendingWork())
        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "hello there")

        // Not enough new audio yet.
        #expect(try await h.transcriber.processOnce() == false)

        h.frameCount.value = 260
        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "hello there general kenobi")
        #expect(h.provider.transcribeCalls == 2)
    }

    @Test func boundsOnePassToMaxChunkFrames() async throws {
        let h = Harness(minChunkFrames: 100, maxChunkFrames: 200)
        h.provider.texts.append(contentsOf: ["first", "second"])
        h.frameCount.value = 500

        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.previews["seg-1"]?.transcribedFrameCount == 200)
        // Backlog continues on the next pass.
        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "first second")
    }

    @Test func noSpeechAdvancesWithoutText() async throws {
        let h = Harness()
        h.frameCount.value = 150
        h.provider.nextError = TranscriptionError.noSpeechDetected("quiet")

        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == nil)
        #expect(await h.transcriber.previews["seg-1"]?.transcribedFrameCount == 150)
    }

    @Test func failureBacksOffThenRetries() async throws {
        let h = Harness()
        h.frameCount.value = 150
        h.provider.nextError = TranscriptionError.transcriptionFailed("boom")

        #expect(try await h.transcriber.processOnce() == false)
        #expect((await h.transcriber.previews["seg-1"]?.transcribedFrameCount ?? 0) == 0)

        // Still inside the backoff window: no provider call.
        h.nowMs.now += 1_000
        #expect(try await h.transcriber.processOnce() == false)
        #expect(h.provider.transcribeCalls == 1)

        h.nowMs.now += 60_000
        h.provider.texts.append("recovered")
        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "recovered")
    }

    @Test func unavailableRouterDoesNothing() async throws {
        let h = Harness()
        h.frameCount.value = 150
        h.provider.available = false
        #expect(try await h.transcriber.processOnce() == false)
        #expect(h.provider.transcribeCalls == 0)
    }

    @Test func pruneDropsFinalizedAndMissingSegments() async throws {
        let h = Harness()
        h.provider.texts.append("preview")
        h.frameCount.value = 150
        #expect(try await h.transcriber.processOnce())

        // Final transcript exists now: the preview is superseded.
        await h.transcriber.prune(hasFinalTranscript: { _ in true })
        #expect(await h.transcriber.textFor("seg-1") == nil)
    }

    @Test func keepsPreviewOfJustClosedSegmentUntilFinalTranscript() async throws {
        let h = Harness()
        h.provider.texts.append("ongoing words")
        h.frameCount.value = 150
        #expect(try await h.transcriber.processOnce())

        // Segment closed (rotation/stop); preview should survive pruning until the durable
        // transcript lands.
        h.openId.value = nil
        h.metaOpen.value = false
        await h.transcriber.prune(hasFinalTranscript: { _ in false })
        #expect(await h.transcriber.textFor("seg-1") == "ongoing words")

        await h.transcriber.prune(hasFinalTranscript: { _ in true })
        #expect(await h.transcriber.textFor("seg-1") == nil)
    }

    // MARK: - Mode routing (the defect: the live preview ignored Settings)

    @Test func localOnlyKeepsThePreviewOnDevice() async throws {
        let h = Harness(mode: .localOnly)
        h.provider.texts.append("on device words")
        h.frameCount.value = 150

        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "on device words")
        #expect(h.remote.transcribeCalls == 0)
        #expect(await h.transcriber.previews["seg-1"]?.providerId == "fake-local")
    }

    @Test func remoteFirstSendsThePreviewToTheCloud() async throws {
        let h = Harness(mode: .remoteFirst)
        h.remote.texts.append("cloud words")
        h.frameCount.value = 150

        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "cloud words")
        #expect(h.remote.transcribeCalls == 1)
        #expect(h.provider.transcribeCalls == 0)
        // The provenance line reads this: a cloud preview must never say on-device.
        #expect(await h.transcriber.previews["seg-1"]?.providerId == "fake-remote")
    }

    @Test func remoteFirstFallsBackToLocalAndSaysSo() async throws {
        let h = Harness(mode: .remoteFirst)
        h.remote.nextError = TranscriptionError.transcriptionFailed("cloud down")
        h.provider.texts.append("local rescue")
        h.frameCount.value = 150

        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "local rescue")
        // ... and the preview is honest about who actually produced it.
        #expect(await h.transcriber.previews["seg-1"]?.providerId == "fake-local")
    }

    @Test func remoteOnlyNeverFallsBackToTheLocalEngine() async throws {
        let h = Harness(mode: .remoteOnly)
        h.remote.nextError = TranscriptionError.transcriptionFailed("cloud down")
        h.provider.texts.append("must not be used")
        h.frameCount.value = 150

        #expect(try await h.transcriber.processOnce() == false)
        #expect(h.provider.transcribeCalls == 0)
        #expect(await h.transcriber.textFor("seg-1") == nil)
    }

    @Test func modeChangeTakesEffectOnTheNextPass() async throws {
        let h = Harness(mode: .localOnly)
        h.provider.texts.append("local first")
        h.remote.texts.append("then cloud")
        h.frameCount.value = 150
        #expect(try await h.transcriber.processOnce())

        h.mode.value = .remoteOnly
        h.frameCount.value = 260
        #expect(try await h.transcriber.processOnce())
        #expect(await h.transcriber.textFor("seg-1") == "local first then cloud")
        #expect(h.remote.transcribeCalls == 1)
        #expect(await h.transcriber.previews["seg-1"]?.providerId == "fake-remote")
    }

    // MARK: - Standing down for the realtime socket (no double transcription)

    @Test func coveredAudioIsNeitherTranscribedNorRebilled() async throws {
        let h = Harness(mode: .remoteFirst)
        h.remote.texts.append(contentsOf: ["after the handoff"])
        h.frameCount.value = 400

        // The realtime socket carried this stretch: no provider call, no preview.
        await h.transcriber.markCoveredByOtherSource()
        #expect(try await h.transcriber.processOnce() == false)
        #expect(await h.transcriber.hasPendingWork() == false)
        #expect(h.remote.transcribeCalls == 0)
        #expect(h.provider.transcribeCalls == 0)
        #expect(await h.transcriber.previewFor("seg-1") == nil)

        // The socket dies: only audio recorded AFTER the handoff is transcribed here.
        h.frameCount.value = 550
        #expect(try await h.transcriber.processOnce())
        let preview = await h.transcriber.previews["seg-1"]
        #expect(preview?.text == "after the handoff")
        #expect(preview?.transcribedFrameCount == 550)
        #expect(h.remote.transcribeCalls == 1)
    }
}

// MARK: - Merging the two live sources

@Suite struct LiveTranscriptPreviewMergeTests {
    private func preview(
        text: String,
        segments: [(String, Int64, Int64)],
        updatedAtMs: Int64,
        providerId: String
    ) -> LiveTranscriptPreview {
        LiveTranscriptPreview(
            segmentId: "seg-1",
            text: text,
            segments: segments.map {
                TranscriptSegment(text: $0.0, startMs: $0.1, endMs: $0.2)
            },
            transcribedFrameCount: 100,
            lastSampleIndexExclusive: 32_000,
            updatedAtMs: updatedAtMs,
            providerId: providerId
        )
    }

    @Test func eitherSideAloneIsUsedAsIs() {
        let cloud = preview(
            text: "cloud", segments: [("cloud", 0, 1_000)], updatedAtMs: 10, providerId: "soniox")
        #expect(LiveTranscriptPreview.merged(cloud: cloud, local: nil)?.providerId == "soniox")
        #expect(LiveTranscriptPreview.merged(cloud: nil, local: cloud)?.providerId == "soniox")
        #expect(LiveTranscriptPreview.merged(cloud: nil, local: nil) == nil)
    }

    @Test func cloudPreviewSurfacesWithItsOwnProvenance() {
        let cloud = preview(
            text: "streamed live", segments: [("streamed live", 0, 4_000)], updatedAtMs: 200,
            providerId: "soniox-realtime")
        let local = preview(
            text: "chunked", segments: [("chunked", 0, 3_000)], updatedAtMs: 100,
            providerId: "speechanalyzer")

        let merged = LiveTranscriptPreview.merged(cloud: cloud, local: local)
        // The chunk path covered nothing the socket did not, so the socket's text stands.
        #expect(merged?.text == "streamed live")
        #expect(merged?.providerId == "soniox-realtime")
    }

    @Test func takeoverKeepsTheCloudPrefixAndNamesTheNewSource() {
        let cloud = preview(
            text: "the socket said this", segments: [("the socket said this", 0, 8_000)],
            updatedAtMs: 100, providerId: "soniox-realtime")
        let local = preview(
            text: "and then this", segments: [("and then this", 8_000, 16_000)],
            updatedAtMs: 300, providerId: "speechanalyzer")

        let merged = LiveTranscriptPreview.merged(cloud: cloud, local: local)
        #expect(merged?.text == "the socket said this and then this")
        #expect(merged?.segments.count == 2)
        // Newest words came from the fallback, so the line must not still say Soniox.
        #expect(merged?.providerId == "speechanalyzer")
        #expect(merged?.updatedAtMs == 300)
    }
}
