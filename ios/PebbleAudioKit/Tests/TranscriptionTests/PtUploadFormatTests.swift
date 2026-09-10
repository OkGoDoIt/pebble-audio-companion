import AppDB
import AudioCodec
import Foundation
import Testing

@testable import Transcription

// What the app uploads, and what it does when that is refused.
//
// The container is a CONSTANT per provider (`CloudUploadFormats`), verified against both
// production endpoints on 2026-09-08. It was briefly learned at runtime instead: the app uploaded
// as Ogg Speex, classified failures, and durably recorded "this provider will not take this
// container" so later uploads stepped down a ladder. On 2026-09-10 a Soniox balance ran dry, three
// consecutive uploads failed with "Organization balance exhausted", and the mechanism's
// three-strike backstop read that as three unexplained container failures and permanently retired
// Ogg Speex — a silent, durable 9x bandwidth regression caused by an unpaid invoice.
//
// So these tests are about the property that replaced it: NOTHING a provider says changes what the
// app uploads next. A failure is a failure — the audio is untouched, the segment is retried on the
// ordinary ladder, and the next upload is the same container as the last one. If a provider ever
// genuinely stops reading Ogg Speex, that surfaces as a visible, correctly-attributed failure and
// a human changes the constant.

private final class LadderUploader: BackgroundUploader, @unchecked Sendable {
    let outcomes: AsyncStream<CloudUploadOutcome>
    private let continuation: AsyncStream<CloudUploadOutcome>.Continuation
    private let lock = NSLock()
    private var recorded: [CloudUploadRequest] = []

    init() { (outcomes, continuation) = AsyncStream<CloudUploadOutcome>.makeStream() }

    var enqueued: [CloudUploadRequest] { lock.withLock { recorded } }
    func enqueue(_ request: CloudUploadRequest) async { lock.withLock { recorded.append(request) } }
    func reconcile() async {}
    func inFlightJobIds() async -> Set<String> { [] }
    func finish() { continuation.finish() }
}

/// A backend that echoes whatever container it is handed, so a test can see what was sent.
private final class LadderCloud: TranscriptionProvider, CloudUploadCapable, @unchecked Sendable {
    let id = "soniox"
    let uploadFormat: CloudAudioFormat = CloudUploadFormats.passthrough
    func isAvailable() async -> Bool { true }
    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult { throw AssertionError("not used") }
    func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan? {
        CloudUploadPlan(
            url: "https://provider.invalid/files",
            file: MultipartBody.FilePart(
                name: "file", filename: audio.filename("segment"),
                contentType: audio.contentType, bytes: audio.bytes))
    }
    func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        .done(TranscriptionResult(text: body, providerId: id, modelUsed: "m"))
    }
    func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        throw AssertionError("no control plane")
    }
}

/// In-memory queue behind `QueueHooks`, tracking attempts so a failure can be asserted.
private final class LadderQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var states: [String: TaskState] = [:]
    private(set) var attempts: [String: Int] = [:]
    private(set) var failures: [String] = []

    func enqueue(_ segmentId: String) {
        lock.withLock {
            if states[segmentId] == nil {
                order.append(segmentId)
                attempts[segmentId] = 0
            }
            states[segmentId] = .pending
        }
    }
    func state(_ id: String) -> TaskState? { lock.withLock { states[id] } }
    func attemptCount(_ id: String) -> Int { lock.withLock { attempts[id] ?? 0 } }
    var failureMessages: [String] { lock.withLock { failures } }

    var hooks: BackgroundCloudUploadCoordinator.QueueHooks {
        BackgroundCloudUploadCoordinator.QueueHooks(
            pendingSegmentIds: { [self] in lock.withLock { order.filter { states[$0] == .pending } } },
            uploadingSegmentIds: { [self] in
                lock.withLock { Set(order.filter { states[$0] == .uploading }) }
            },
            isUploading: { [self] id in lock.withLock { states[id] == .uploading } },
            markUploading: { [self] id in
                lock.withLock {
                    states[id] = .uploading
                    // Mirrors `TranscriptionQueue.markUploading`: handing a segment to the
                    // transport spends an attempt.
                    attempts[id, default: 0] += 1
                }
            },
            saveTranscript: { _, _, _ in },
            markComplete: { [self] id, _, _ in lock.withLock { states[id] = .complete } },
            markFailed: { [self] id, message, _ in
                lock.withLock {
                    states[id] = .failed
                    failures.append(message)
                }
            },
            markNoSpeech: { [self] id in lock.withLock { states[id] = .noSpeech } },
            resetAbandonedUploads: { _, _ in [] }
        )
    }
}


