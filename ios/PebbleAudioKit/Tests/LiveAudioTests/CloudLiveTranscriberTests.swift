import Foundation
import SegmentStore
import Testing
import Transcription

@testable import LiveAudio

// Port of `app/src/commonTest/.../CloudLiveTranscriberTest.kt` — all 4 cases, same names.
// The KMP tests ran on kotlinx virtual time; here reconnect backoffs are injected as zero and
// each ordering point the scheduler used to provide is pinned with an explicit `waitUntil`.

private final class FakeStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let id = "fake-cloud"
    var available = true
    let updates = Broadcast<StreamingTranscriptUpdate>()
    private let lock = NSLock()
    private var _streamStarts = 0
    var streamStarts: Int { lock.withLock { _streamStarts } }

    func isAvailable() async -> Bool { available }

    func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        lock.withLock { _streamStarts += 1 }
        let updates = updates
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await update in updates.subscribe() {
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Fails its first `failuresBeforeSuccess` streams (simulating transient Soniox socket errors).
/// A provider whose socket is taken away underneath it, the way iOS does when it suspends the
/// app and the way a Wi-Fi↔cellular handover does at any time.
private final class DroppedSocketProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let id = "dropped-cloud"
    private let lock = NSLock()
    private var _streamStarts = 0
    var streamStarts: Int { lock.withLock { _streamStarts } }

    func isAvailable() async -> Bool { true }

    func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        lock.withLock { _streamStarts += 1 }
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: WebSocketDroppedError(code: 53))
        }
    }
}

