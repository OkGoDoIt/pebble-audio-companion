import AppDB
import AudioCodec
import Foundation
import Testing

@testable import Transcription

// The safety net under Speex passthrough.
//
// Passthrough is a bet: neither provider documents Speex, both document `ogg` as a container, and
// ffmpeg has decoded Speex natively since 5.0. The bet is only defensible because losing it is
// cheap and automatic — one HTTP 400, one requeue, and that provider never sees Ogg again. These
// tests are the whole reason it is safe to take, so they are about the LOSING path far more than
// the winning one:
//
//  * which failures count as "this provider will not read that container" and, more importantly,
//    which ones must not (an expired key, a rate limit, a dead radio, a bad afternoon at the
//    backend — every one of those would otherwise cost the user 9x the bytes, permanently);
//  * that a rejection costs a requeue rather than a recording, and does not spend an attempt from
//    the eight-attempt retry budget;
//  * that the verdict survives a relaunch, because relearning it costs another failed upload.

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

/// A backend that echoes whatever container it is handed, so a test can see which rung was used.
private final class LadderCloud: TranscriptionProvider, CloudUploadCapable, @unchecked Sendable {
    let id = "soniox"
    let uploadFormatLadder: [CloudAudioFormat] = CloudUploadFormatPreference.ladder
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

/// In-memory queue behind `QueueHooks`, tracking attempts so the refund can be asserted.
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
            resetAbandonedUploads: { _, _ in [] },
            requeueWithoutAttempt: { [self] id in
                lock.withLock {
                    states[id] = .pending
                    attempts[id] = max(0, (attempts[id] ?? 0) - 1)
                }
            }
        )
    }
}

@Suite("PT — which failures mean 'I cannot read that container'")
struct PtFormatRejectionClassifierTests {
    /// The real body OpenAI returns for a container it will not take.
    private static let openAiFormatError = """
        {"error":{"message":"Invalid file format. Supported formats: ['flac', 'm4a', 'mp3', \
        'mp4', 'mpeg', 'mpga', 'oga', 'ogg', 'wav', 'webm']","type":"invalid_request_error"}}
        """

    @Test("415 is decisive on its own, for any container")
    func unsupportedMediaTypeIsDecisive() {
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .flac, httpStatus: 415, body: ""))
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 415, body: ""))
    }

    @Test("a documented container needs the body to actually say so")
    func documentedFormatsNeedEvidence() {
        // FLAC is listed by both vendors and has been accepted in production, so a bare 400 is
        // far likelier to be a malformed field than a codec objection.
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .flac, httpStatus: 400, body: Self.openAiFormatError))
        #expect(
            !CloudUploadFormatRejection.isFormatRejection(
                format: .flac, httpStatus: 400,
                body: #"{"error":{"message":"Invalid value for 'response_format'"}}"#))
        #expect(
            !CloudUploadFormatRejection.isFormatRejection(
                format: .flac, httpStatus: 400, body: "missing required parameter: model"))
    }

    @Test("an undocumented container is taken at face value on any remaining 4xx")
    func undocumentedFormatsBelieveAnyClientError() {
        // Nothing about an Ogg Speex request differs from a FLAC request the provider has already
        // accepted except the bytes, and the auth/limit/size codes are excluded below. Waiting for
        // wording we happened to anticipate would strand real recordings; falling to FLAC costs a
        // lossless 63% saving instead of a 96% one.
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 400, body: "something we have never seen"))
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 422, body: ""))
    }

    @Test("the failures that are never about the bytes are never treated as such")
    func unrelatedFailuresAreExcluded() {
        // The allowlist is {400, 406, 415, 422}; everything else is inadmissible even when the
        // body happens to contain words that look like a format complaint. The body text below is
        // deliberately the strongest possible false signal.
        let inadmissible = [
            401, 402, 403, 404, 405, 407, 408, 409, 410, 411, 412, 413, 414, 423, 428, 429, 431,
            451, 500, 502, 503, 504,
        ]
        for status in inadmissible {
            #expect(
                !CloudUploadFormatRejection.isFormatRejection(
                    format: .oggSpeex, httpStatus: status, body: "unsupported audio format"),
                "status \(status) must never downgrade a format")
            #expect(
                !CloudUploadFormatRejection.couldConcernThePayload(httpStatus: status),
                "status \(status) must not feed the backstop either")
        }
        // 413 deserves its own note: the body was too big, and every rung below is BIGGER, so a
        // downgrade would make the next attempt worse.
        #expect(
            !CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 413, body: "payload too large"))
    }

    @Test("WAV is the floor and can never be rejected")
    func wavIsNeverRejected() {
        #expect(
            !CloudUploadFormatRejection.isFormatRejection(
                format: .wav, httpStatus: 415, body: "unsupported format"))
    }

    @Test("a statusless provider complaint is judged on its wording alone")
    func statuslessComplaintsNeedWording() {
        // Soniox stores the file first and transcodes later, so its verdict arrives as a
        // transcription-level error message with no status attached.
        #expect(
            CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 0, body: "failed to decode audio stream"))
        #expect(
            !CloudUploadFormatRejection.isFormatRejection(
                format: .oggSpeex, httpStatus: 0, body: "internal error, please retry"))
    }

    @Test("a complaint is found through the error the provider actually throws")
    func complaintsSurviveTheErrorWrapping() {
        let wrapped = TranscriptionError.transcriptionFailed(
            "Soniox file upload failed (415): nope",
            underlying: CloudFormatComplaint(httpStatus: 415, evidence: "nope"))
        #expect(CloudUploadFormatRejection.complaint(in: wrapped)?.httpStatus == 415)
        #expect(CloudUploadFormatRejection.complaint(in: URLError(.timedOut)) == nil)
    }
}

