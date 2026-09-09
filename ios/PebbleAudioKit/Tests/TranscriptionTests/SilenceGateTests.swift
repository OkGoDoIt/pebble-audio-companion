import AppDB
import AudioCodec
import Foundation
import Testing

@testable import Transcription

// Stream EN. The gate that keeps provably-silent audio away from a transcription provider, at
// both places audio can reach one: the foreground processor and the background upload
// coordinator. What is being protected is not only money — it is that neither provider can
// invent sentences out of audio it never receives.
//
// Levels come from the real corpus; see `SegmentEnergy.provableSilenceFloorRms`.

// MARK: - Fixtures

/// s16le mono PCM at 16 kHz: `ms` at the given RMS (square wave, so RMS == amplitude).
private func levelPcm(rms: Int, ms: Int) -> Data {
    let samples = 16_000 * ms / 1_000
    var out = Data(capacity: samples * 2)
    for i in 0..<samples {
        let value = Int16(i % 2 == 0 ? rms : -rms)
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    return out
}

/// Room tone at the microphone's own measured noise floor — the audio the gate exists for.
private func roomTone(ms: Int) -> Data { levelPcm(rms: 12, ms: ms) }

/// Ordinary speech level (the corpus median recording's loudest second is RMS 1733).
private func speech(ms: Int) -> Data { levelPcm(rms: 900, ms: ms) }

private final class GateFakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id = "local"
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        lock.withLock { calls += 1 }
        // Drains its input like a real provider, so a stream that fails mid-read surfaces here
        // rather than being silently ignored.
        for try await _ in pcmChunks {}
        // What a provider handed room tone actually does: it answers fluently.
        return TranscriptionResult(
            text: "The weather looks clear for the rest of the afternoon.",
            providerId: id, modelUsed: "model")
    }
}

// MARK: - Foreground processor

@Suite struct SilenceGateProcessorTests {
    private let clock = ClockBox(5_000)
    private let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    private func queue() -> TranscriptionQueue {
        TranscriptionQueue(database: db, nowMs: { [clock] in clock.postIncrement() })
    }

    private func processor(
        queue: TranscriptionQueue,
        provider: GateFakeProvider,
        pcm: [Data],
        floor: Double? = SegmentEnergy.provableSilenceFloorRms,
        states: (@Sendable (String, TaskState) -> Void)? = nil
    ) -> TranscriptionProcessor {
        TranscriptionProcessor(
            queue: queue,
            router: TranscriptionModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            pcmSource: { _ in pcmStream(pcm) },
            onStateChanged: states ?? { _, _ in },
            silenceFloorRms: floor
        )
    }

    @Test func provablySilentSegmentIsNeverHandedToAProvider() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let processor = processor(queue: queue, provider: provider, pcm: [roomTone(ms: 30_000)])

        try await processor.processNext()