private final class FlakyStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let id = "flaky-cloud"
    private let failuresBeforeSuccess: Int
    private let lock = NSLock()
    private var _streamStarts = 0
    var streamStarts: Int { lock.withLock { _streamStarts } }
    let updates = Broadcast<StreamingTranscriptUpdate>()

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func isAvailable() async -> Bool { true }

    func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        let attempt: Int = lock.withLock {
            let value = _streamStarts
            _streamStarts += 1
            return value
        }
        let updates = updates
        let shouldFail = attempt < failuresBeforeSuccess
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(
                    throwing: TranscriptionError.transcriptionFailed(
                        "Soniox realtime error: Request timeout"))
                return
            }
            let task = Task {
                for await update in updates.subscribe() {
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func cloudFrames(_ count: Int, firstSequence: UInt32 = 0) -> [SegmentFrame] {
    (0..<count).map { index in
        let sequence = firstSequence + UInt32(index)
        return SegmentFrame(
            sequence: sequence,
            sampleIndex: UInt64(sequence) * 320,
            payload: [UInt8](repeating: 1, count: 25)
        )
    }
}

private func opened(_ segmentId: String) -> LiveAudioEvent {
    .segmentOpened(
        LiveAudioEvent.SegmentOpened(
            segmentId: segmentId, sampleRateHz: 16_000, bitRateBps: 9_800, frameSamples: 320))
}

@Suite struct CloudLiveTranscriberTests {

    @Test func streamingPreviewCarriesTranscribedFrameAndSampleBoundary() async throws {
        let tap = LiveAudioTap()
        let provider = FakeStreamingProvider()
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { provider.updates.subscriberCount == 1 })
        tap.emit(.framesAppended(segmentId: "seg-1", frames: cloudFrames(3, firstSequence: 10)))
        #expect(await waitUntil { await transcriber.streamedFrameCountForTesting() == 3 })
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "streaming words")))
        #expect(await waitUntil { await transcriber.previews["seg-1"] != nil })

        let preview = await transcriber.previews["seg-1"]
        #expect(preview?.text == "streaming words")
        #expect(preview?.transcribedFrameCount == 3)
        #expect(preview?.lastSampleIndexExclusive == 13 * 320)
        #expect(preview?.providerId == "fake-cloud")

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        await transcriber.setForeground(false)
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func backgroundingDoesNotStopCloudStreamingProgress() async throws {
        let tap = LiveAudioTap()
        let provider = FakeStreamingProvider()
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { provider.updates.subscriberCount == 1 })
        tap.emit(.framesAppended(segmentId: "seg-1", frames: cloudFrames(3, firstSequence: 10)))
        #expect(await waitUntil { await transcriber.streamedFrameCountForTesting() == 3 })
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "before background")))
        #expect(await waitUntil { await transcriber.previews["seg-1"]?.text == "before background" })

        await transcriber.setForeground(false)
        tap.emit(.framesAppended(segmentId: "seg-1", frames: cloudFrames(2, firstSequence: 13)))
        #expect(await waitUntil { await transcriber.streamedFrameCountForTesting() == 5 })
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "after background")))
        #expect(await waitUntil { await transcriber.previews["seg-1"]?.text == "after background" })

        let preview = await transcriber.previews["seg-1"]
        #expect(preview?.text == "after background")
        #expect(preview?.transcribedFrameCount == 5)
        #expect(preview?.lastSampleIndexExclusive == 15 * 320)

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func transientSocketFailureReconnectsAndKeepsTranscribing() async throws {
        let tap = LiveAudioTap()
        let provider = FlakyStreamingProvider(failuresBeforeSuccess: 2)
        let outcomes = Box<[CloudLiveOutcome]>([])
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            onOutcome: { outcome in outcomes.mutate { $0.append(outcome) } },
            reconnectBackoffMs: { _ in 0 },
            logFailure: { _, _ in },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        // First two stream attempts fail; backoff (zero here) elapses; third connects.
        #expect(await waitUntil { provider.updates.subscriberCount == 1 })
        tap.emit(.framesAppended(segmentId: "seg-1", frames: cloudFrames(3, firstSequence: 10)))
        #expect(await waitUntil { await transcriber.streamedFrameCountForTesting() == 3 })
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "recovered words")))
        #expect(await waitUntil { await transcriber.previews["seg-1"] != nil })

        #expect(provider.streamStarts == 3)  // 2 failures + 1 success
        let failedCount = outcomes.value.filter {
            if case .failed = $0 { return true } else { return false }
        }.count
        #expect(failedCount == 2)
        if case .ok = outcomes.value.last {
        } else {
            Issue.record("expected last outcome to be Ok, got \(String(describing: outcomes.value.last))")
        }
        #expect(await transcriber.previews["seg-1"]?.text == "recovered words")

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func interruptedConnectionReconnectsQuietlyWithoutBlamingTheProvider() async throws {
        // Roger's log showed `NSPOSIXErrorDomain Code=53 "Software caused connection abort"`
        // recorded as a live-transcription FAILURE while iOS had the app suspended. Losing a
        // WebSocket to suspension is what suspension IS — it is not evidence that Soniox is
        // unwell, and three of them must not raise "Cloud transcription isn't working" at
        // someone who merely put their phone in a pocket.
        let tap = LiveAudioTap()
        let provider = DroppedSocketProvider()
        let outcomes = Box<[CloudLiveOutcome]>([])
        let notes = Box<[String]>([])
        let failureLogs = Box<[String]>([])
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            onOutcome: { outcome in outcomes.mutate { $0.append(outcome) } },
            maxReconnects: 4,
            reconnectBackoffMs: { _ in 0 },
            logFailure: { label, _ in failureLogs.mutate { $0.append(label) } },
            logNote: { note in notes.mutate { $0.append(note) } },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { provider.streamStarts == 5 })

        // It still reconnects, on the same bounded budget as any other reconnect...
        #expect(provider.streamStarts == 5)  // initial attempt + 4 reconnects
        // ...but cloud health hears nothing, because nothing was learned about the cloud.
        #expect(outcomes.value.isEmpty)
        // ...and the log records an event, not a defect.
        #expect(failureLogs.value.isEmpty)
        #expect(notes.value.count == 5)
        #expect(notes.value.allSatisfy { $0.contains("interrupted") })

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func providerFailureIsClassifiedNotQuotedVerbatim() async throws {
        // The other half of the same rule: a real provider fault DOES reach cloud health, but
        // as a case the app has a sentence for — never as the provider's own prose (B20).
        let tap = LiveAudioTap()
        let provider = FlakyStreamingProvider(failuresBeforeSuccess: Int.max)
        let outcomes = Box<[CloudLiveOutcome]>([])
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            onOutcome: { outcome in outcomes.mutate { $0.append(outcome) } },
            maxReconnects: 0,
            reconnectBackoffMs: { _ in 0 },
            logFailure: { _, _ in },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { outcomes.value.count == 1 })
        #expect(outcomes.value == [.failed(kind: .timedOut)])

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        tapJob.cancel()
        await tapJob.value
    }

    @Test func givesUpAfterMaxReconnects() async throws {
        let tap = LiveAudioTap()
        let provider = FlakyStreamingProvider(failuresBeforeSuccess: Int.max)
        let outcomes = Box<[CloudLiveOutcome]>([])
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            onOutcome: { outcome in outcomes.mutate { $0.append(outcome) } },
            maxReconnects: 4,
            reconnectBackoffMs: { _ in 0 },
            logFailure: { _, _ in },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(
            await waitUntil {
                outcomes.value.count == 5 && provider.streamStarts == 5
            })

        #expect(provider.streamStarts == 5)  // initial attempt + 4 reconnects
        let failedCount = outcomes.value.filter {
            if case .failed = $0 { return true } else { return false }
        }.count
        #expect(failedCount == 5)

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func aConnectedButWordlessSocketDoesNotClaimTheSegment() async throws {
        // Soniox answers a connected socket with token-less frames while nobody is speaking.
        // Those used to claim the segment on arrival: an empty preview was published and
        // `LiveAudioService` stood the chunk-based fallback down, so a session that never
        // produced words left the Recording-now screen on its "Listening — words appear here"
        // line for the whole recording, with the path that would have filled it held back.
        let tap = LiveAudioTap()
        let provider = FakeStreamingProvider()
        let outcomes = Box<[CloudLiveOutcome]>([])
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { 123_000 },
            onOutcome: { outcome in outcomes.mutate { $0.append(outcome) } },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { provider.updates.subscriberCount == 1 })
        tap.emit(.framesAppended(segmentId: "seg-1", frames: cloudFrames(3, firstSequence: 10)))
        #expect(await waitUntil { await transcriber.streamedFrameCountForTesting() == 3 })

        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "")))
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "   ")))
        // The socket answering AT ALL is what cloud health hears, and it is the ordering point
        // that proves both wordless updates were consumed before the assertions below.
        #expect(await waitUntil { outcomes.value.count == 1 })
        #expect(outcomes.value == [.ok()])
        // Nothing to show, and — the part that mattered — nothing claimed.
        #expect(await transcriber.previews["seg-1"] == nil)
        #expect(await transcriber.deliveringSegmentId() == nil)

        // The first real words take the segment over as they always did.
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "first words")))
        #expect(await waitUntil { await transcriber.previews["seg-1"]?.text == "first words" })
        #expect(await transcriber.deliveringSegmentId() == "seg-1")

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }

    @Test func aSocketThatGoesQuietHandsTheSegmentBack() async throws {
        // The other half: a session that delivered once and then went quiet held its claim for
        // as long as the socket stayed open, so the chunk path never resumed and the preview
        // froze mid-sentence. Delivery is evidence only while it is fresh.
        let clock = ClockBox(123_000)
        let tap = LiveAudioTap()
        let provider = FakeStreamingProvider()
        let transcriber = CloudLiveTranscriber(
            tap: tap,
            provider: provider,
            enabled: { true },
            nowMs: { clock.now },
            decodePcm: { _, encoded in passthrough(encoded) }
        )
        let tapJob = await transcriber.start()

        tap.emit(opened("seg-1"))
        #expect(await waitUntil { provider.updates.subscriberCount == 1 })
        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "some words")))
        #expect(await waitUntil { await transcriber.previews["seg-1"] != nil })
        #expect(await transcriber.deliveringSegmentId() == "seg-1")

        clock.now += CloudLiveTranscriber.deliveryStaleMs + 1
        #expect(await transcriber.deliveringSegmentId() == nil)
        // The preview itself stays on screen — the words were said. Only the CLAIM expires.
        #expect(await transcriber.previews["seg-1"]?.text == "some words")

        #expect(provider.updates.send(StreamingTranscriptUpdate(finalText: "some words again")))
        #expect(await waitUntil { await transcriber.deliveringSegmentId() == "seg-1" })

        tap.emit(.segmentClosed(segmentId: "seg-1"))
        #expect(await waitUntil { await transcriber.activeSegmentIdForTesting() == nil })
        tapJob.cancel()
        await tapJob.value
    }
}
