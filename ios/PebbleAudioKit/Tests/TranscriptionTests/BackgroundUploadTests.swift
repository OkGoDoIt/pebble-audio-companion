import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../BackgroundCloudUploadCoordinatorTest.kt` — all 3
// cases, same names (fakes ported alongside). The KMP fixture used the real
// FileTranscriptionQueue/FileTranscriptStore; the Swift coordinator takes its queue seam as
// injected closures (`QueueHooks`), so the fixture drives an in-memory queue double that mirrors
// the queue's Uploading/Complete/Failed/NoSpeech contract.

private final class FakeUploader: BackgroundUploader, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudUploadRequest] = []
    private var inFlight: Set<String> = []

    let outcomes: AsyncStream<CloudUploadOutcome>
    private let continuation: AsyncStream<CloudUploadOutcome>.Continuation

    init() {
        (outcomes, continuation) = AsyncStream<CloudUploadOutcome>.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    var enqueued: [CloudUploadRequest] { lock.withLock { recorded } }

    func enqueue(_ request: CloudUploadRequest) async {
        lock.withLock {
            recorded.append(request)
            inFlight.insert(request.jobId)
        }
    }

    func reconcile() async {}

    func inFlightJobIds() async -> Set<String> {
        lock.withLock { inFlight }
    }

    func deliver(_ outcome: CloudUploadOutcome) {
        lock.withLock { _ = inFlight.remove(outcome.jobId) }
        continuation.yield(outcome)
    }
}

private final class FakeOpenAi: TranscriptionProvider, CloudUploadCapable, @unchecked Sendable {
    let id = "openai"

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        throw AssertionError("not used")
    }

    func uploadPlan(wav: Data, sampleRateHz: Int) async -> CloudUploadPlan? {
        CloudUploadPlan(
            url: "https://openai/transcriptions",
            file: MultipartBody.FilePart(
                name: "file", filename: "s.wav", contentType: "audio/wav", bytes: wav
            )
        )
    }

    func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        .done(TranscriptionResult(text: body, providerId: id, modelUsed: "m"))
    }

    func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        throw AssertionError("no control plane")
    }
}

private final class FakeSoniox: TranscriptionProvider, CloudUploadCapable, @unchecked Sendable {
    let id = "soniox"

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        throw AssertionError("not used")
    }

    func uploadPlan(wav: Data, sampleRateHz: Int) async -> CloudUploadPlan? {
        CloudUploadPlan(
            url: "https://soniox/files",
            file: MultipartBody.FilePart(
                name: "file", filename: "s.wav", contentType: "audio/wav", bytes: wav
            )
        )
    }

    func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        .needsControlPlane("file-123")
    }

    func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        TranscriptionResult(text: "soniox \(controlState)", providerId: id, modelUsed: "m")
    }
}

/// In-memory stand-in for FileTranscriptionQueue + FileTranscriptStore behind the coordinator's
/// `QueueHooks` seam.
private final class FakeUploadQueue: @unchecked Sendable {
    enum State: Equatable {
        case pending, uploading, complete, noSpeech, failed
    }

    struct SavedTranscript: Equatable {
        let text: String
        let modeUsed: TranscriptionMode
    }

    private let lock = NSLock()
    private var order: [String] = []
    private var states: [String: State] = [:]
    private var retryableFlags: [String: Bool] = [:]
    private var transcripts: [String: SavedTranscript] = [:]

    func enqueue(_ segmentId: String) {
        lock.withLock {
            if states[segmentId] == nil { order.append(segmentId) }
            states[segmentId] = .pending
        }
    }

    func state(_ segmentId: String) -> State? {
        lock.withLock { states[segmentId] }
    }

    func retryable(_ segmentId: String) -> Bool? {
        lock.withLock { retryableFlags[segmentId] }
    }

    func transcript(_ segmentId: String) -> SavedTranscript? {
        lock.withLock { transcripts[segmentId] }
    }

    var hooks: BackgroundCloudUploadCoordinator.QueueHooks {
        BackgroundCloudUploadCoordinator.QueueHooks(
            pendingSegmentIds: { [self] in
                lock.withLock { order.filter { states[$0] == .pending } }
            },
            uploadingSegmentIds: { [self] in
                lock.withLock { Set(order.filter { states[$0] == .uploading }) }
            },
            isUploading: { [self] segmentId in
                lock.withLock { states[segmentId] == .uploading }
            },
            markUploading: { [self] segmentId in
                lock.withLock { states[segmentId] = .uploading }
            },
            saveTranscript: { [self] segmentId, result, modeUsed in
                lock.withLock {
                    transcripts[segmentId] = SavedTranscript(text: result.text, modeUsed: modeUsed)
                }
            },
            markComplete: { [self] segmentId, _, _ in
                lock.withLock { states[segmentId] = .complete }
            },
            markFailed: { [self] segmentId, _, retryable in
                lock.withLock {
                    states[segmentId] = .failed
                    retryableFlags[segmentId] = retryable
                }
            },
            markNoSpeech: { [self] segmentId in
                lock.withLock { states[segmentId] = .noSpeech }
            },
            resetAbandonedUploads: { [self] inFlight in
                lock.withLock {
                    let abandoned = order.filter { states[$0] == .uploading && !inFlight.contains($0) }
                    for segmentId in abandoned { states[segmentId] = .pending }
                    return abandoned
                }
            }
        )
    }
}

@Suite struct BackgroundUploadTests {

    private struct Fixture {
        let root: URL
        let queue = FakeUploadQueue()
        let jobStore: CloudUploadJobStore
        let uploader = FakeUploader()
        let cloud: SelectableCloudTranscriptionProvider
        let coordinator: BackgroundCloudUploadCoordinator

        init(provider: CloudProvider) throws {
            root = try makeTempRoot("upload-coord")
            jobStore = CloudUploadJobStore(root: root)
            cloud = SelectableCloudTranscriptionProvider(
                selected: { provider },
                openAi: FakeOpenAi(),
                soniox: FakeSoniox()
            )
            coordinator = BackgroundCloudUploadCoordinator(
                uploader: uploader,
                cloudProvider: cloud,
                jobStore: jobStore,
                queue: queue.hooks,
                audioSource: { _ in SegmentAudio(wav: Data(repeating: 1, count: 64), sampleRateHz: 16_000) },
                bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
                nowMs: { 1 },
                cloudPrimary: { true }
            )
        }
    }

    /// Polls until `condition` holds (outcomes flow through the coordinator's consumer task
    /// asynchronously — the KMP test's `runCurrent()`).
    private func waitForUpload(
        timeoutMs: Int = 2_000,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while !condition() {
            if Date() > deadline {
                throw AssertionError("condition not met within \(timeoutMs) ms")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func openAiSingleShotUploadCompletesTranscript() async throws {
        let f = try Fixture(provider: .openAi)
        f.queue.enqueue("seg1")
        let consumer = await f.coordinator.start()
        defer { consumer.cancel() }

        try await f.coordinator.submitPending()
        #expect(f.queue.state("seg1") == .uploading)
        #expect(f.uploader.enqueued.count == 1)
        let bodyPath = try #require(f.uploader.enqueued.first?.bodyFilePath)
        #expect(FileManager.default.fileExists(atPath: bodyPath))

        f.uploader.deliver(
            CloudUploadOutcome(jobId: "seg1", httpStatus: 200, responseBody: "hello cloud")
        )
        try await waitForUpload { f.queue.state("seg1") == .complete }

        #expect(f.queue.transcript("seg1")?.text == "hello cloud")
        #expect(f.queue.transcript("seg1")?.modeUsed == .remoteOnly)
        #expect(f.jobStore.load(jobId: "seg1") == nil)
        #expect(!FileManager.default.fileExists(atPath: bodyPath))
    }

    @Test func sonioxUploadThenControlPlaneCompletesTranscript() async throws {
        let f = try Fixture(provider: .soniox)
        f.queue.enqueue("seg2")
        let consumer = await f.coordinator.start()
        defer { consumer.cancel() }

        try await f.coordinator.submitPending()
        f.uploader.deliver(
            CloudUploadOutcome(jobId: "seg2", httpStatus: 201, responseBody: #"{"id":"file-123"}"#)
        )
        try await waitForUpload { f.queue.state("seg2") == .complete }

        #expect(f.queue.transcript("seg2")?.text == "soniox file-123")
        #expect(f.queue.transcript("seg2")?.modeUsed == .remoteOnly)
        #expect(f.jobStore.load(jobId: "seg2") == nil)
    }

    @Test func failedUploadMarksTaskFailedRetryable() async throws {
        let f = try Fixture(provider: .openAi)
        f.queue.enqueue("seg3")
        let consumer = await f.coordinator.start()
        defer { consumer.cancel() }

        try await f.coordinator.submitPending()
        f.uploader.deliver(CloudUploadOutcome(jobId: "seg3", httpStatus: 0, error: "network lost"))
        try await waitForUpload { f.queue.state("seg3") == .failed }

        #expect(f.queue.retryable("seg3") == true)
        #expect(f.jobStore.load(jobId: "seg3") == nil)
    }
}