        #expect(provider.callCount == 0, "silent audio must not reach a provider at all")
        let task = try queue.load("seg-1")
        #expect(task?.state == .noSpeech, "terminal, and not a failure")
        #expect(task?.lastError == nil)
        #expect(task?.attempts == 0, "a gated segment must not burn a retry attempt")
    }

    @Test func gatedSegmentAnnouncesQuietNotFailure() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let seen = StateLog()
        let processor = processor(
            queue: queue, provider: GateFakeProvider(), pcm: [roomTone(ms: 30_000)],
            states: { [seen] id, state in seen.append(id, state) })

        try await processor.processNext()

        // Never Running, never Failed: the UI is told once, and what it is told is terminal.
        #expect(seen.states == [.noSpeech])
    }

    @Test func gatedSegmentIsNotRetriedOrRevived() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let processor = processor(
            queue: queue, provider: GateFakeProvider(), pcm: [roomTone(ms: 30_000)])

        try await processor.processNext()
        #expect(try queue.nextRunnable() == nil, "nothing left to run")
        #expect(try queue.nextRetryAtMs() == nil, "no backoff timer to wake for")
        // `reviveExhausted` rescues stuck FAILURES after an outage; a settled quiet segment is
        // not one, and must not come back around.
        let revived = try queue.reviveExhausted(notAttemptedWithinMs: 0) { _ in true }
        #expect(revived.isEmpty)
        #expect(try queue.load("seg-1")?.state == .noSpeech)
    }

    @Test func gatedSegmentSettlesInsteadOfLookingUntranscribed() async throws {
        // `enqueueClosedSegments` runs on every pipeline pass over every not-fully-transcribed
        // segment. A gated one must re-announce its terminal state, not requeue — otherwise the
        // gate would run forever on a loop instead of settling once.
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let first = processor(queue: queue, provider: provider, pcm: [roomTone(ms: 30_000)])
        try await first.processNext()

        let seen = StateLog()
        let second = processor(
            queue: queue, provider: provider, pcm: [roomTone(ms: 30_000)],
            states: { [seen] id, state in seen.append(id, state) })
        try second.enqueueClosedSegments(["seg-1"])

        #expect(seen.states == [.noSpeech])
        #expect(try queue.load("seg-1")?.state == .noSpeech)
        #expect(provider.callCount == 0)
    }

    @Test func quietButRealSpeechStillTranscribes() async throws {
        // The muffled-dictation case from the corpus: thirteen minutes under the floor with one
        // real second in it. Transcription must proceed exactly as before.
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let processor = processor(
            queue: queue, provider: provider,
            pcm: [levelPcm(rms: 11, ms: 120_000), levelPcm(rms: 85, ms: 1_000)])

        try await processor.processNext()

        #expect(provider.callCount == 1)
        #expect(try queue.load("seg-1")?.state == .complete)
    }

    @Test func ordinarySpeechIsUnaffected() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let processor = processor(queue: queue, provider: provider, pcm: [speech(ms: 5_000)])

        try await processor.processNext()

        #expect(provider.callCount == 1)
        #expect(try queue.load("seg-1")?.state == .complete)
    }

    @Test func gateCanBeDisabled() async throws {
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let processor = processor(
            queue: queue, provider: provider, pcm: [roomTone(ms: 30_000)], floor: nil)

        try await processor.processNext()

        #expect(provider.callCount == 1)
        #expect(try queue.load("seg-1")?.state == .complete)
    }

    @Test func gateFailsOpenWhenTheAudioCannotBeMeasured() async throws {
        // A truncated spool, a store that moved on: the measurement throws. The segment must go
        // down the normal path — where the failure is recorded honestly and retried — rather than
        // being silently declared quiet. A gate that cannot measure never claims silence.
        let queue = queue()
        try queue.enqueue("seg-1")
        let provider = GateFakeProvider()
        let processor = TranscriptionProcessor(
            queue: queue,
            router: TranscriptionModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            pcmSource: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(roomTone(ms: 5_000))
                    continuation.finish(throwing: AssertionError("spool truncated"))
                }
            }
        )

        try await processor.processNext()

        #expect(provider.callCount == 1, "the gate must hand an unmeasurable segment onward")
        let task = try queue.load("seg-1")
        #expect(task?.state == .failed, "an unreadable segment is a failure, not a quiet one")
        #expect(task?.retryable == true)
    }
}

/// Records the processor's state announcements in order.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, TaskState)] = []
    func append(_ id: String, _ state: TaskState) { lock.withLock { entries.append((id, state)) } }
    var states: [TaskState] { lock.withLock { entries.map(\.1) } }
}

// MARK: - Background upload path (the one that spends money)

private final class SilenceGateUploader: BackgroundUploader, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudUploadRequest] = []
    let outcomes: AsyncStream<CloudUploadOutcome>

    init() { (outcomes, _) = AsyncStream<CloudUploadOutcome>.makeStream() }

    var enqueued: [CloudUploadRequest] { lock.withLock { recorded } }
    func enqueue(_ request: CloudUploadRequest) async {
        lock.withLock { recorded.append(request) }
    }
    func reconcile() async {}
    func inFlightJobIds() async -> Set<String> { [] }
}

private final class SilenceGateCloud: TranscriptionProvider, CloudUploadCapable, @unchecked Sendable
{
    let id = "soniox"
    func isAvailable() async -> Bool { true }
    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult { throw AssertionError("not used") }
    let uploadFormatLadder: [CloudAudioFormat] = CloudUploadFormatPreference.ladder
    func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan? {
        CloudUploadPlan(
            url: "https://soniox/files",
            file: MultipartBody.FilePart(
                name: "file", filename: audio.filename("s"), contentType: audio.contentType,
                bytes: audio.bytes))
    }
    func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        .done(TranscriptionResult(text: body, providerId: id, modelUsed: "m"))
    }
    func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        throw AssertionError("no control plane")
    }
}

