import AudioCodec
import Foundation
import Testing

@testable import Transcription

// What happens to a Pending cloud segment the background uploader CANNOT send.
//
// Both refusals used to `continue` silently, leaving the task Pending — which meant the very next
// background pass offered the same segment again, re-read the spool, re-ran the decode, and
// dropped it again. Forever, with nothing said anywhere, on a phone that is supposed to be asleep.
//
// The two refusals are not the same failure and do not get the same words:
//
//  - `audioSource` returned nil: no readable sidecar, or frames that will not decode. Failed with
//    a message `TranscriptionFailureKind` reads as `.audioUnreadable`.
//  - `uploadPlan` returned nil: the only reason left once `isAvailable()` has passed is the
//    provider's single-request size limit. Failed as `.recordingTooLong`.
//
// Both are marked RETRYABLE on purpose. Nothing on this path increments `attempts`, so the
// foreground processor still picks the task up through `nextRunnable` and runs it through the
// ordinary ladder — which is what keeps a sidecar that was merely unreadable before first unlock,
// or a segment the synchronous chunked path can still transcribe, from being killed off by a
// background pass. What changes is that the BACKGROUND pass stops reconsidering it, because
// `pendingSegmentIds` does not return Failed tasks.

private final class SilentUploader: BackgroundUploader, @unchecked Sendable {
    let outcomes: AsyncStream<CloudUploadOutcome>
    private let continuation: AsyncStream<CloudUploadOutcome>.Continuation
    private let lock = NSLock()
    private var recorded: [CloudUploadRequest] = []

    init() {
        (outcomes, continuation) = AsyncStream<CloudUploadOutcome>.makeStream(
            bufferingPolicy: .unbounded)
    }

    var enqueued: [CloudUploadRequest] { lock.withLock { recorded } }

    func enqueue(_ request: CloudUploadRequest) async {
        lock.withLock { recorded.append(request) }
    }

    func reconcile() async {}
    func inFlightJobIds() async -> Set<String> { [] }
}

