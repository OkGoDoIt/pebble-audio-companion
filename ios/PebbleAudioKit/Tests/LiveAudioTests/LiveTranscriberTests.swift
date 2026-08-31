import Foundation
import SegmentStore
import Testing
import Transcription

@testable import LiveAudio

// Port of `app/src/commonTest/.../LiveTranscriberTest.kt` — all 8 cases, same names.

private final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id = "fake-local"
    private let lock = NSLock()
    var available = true
    var nextError: Error?
    var texts: [String] = []
    private var _transcribeCalls = 0
    var transcribeCalls: Int { lock.withLock { _transcribeCalls } }

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
    let provider = FakeProvider()
    let openId = Box<String?>("seg-1")
    let frameCount = Box<Int64>(0)
    let nowMs = ClockBox(1_000_000)
    let metaOpen = Box(true)

    let transcriber: LiveTranscriber

    init(minChunkFrames: Int = 100, maxChunkFrames: Int = 500, failureBackoffMs: Int64 = 30_000) {
        let openId = self.openId
        let frameCount = self.frameCount
        let nowMs = self.nowMs
        let metaOpen = self.metaOpen
        transcriber = LiveTranscriber(
            openSegmentId: { openId.value },
            readMeta: { id in
                (id == "seg-1" || id == "seg-2")
                    ? testMeta(id, frameCount: frameCount.value, open: metaOpen.value) : nil
            },
            readFrames: { _ in testFrames(Int(frameCount.value)) },
            provider: provider,
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
}