@Suite("PT — the ladder and what it remembers")
struct PtFormatMemoryTests {
    @Test("the ladder walks down and always lands somewhere")
    func ladderResolves() {
        #expect(CloudUploadFormatPreference.resolve(rejected: []) == .oggSpeex)
        #expect(CloudUploadFormatPreference.resolve(rejected: [.oggSpeex]) == .flac)
        #expect(CloudUploadFormatPreference.resolve(rejected: [.oggSpeex, .flac]) == .wav)
        // Even a provider that has somehow refused everything gets the floor rather than nothing:
        // an upload with no format is not a state this pipeline has.
        #expect(CloudUploadFormatPreference.resolve(rejected: [.oggSpeex, .flac, .wav]) == .wav)
        #expect(CloudUploadFormatPreference.next(after: .oggSpeex) == .flac)
        #expect(CloudUploadFormatPreference.next(after: .flac) == .wav)
        #expect(CloudUploadFormatPreference.next(after: .wav) == nil)
    }

    @Test("a rejection survives a relaunch")
    func rejectionsArePersisted() throws {
        let root = try makeTempRoot("pt-format-memory")
        let store = CloudUploadFormatStore(root: root)
        #expect(store.rejectedFormats(.soniox).isEmpty)

        store.recordRejection(
            CloudFormatRejectionRecord(
                format: .oggSpeex, httpStatus: 400, evidence: "unsupported", recordedAtMs: 7),
            provider: .soniox)

        // A fresh instance on the same container is the relaunch: relearning this would cost
        // another failed upload of somebody's recording.
        let reopened = CloudUploadFormatStore(root: root)
        #expect(reopened.rejectedFormats(.soniox) == [.oggSpeex])
        #expect(reopened.rejections(.soniox).first?.httpStatus == 400)
        // Keyed per provider: switching backends must not inherit the other's verdict.
        #expect(reopened.rejectedFormats(.openAi).isEmpty)

        reopened.forget(.soniox)
        #expect(CloudUploadFormatStore(root: root).rejectedFormats(.soniox).isEmpty)
    }

    @Test("the backstop needs a run of failures, and any success clears it")
    func inconclusiveFailuresNeedARun() throws {
        let store = CloudUploadFormatStore(root: try makeTempRoot("pt-format-backstop"))
        #expect(!store.noteInconclusiveFailure(.soniox, format: .oggSpeex))
        #expect(!store.noteInconclusiveFailure(.soniox, format: .oggSpeex))
        store.noteSuccess(.soniox)
        // The run restarts: two failures either side of a working upload are not three in a row.
        #expect(!store.noteInconclusiveFailure(.soniox, format: .oggSpeex))
        #expect(!store.noteInconclusiveFailure(.soniox, format: .oggSpeex))
        #expect(store.noteInconclusiveFailure(.soniox, format: .oggSpeex))
    }

    @Test("recording a rejection is idempotent")
    func recordingTwiceChangesNothing() throws {
        let store = CloudUploadFormatStore(root: try makeTempRoot("pt-format-idempotent"))
        for status in [400, 415] {
            store.recordRejection(
                CloudFormatRejectionRecord(
                    format: .oggSpeex, httpStatus: status, evidence: "x", recordedAtMs: 1),
                provider: .openAi)
        }
        #expect(store.rejections(.openAi).count == 1)
        #expect(store.rejections(.openAi).first?.httpStatus == 400)
    }
}