/// A provider that plans an upload only when `plans` says so — the seam for "the body is over the
/// single-request limit", which is the only way a real `uploadPlan` can refuse once
/// `isAvailable()` has already answered the consent/key half of its own guard.
private final class PlanControlledProvider: TranscriptionProvider, CloudUploadCapable,
    @unchecked Sendable
{
    let id = "planner"
    private let plans: Bool

    init(plans: Bool) { self.plans = plans }

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        throw AssertionError("not used")
    }

    let uploadFormat: CloudAudioFormat = CloudUploadFormats.passthrough

    func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan? {
        guard plans else { return nil }
        return CloudUploadPlan(
            url: "https://provider/upload",
            file: MultipartBody.FilePart(
                name: "file", filename: audio.filename("s"), contentType: audio.contentType,
                bytes: audio.bytes
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

/// The queue contract this path touches, recorded rather than simulated: the assertions are about
/// WHICH transition happened and with what message.
private final class RecordingQueue: @unchecked Sendable {
    struct Failure: Equatable {
        let message: String
        let retryable: Bool
    }

    private let lock = NSLock()
    private var order: [String] = []
    private var terminal: Set<String> = []
    private var failures: [String: Failure] = [:]
    private var uploads: Set<String> = []
    private var noSpeech: Set<String> = []
    private var passes = 0

    func enqueue(_ segmentId: String) {
        lock.withLock {
            order.append(segmentId)
            terminal.remove(segmentId)
        }
    }

    func failure(_ segmentId: String) -> Failure? { lock.withLock { failures[segmentId] } }
    var uploaded: Set<String> { lock.withLock { uploads } }
    var settledAsNoSpeech: Set<String> { lock.withLock { noSpeech } }
    /// How many times the coordinator asked for the pending list — one per `submitPending`.
    var passCount: Int { lock.withLock { passes } }

    var hooks: BackgroundCloudUploadCoordinator.QueueHooks {
        BackgroundCloudUploadCoordinator.QueueHooks(
            pendingSegmentIds: { [self] in
                lock.withLock {
                    passes += 1
                    return order.filter { !terminal.contains($0) }
                }
            },
            uploadingSegmentIds: { [self] in lock.withLock { uploads } },
            isUploading: { [self] id in lock.withLock { uploads.contains(id) } },
            markUploading: { [self] id in
                lock.withLock {
                    uploads.insert(id)
                    terminal.insert(id)
                }
            },
            saveTranscript: { _, _, _ in },
            markComplete: { [self] id, _, _ in lock.withLock { _ = terminal.insert(id) } },
            markFailed: { [self] id, message, retryable in
                lock.withLock {
                    failures[id] = Failure(message: message, retryable: retryable)
                    terminal.insert(id)
                }
            },
            markNoSpeech: { [self] id, _ in
                lock.withLock {
                    noSpeech.insert(id)
                    terminal.insert(id)
                }
            },
            resetAbandonedUploads: { _, _ in [] }
        )
    }
}

@Suite("upload assembly outcomes") struct FLUploadAssemblyOutcomeTests {

    private func makeCoordinator(
        queue: RecordingQueue,
        plans: Bool = true,
        audio: @escaping @Sendable (String, CloudAudioFormat) async -> SegmentAudio?
    ) throws -> (BackgroundCloudUploadCoordinator, SilentUploader) {
        let root = try makeTempRoot("fl-upload-assembly")
        let uploader = SilentUploader()
        let coordinator = BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .openAi },
                openAi: PlanControlledProvider(plans: plans),
                soniox: PlanControlledProvider(plans: plans)
            ),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: audio,
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 1 },
            cloudPrimary: { true },
            // Off: this suite is about segments that never reach the gate, and a fixture whose
            // audio cannot be assembled has no energy profile to measure either.
            silenceFloorRms: nil
        )
        return (coordinator, uploader)
    }

    // MARK: - audioSource returned nil

    @Test func aSegmentWhoseAudioCannotBeAssembledIsFailedRatherThanReconsideredForever()
        async throws
    {
        let queue = RecordingQueue()
        queue.enqueue("broken")
        let (coordinator, uploader) = try makeCoordinator(queue: queue) { _, _ in nil }

        try await coordinator.submitPending()

        let failure = try #require(queue.failure("broken"))
        #expect(failure.retryable)
        #expect(uploader.enqueued.isEmpty)
        // Not silence. A gate that could not measure the audio must never claim nobody spoke.
        #expect(queue.settledAsNoSpeech.isEmpty)
        // `.audioUnreadable`, so the six-hourly revival sweep leaves the broken spool alone.
        #expect(TranscriptionFailureKind.classify(failure.message) == .audioUnreadable)
    }

    /// The actual cost being removed: the segment leaves the Pending list, so the next background
    /// pass does not re-read the spool and re-run the decode for it.
    @Test func aFailedAssemblyIsNotOfferedToTheNextPass() async throws {
        let queue = RecordingQueue()
        queue.enqueue("broken")
        let attempts = Counter()
        let (coordinator, _) = try makeCoordinator(queue: queue) { _, _ in
            attempts.increment()
            return nil
        }

        try await coordinator.submitPending()
        try await coordinator.submitPending()
        try await coordinator.submitPending()

        #expect(queue.passCount == 3)
        #expect(attempts.value == 1)
    }

    /// One broken segment must not stop the healthy ones behind it in the same pass.
    @Test func healthySegmentsInTheSamePassStillUpload() async throws {
        let queue = RecordingQueue()
        queue.enqueue("broken")
        queue.enqueue("good")
        let (coordinator, uploader) = try makeCoordinator(queue: queue) { segmentId, _ in
            segmentId == "good" ? uploadableAudio() : nil
        }

        try await coordinator.submitPending()

        #expect(queue.failure("broken") != nil)
        #expect(queue.uploaded == ["good"])
        #expect(uploader.enqueued.map(\.jobId) == ["good"])
    }

    // MARK: - uploadPlan returned nil

    @Test func aBodyOverTheProvidersLimitIsFailedAsRecordingTooLong() async throws {
        let queue = RecordingQueue()
        queue.enqueue("huge")
        let (coordinator, uploader) = try makeCoordinator(queue: queue, plans: false) { _, _ in
            uploadableAudio()
        }

        try await coordinator.submitPending()

        let failure = try #require(queue.failure("huge"))
        #expect(failure.retryable)
        #expect(uploader.enqueued.isEmpty)
        #expect(TranscriptionFailureKind.classify(failure.message) == .recordingTooLong)
    }
}

/// A body the coordinator will happily package and hand to the transport.
private func uploadableAudio() -> SegmentAudio {
    SegmentAudio(wav: Data(repeating: 1, count: 64), sampleRateHz: 16_000)
}

/// Minimal thread-safe counter — the audio source is `@Sendable` and called from the actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