@Suite("PT — the container is a constant, not a negotiation")
struct PtUploadFormatConstantTests {
    private func makeCoordinator(
        queue: LadderQueue,
        uploader: LadderUploader,
        root: URL,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> BackgroundCloudUploadCoordinator {
        BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: LadderCloud(), soniox: LadderCloud()),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: { _, format in
                // Speech-level PCM so the silence gate never fires, plus a packaged body when the
                // coordinator asks for passthrough — the shape the real audio source produces.
                let pcm = Data((0..<32_000).map { UInt8(truncatingIfNeeded: $0 &* 37) })
                if format == .oggSpeex {
                    let frames = (0..<50).map { i in
                        Data((0..<25).map { UInt8(truncatingIfNeeded: i &* 13 &+ $0) })
                    }
                    return SegmentAudio(
                        wav: Data(), sampleRateHz: 16_000,
                        packaged: try? CloudAudioBody.passthrough(
                            speexFrames: frames, sampleRateHz: 16_000, frameSamples: 320,
                            bitRateBps: 9_800),
                        energy: SegmentEnergy.profile(
                            pcmChunks: [pcm], sampleRateHz: 16_000))
                }
                return SegmentAudio(
                    wav: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: 16_000), sampleRateHz: 16_000)
            },
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 42 },
            cloudPrimary: { true },
            log: log)
    }

    private func uploadedBody(_ request: CloudUploadRequest) throws -> String {
        String(
            decoding: try Data(contentsOf: URL(fileURLWithPath: request.bodyFilePath)).prefix(400),
            as: UTF8.self)
    }

    @Test("both providers declare the measured container, and it is the same one")
    func providersDeclareTheVerifiedConstant() {
        #expect(SonioxTranscriptionProvider.uploadFormat == CloudUploadFormats.passthrough)
        #expect(OpenAiTranscriptionProvider.uploadFormat == CloudUploadFormats.passthrough)
        #expect(CloudUploadFormats.passthrough == .oggSpeex)
        // The synchronous path is handed decoded PCM and so can never package the watch's frames.
        #expect(SonioxTranscriptionProvider.pcmFormat == .flac)
        #expect(OpenAiTranscriptionProvider.pcmFormat == .flac)
    }

    @Test("the upload really is the passthrough container")
    func passthroughIsWhatGoesOut() async throws {
        let root = try makeTempRoot("pt-default-format")
        let queue = LadderQueue()
        queue.enqueue("seg-1")
        let uploader = LadderUploader()
        let coordinator = makeCoordinator(queue: queue, uploader: uploader, root: root)

        try await coordinator.submitPending()

        let body = try uploadedBody(uploader.enqueued[0])
        #expect(body.contains("filename=\"segment.ogg\""))
        #expect(body.contains("Content-Type: audio/ogg"))
        #expect(body.contains("OggS"))
    }

    // The 2026-09-10 incident, pinned. Both strings are verbatim from the phone that hit it.
    @Test("a run of billing failures does not change what the next upload is")
    func aBillingOutageNeverChangesTheContainer() async throws {
        let root = try makeTempRoot("pt-billing")
        let queue = LadderQueue()
        let uploader = LadderUploader()
        let coordinator = makeCoordinator(queue: queue, uploader: uploader, root: root)
        let billing =
            "Organization balance exhausted. Please either add funds manually or enable autopay."

        // Three in a row — exactly what tripped the old three-strike backstop.
        for index in 1...3 {
            let segmentId = "seg-\(index)"
            queue.enqueue(segmentId)
            try await coordinator.submitPending()
            await coordinator.onOutcome(
                CloudUploadOutcome(jobId: segmentId, httpStatus: 0, responseBody: billing))
            #expect(queue.state(segmentId) == .failed, "attempt \(index)")
        }

        // The fourth upload is still Ogg Speex. Nothing was learned, because nothing about the
        // audio was ever in question.
        queue.enqueue("seg-4")
        try await coordinator.submitPending()
        let body = try uploadedBody(uploader.enqueued.last!)
        #expect(body.contains("filename=\"segment.ogg\""))
        #expect(body.contains("Content-Type: audio/ogg"))
    }

    @Test("even a real container refusal fails loudly rather than changing the next upload")
    func aContainerRefusalIsLoudNotAdaptive() async throws {
        // The case the ladder existed for. It now costs a visible failure and a human decision,
        // not a silent permanent regime change — and crucially the AUDIO is never lost: the
        // segment is Failed, which the retry ladder revisits.
        let root = try makeTempRoot("pt-real-refusal")
        let queue = LadderQueue()
        queue.enqueue("seg-1")
        let uploader = LadderUploader()
        let coordinator = makeCoordinator(queue: queue, uploader: uploader, root: root)
        try await coordinator.submitPending()

        await coordinator.onOutcome(
            CloudUploadOutcome(
                jobId: "seg-1", httpStatus: 415, responseBody: "unsupported media type"))
        #expect(queue.state("seg-1") == .failed)

        queue.enqueue("seg-2")
        try await coordinator.submitPending()
        let body = try uploadedBody(uploader.enqueued.last!)
        #expect(body.contains("Content-Type: audio/ogg"), "the constant is not touched at runtime")
    }

    @Test("an outage, a bad key and a rate limit all fail normally")
    func unrelatedFailuresFailNormally() async throws {
        for outcome in [
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 503, responseBody: "upstream down"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 401, responseBody: "invalid api key"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 429, responseBody: "slow down"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 0, error: "network lost"),
        ] {
            let root = try makeTempRoot("pt-unrelated-\(outcome.httpStatus)")
            let queue = LadderQueue()
            queue.enqueue("seg-1")
            let coordinator = makeCoordinator(
                queue: queue, uploader: LadderUploader(), root: root)
            try await coordinator.submitPending()

            await coordinator.onOutcome(outcome)

            #expect(queue.state("seg-1") == .failed, "status \(outcome.httpStatus)")
            // The attempt stands: this really was an attempt at transcribing the segment.
            #expect(queue.attemptCount("seg-1") == 1)
        }
    }

    @Test("passthrough does not smuggle a segment past the silence gate")
    func theSilenceGateStillRunsOnThePassthroughPath() async throws {
        // Passthrough removes the decode that existed to BUILD an upload, not the decode the gate
        // needs. The audio source measures the profile while streaming and hands it over; the
        // gate makes the identical verdict it always did, and nothing quiet is ever uploaded.
        let root = try makeTempRoot("pt-passthrough-gate")
        let queue = LadderQueue()
        queue.enqueue("quiet-1")
        queue.enqueue("loud-1")
        let uploader = LadderUploader()
        let coordinator = BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: LadderCloud(), soniox: LadderCloud()),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: { segmentId, _ in
                // Room tone at RMS ~8, well under the RMS 32 floor, versus ordinary speech level.
                let level = segmentId.hasPrefix("quiet") ? 8 : 3_000
                var pcm = Data()
                for index in 0..<(16_000 * 3) {
                    let sample = Int16(index % 2 == 0 ? level : -level)
                    pcm.append(UInt8(truncatingIfNeeded: sample))
                    pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
                }
                return SegmentAudio(
                    wav: Data(), sampleRateHz: 16_000,
                    packaged: CloudAudioBody(bytes: Data("OggS".utf8), format: .oggSpeex),
                    energy: SegmentEnergy.profile(pcmChunks: [pcm], sampleRateHz: 16_000))
            },
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 42 },
            cloudPrimary: { true })

        try await coordinator.submitPending()

        #expect(queue.state("quiet-1") == .noSpeech)
        #expect(uploader.enqueued.map(\.jobId) == ["loud-1"])
    }
}