@Suite("PT — a refused container costs a requeue, never a recording")
struct PtFormatDowngradeTests {
    private func makeCoordinator(
        queue: LadderQueue,
        uploader: LadderUploader,
        memory: any CloudUploadFormatMemory,
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
            formatMemory: memory,
            log: log)
    }

    @Test("the first upload is the passthrough, and a refusal moves the next one down a rung")
    func aRejectionDowngradesAndRetriesTheSameAudio() async throws {
        let root = try makeTempRoot("pt-downgrade")
        let queue = LadderQueue()
        queue.enqueue("seg-1")
        let uploader = LadderUploader()
        let memory = CloudUploadFormatStore(root: root)
        var lines: [String] = []
        let lock = NSLock()
        let coordinator = makeCoordinator(
            queue: queue, uploader: uploader, memory: memory, root: root,
            log: { line in lock.withLock { lines.append(line) } })

        try await coordinator.submitPending()
        #expect(uploader.enqueued.count == 1)
        #expect(queue.state("seg-1") == .uploading)
        #expect(queue.attemptCount("seg-1") == 1)

        await coordinator.onOutcome(
            CloudUploadOutcome(
                jobId: "seg-1", httpStatus: 400, responseBody: "unsupported audio format"))

        // NOT failed. The audio is fine; the envelope was wrong.
        #expect(queue.state("seg-1") == .pending)
        #expect(queue.failureMessages.isEmpty)
        // And the attempt is refunded, so a downgrade cannot eat into the retry budget.
        #expect(queue.attemptCount("seg-1") == 0)
        #expect(memory.rejectedFormats(.soniox) == [.oggSpeex])
        #expect(lock.withLock { lines }.contains { $0.contains("will not take oggSpeex") })

        // The next pass sends the identical recording one rung down, with no user involvement.
        try await coordinator.submitPending()
        #expect(uploader.enqueued.count == 2)
        let body = try String(
            decoding: Data(contentsOf: URL(fileURLWithPath: uploader.enqueued[1].bodyFilePath))
                .prefix(400), as: UTF8.self)
        #expect(body.contains("filename=\"segment.flac\""))
        #expect(body.contains("Content-Type: audio/flac"))
    }

    @Test("the first upload really is the passthrough container")
    func passthroughIsTheDefault() async throws {
        let root = try makeTempRoot("pt-default-format")
        let queue = LadderQueue()
        queue.enqueue("seg-1")
        let uploader = LadderUploader()
        let coordinator = makeCoordinator(
            queue: queue, uploader: uploader,
            memory: CloudUploadFormatStore(root: root), root: root)

        try await coordinator.submitPending()

        let body = try String(
            decoding: Data(contentsOf: URL(fileURLWithPath: uploader.enqueued[0].bodyFilePath))
                .prefix(400), as: UTF8.self)
        #expect(body.contains("filename=\"segment.ogg\""))
        #expect(body.contains("Content-Type: audio/ogg"))
        #expect(body.contains("OggS"))
    }

    @Test("an outage, a bad key and a rate limit all fail normally and teach nothing")
    func unrelatedFailuresDoNotDowngrade() async throws {
        for outcome in [
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 503, responseBody: "upstream down"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 401, responseBody: "invalid api key"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 429, responseBody: "slow down"),
            CloudUploadOutcome(jobId: "seg-1", httpStatus: 0, error: "network lost"),
        ] {
            let root = try makeTempRoot("pt-unrelated-\(outcome.httpStatus)")
            let queue = LadderQueue()
            queue.enqueue("seg-1")
            let memory = CloudUploadFormatStore(root: root)
            let coordinator = makeCoordinator(
                queue: queue, uploader: LadderUploader(), memory: memory, root: root)
            try await coordinator.submitPending()

            await coordinator.onOutcome(outcome)

            #expect(queue.state("seg-1") == .failed, "status \(outcome.httpStatus)")
            #expect(memory.rejectedFormats(.soniox).isEmpty, "status \(outcome.httpStatus)")
            // The attempt stands: this really was an attempt at transcribing the segment.
            #expect(queue.attemptCount("seg-1") == 1)
        }
    }

    @Test("a provider that refuses in words we did not anticipate is still escaped")
    func theBackstopEventuallyDowngrades() async throws {
        // The one hole a wording-based classifier leaves: a provider that says "internal error"
        // when it means "I cannot read this". Only failures that survived every exclusion are
        // counted — no transport errors, no 5xx, no auth, no rate limits — so this cannot be
        // driven by an outage or an expired key, and any success resets the run. Three delayed
        // segments is a far better outcome than a permanent failure loop over real recordings.
        let root = try makeTempRoot("pt-backstop")
        let memory = CloudUploadFormatStore(root: root)
        let queue = LadderQueue()
        let uploader = LadderUploader()
        let coordinator = BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: MuteControlPlaneCloud(), soniox: MuteControlPlaneCloud()),
            jobStore: CloudUploadJobStore(root: root),
            queue: queue.hooks,
            audioSource: { _, _ in
                SegmentAudio(
                    wav: PcmWav.encodeMono16(
                        pcm: Data((0..<32_000).map { UInt8(truncatingIfNeeded: $0 &* 37) }),
                        sampleRateHz: 16_000),
                    sampleRateHz: 16_000,
                    packaged: CloudAudioBody(bytes: Data("OggS".utf8), format: .oggSpeex))
            },
            bodyDir: root.appendingPathComponent("bodies", isDirectory: true),
            nowMs: { 42 },
            cloudPrimary: { true },
            formatMemory: memory)

        let runLength = CloudUploadFormatStore.consecutiveFailuresBeforeDowngrade
        for index in 1...runLength {
            let id = "seg-\(index)"
            queue.enqueue(id)
            try await coordinator.submitPending()
            await coordinator.onOutcome(
                CloudUploadOutcome(jobId: id, httpStatus: 200, responseBody: "{}"))
            let isLast = index == runLength
            #expect(
                memory.rejectedFormats(.soniox).isEmpty == !isLast,
                "downgraded after \(index) of \(runLength) unexplained failures")
            // Only the segment that triggered the downgrade is spared; the earlier ones failed
            // honestly, because at the time there was nothing to conclude.
            #expect(queue.state(id) == (isLast ? .pending : .failed))
        }
        #expect(memory.rejectedFormats(.soniox) == [.oggSpeex])
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