/// Minimal in-memory queue behind the coordinator's `QueueHooks` seam.
private final class SilenceGateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var states: [String: TaskState] = [:]

    func enqueue(_ segmentId: String) {
        lock.withLock {
            if states[segmentId] == nil { order.append(segmentId) }
            states[segmentId] = .pending
        }
    }
    func state(_ segmentId: String) -> TaskState? { lock.withLock { states[segmentId] } }

    var hooks: BackgroundCloudUploadCoordinator.QueueHooks {
        BackgroundCloudUploadCoordinator.QueueHooks(
            pendingSegmentIds: { [self] in lock.withLock { order.filter { states[$0] == .pending } } },
            uploadingSegmentIds: { [self] in
                lock.withLock { Set(order.filter { states[$0] == .uploading }) }
            },
            isUploading: { [self] id in lock.withLock { states[id] == .uploading } },
            markUploading: { [self] id in lock.withLock { states[id] = .uploading } },
            saveTranscript: { _, _, _ in },
            markComplete: { [self] id, _, _ in lock.withLock { states[id] = .complete } },
            markFailed: { [self] id, _, _ in lock.withLock { states[id] = .failed } },
            markNoSpeech: { [self] id in lock.withLock { states[id] = .noSpeech } },
            resetAbandonedUploads: { _, _ in [] }
        )
    }
}

@Suite struct SilenceGateUploadTests {
    private func coordinator(
        queue: SilenceGateQueue, uploader: SilenceGateUploader, wav: Data
    ) throws -> BackgroundCloudUploadCoordinator {
        let root = try makeTempRoot("silence-gate")
        return BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: SilenceGateCloud(), soniox: SilenceGateCloud()),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: { _, _ in SegmentAudio(wav: wav, sampleRateHz: 16_000) },
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 1 },
            cloudPrimary: { true }
        )
    }

    @Test func provablySilentAudioIsSettledInsteadOfUploaded() async throws {
        let queue = SilenceGateQueue()
        queue.enqueue("seg-1")
        let uploader = SilenceGateUploader()
        let wav = PcmWav.encodeMono16(pcm: roomTone(ms: 30_000), sampleRateHz: 16_000)

        try await coordinator(queue: queue, uploader: uploader, wav: wav).submitPending()

        #expect(uploader.enqueued.isEmpty, "no bytes may leave the device")
        #expect(queue.state("seg-1") == .noSpeech, "settled, so it is not retried forever")
    }

    @Test func audibleAudioStillUploads() async throws {
        let queue = SilenceGateQueue()
        queue.enqueue("seg-1")
        let uploader = SilenceGateUploader()
        let wav = PcmWav.encodeMono16(pcm: speech(ms: 5_000), sampleRateHz: 16_000)

        try await coordinator(queue: queue, uploader: uploader, wav: wav).submitPending()

        #expect(uploader.enqueued.count == 1)
        #expect(queue.state("seg-1") == .uploading)
    }

    @Test func quietButRealSpeechStillUploads() async throws {
        // Same muffled-dictation guard as the foreground path, on the money path.
        let queue = SilenceGateQueue()
        queue.enqueue("seg-1")
        let uploader = SilenceGateUploader()
        var pcm = levelPcm(rms: 11, ms: 120_000)
        pcm.append(levelPcm(rms: 85, ms: 1_000))
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: 16_000)

        try await coordinator(queue: queue, uploader: uploader, wav: wav).submitPending()

        #expect(uploader.enqueued.count == 1)
        #expect(queue.state("seg-1") == .uploading)
    }

    @Test func settledSilentSegmentDoesNotOccupyTheUploadBudget() async throws {
        // A gated segment must leave the concurrency budget for real work: four silent segments
        // ahead of one real one must not starve it.
        let queue = SilenceGateQueue()
        for i in 1...4 { queue.enqueue("quiet-\(i)") }
        queue.enqueue("loud-1")
        let uploader = SilenceGateUploader()
        let root = try makeTempRoot("silence-gate-budget")
        let coordinator = BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: SilenceGateCloud(), soniox: SilenceGateCloud()),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: { segmentId, _ in
                let pcm = segmentId.hasPrefix("quiet") ? roomTone(ms: 20_000) : speech(ms: 5_000)
                return SegmentAudio(
                    wav: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: 16_000), sampleRateHz: 16_000)
            },
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 1 },
            cloudPrimary: { true }
        )

        try await coordinator.submitPending()

        #expect(uploader.enqueued.map(\.jobId) == ["loud-1"])
        for i in 1...4 { #expect(queue.state("quiet-\(i)") == .noSpeech) }
    }
}