@Suite("PT — refunding the attempt a rejected container spent")
struct PtRequeueWithoutAttemptTests {
    @Test("the refund gives back exactly one attempt and nothing else")
    func refundIsPreciseRatherThanAReset() throws {
        let db = try AppDatabase.inMemory()
        let queue = TranscriptionQueue(database: db, nowMs: { 1_000 })
        _ = try queue.enqueue("seg-1")
        // Three real attempts already spent on this segment for unrelated reasons, then the
        // fourth hands it to the upload transport and the provider refuses the container.
        for _ in 0..<3 { _ = try queue.markRunning("seg-1") }
        _ = try queue.markFailed("seg-1", error: "network", retryable: true)
        _ = try queue.markUploading("seg-1")
        #expect(try queue.load("seg-1")?.attempts == 4)

        let refunded = try #require(try queue.requeueWithoutAttempt("seg-1"))

        #expect(refunded.state == .pending)
        #expect(refunded.retryable)
        #expect(refunded.lastError == nil)
        // Back to three, NOT to zero: `requeue` would forgive the failures this segment really
        // did accumulate, and the budget exists to bound genuinely broken work.
        #expect(refunded.attempts == 3)
    }

    @Test("a segment that has never been attempted cannot go negative")
    func refundIsClamped() throws {
        let db = try AppDatabase.inMemory()
        let queue = TranscriptionQueue(database: db, nowMs: { 1_000 })
        _ = try queue.enqueue("seg-1")
        #expect(try queue.requeueWithoutAttempt("seg-1")?.attempts == 0)
        #expect(try queue.requeueWithoutAttempt("missing") == nil)
    }
}

/// A backend whose control plane fails with a complaint nothing in `complaintPhrases` matches —
/// the case the run-length backstop exists for.
private final class MuteControlPlaneCloud: TranscriptionProvider, CloudUploadCapable,
    @unchecked Sendable
{
    let id = "soniox"
    let uploadFormatLadder: [CloudAudioFormat] = CloudUploadFormatPreference.ladder
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
        .needsControlPlane("file-1")
    }
    func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        throw TranscriptionError.transcriptionFailed(
            "Soniox transcription error: internal error",
            underlying: CloudFormatComplaint(httpStatus: 0, evidence: "internal error"))
    }
}
