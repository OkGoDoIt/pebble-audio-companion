import Foundation

// Port of `core/transcription/.../BackgroundCloudUploadCoordinator.kt`.

/// A segment's audio ready to upload: WAV bytes plus the sample rate they were encoded at.
public struct SegmentAudio: Sendable {
    public let wav: Data
    public let sampleRateHz: Int

    public init(wav: Data, sampleRateHz: Int) {
        self.wav = wav
        self.sampleRateHz = sampleRateHz
    }
}

/// Drives durable, suspension-proof cloud transcription uploads.
///
/// It coordinates three durable pieces: the transcription queue (the `Uploading` task state is
/// the coordination token so the synchronous processor never double-runs an in-flight segment),
/// the `jobStore` (transport + control-plane state across process death), and the `uploader`
/// transport. Provider specifics live behind `CloudUploadCapable`, so this class is
/// provider-agnostic and handles both single-shot (OpenAI: the response is the transcript) and
/// upload-then-control-plane (Soniox: the upload yields a file id; create/poll/fetch run when
/// next awake) shapes.
///
/// The queue and transcript store are injected as closures (`QueueHooks`) rather than concrete
/// types so this layer stays decoupled from the queue implementation; the app runtime adapts
/// `FileTranscriptionQueue`/`FileTranscriptStore` onto the hooks.
///
/// It runs only for cloud-primary modes (`cloudPrimary`); LocalFirst keeps its synchronous
/// local-then-cloud fallback untouched. The local path is never affected.
public actor BackgroundCloudUploadCoordinator {
    /// The narrow queue/transcript-store seam the coordinator drives.
    public struct QueueHooks: Sendable {
        /// Segment ids of Pending tasks, in queue order.
        public var pendingSegmentIds: @Sendable () async -> [String]
        /// Segment ids currently in the Uploading state (feeds the concurrency budget).
        public var uploadingSegmentIds: @Sendable () async -> Set<String>
        /// Whether the task for this segment is currently in the Uploading state.
        public var isUploading: @Sendable (_ segmentId: String) async -> Bool
        /// Moves the task to Uploading (the durable coordination token).
        public var markUploading: @Sendable (_ segmentId: String) async -> Void
        /// Durably saves the transcript. ALWAYS called before `markComplete` (durability order:
        /// transcript-save before completion, so a crash never yields a Complete task without a
        /// transcript).
        public var saveTranscript:
            @Sendable (_ segmentId: String, _ result: TranscriptionResult, _ modeUsed: TranscriptionMode)
                async -> Void
        /// Marks the task Complete with provenance (modeUsed / providerId / modelUsed).
        public var markComplete:
            @Sendable (_ segmentId: String, _ result: TranscriptionResult, _ modeUsed: TranscriptionMode)
                async -> Void
        /// Marks the task Failed (retryable) with a user-diagnosable message.
        public var markFailed:
            @Sendable (_ segmentId: String, _ message: String, _ retryable: Bool) async -> Void
        /// Marks the task NoSpeech (terminal, not a failure).
        public var markNoSpeech: @Sendable (_ segmentId: String) async -> Void
        /// `FileTranscriptionQueue.resetAbandonedUploads`: Uploading tasks whose job id is NOT in
        /// the transport's in-flight set go back to Pending; returns the reset segment ids.
        public var resetAbandonedUploads: @Sendable (_ inFlight: Set<String>) async -> [String]

        public init(
            pendingSegmentIds: @escaping @Sendable () async -> [String],
            uploadingSegmentIds: @escaping @Sendable () async -> Set<String>,
            isUploading: @escaping @Sendable (String) async -> Bool,
            markUploading: @escaping @Sendable (String) async -> Void,
            saveTranscript: @escaping @Sendable (String, TranscriptionResult, TranscriptionMode)
                async -> Void,
            markComplete: @escaping @Sendable (String, TranscriptionResult, TranscriptionMode)
                async -> Void,
            markFailed: @escaping @Sendable (String, String, Bool) async -> Void,
            markNoSpeech: @escaping @Sendable (String) async -> Void,
            resetAbandonedUploads: @escaping @Sendable (Set<String>) async -> [String]
        ) {
            self.pendingSegmentIds = pendingSegmentIds
            self.uploadingSegmentIds = uploadingSegmentIds
            self.isUploading = isUploading
            self.markUploading = markUploading
            self.saveTranscript = saveTranscript
            self.markComplete = markComplete
            self.markFailed = markFailed
            self.markNoSpeech = markNoSpeech
            self.resetAbandonedUploads = resetAbandonedUploads
        }
    }

    public static let defaultMaxConcurrentUploads = 4

    /// Where the app runtime keeps pre-assembled multipart bodies (`<root>/upload-bodies/`,
    /// matching the KMP iOS runtime). Injected so tests can redirect it.
    public static func defaultBodyDir(root: URL) -> URL {
        root.appendingPathComponent("upload-bodies", isDirectory: true)
    }

    private let uploader: any BackgroundUploader
    private let cloudProvider: SelectableCloudTranscriptionProvider
    private let jobStore: CloudUploadJobStore
    private let queue: QueueHooks
    private let audioSource: @Sendable (_ segmentId: String) async -> SegmentAudio?
    private let bodyDir: URL
    private let nowMs: @Sendable () -> Int64
    private let cloudPrimary: @Sendable () -> Bool
    private let maxConcurrentUploads: Int

    public init(
        uploader: any BackgroundUploader,
        cloudProvider: SelectableCloudTranscriptionProvider,
        jobStore: CloudUploadJobStore,
        queue: QueueHooks,
        audioSource: @escaping @Sendable (_ segmentId: String) async -> SegmentAudio?,
        bodyDir: URL,
        nowMs: @escaping @Sendable () -> Int64,
        cloudPrimary: @escaping @Sendable () -> Bool,
        maxConcurrentUploads: Int = BackgroundCloudUploadCoordinator.defaultMaxConcurrentUploads
    ) {
        self.uploader = uploader
        self.cloudProvider = cloudProvider
        self.jobStore = jobStore
        self.queue = queue
        self.audioSource = audioSource
        self.bodyDir = bodyDir
        self.nowMs = nowMs
        self.cloudPrimary = cloudPrimary
        self.maxConcurrentUploads = maxConcurrentUploads
    }

    /// Starts consuming upload outcomes (including ones delivered after a relaunch).
    public func start() -> Task<Void, Never> {
        let outcomes = uploader.outcomes
        return Task { [weak self] in
            for await outcome in outcomes {
                guard let self else { return }
                await self.onOutcome(outcome)
            }
        }
    }

    /// Re-attach to in-flight uploads after a (re)launch and finish any deferred control planes.
    public func reconcile() async {
        await uploader.reconcile()
        let inFlight = await uploader.inFlightJobIds()
        _ = await queue.resetAbandonedUploads(inFlight)
        for job in jobStore.all() where job.phase == .awaitingControlPlane {
            await runControlPlane(job)
        }
        // Drop orphaned job records (no Uploading task and not in flight or awaiting control
        // plane).
        for job in jobStore.all() {
            let live = inFlight.contains(job.jobId) || job.phase == .awaitingControlPlane
            if !live, await !queue.isUploading(job.jobId) {
                cleanup(job)
            }
        }
    }

    /// Hands eligible Pending cloud segments to the background uploader, up to the concurrency
    /// cap.
    public func submitPending() async throws {
        guard cloudPrimary() else { return }
        guard let capable = cloudProvider.activeUploadCapable else { return }
        guard await cloudProvider.isAvailable() else { return }
        var budget = max(0, maxConcurrentUploads - (await queue.uploadingSegmentIds()).count)
        if budget == 0 { return }
        for segmentId in await queue.pendingSegmentIds() {
            if budget == 0 { break }
            guard let audio = await audioSource(segmentId) else { continue }
            guard let plan = await capable.uploadPlan(wav: audio.wav, sampleRateHz: audio.sampleRateHz)
            else { continue }
            try await enqueueUpload(segmentId: segmentId, plan: plan)
            budget -= 1
        }
    }

    private func enqueueUpload(segmentId: String, plan: CloudUploadPlan) async throws {
        try FileManager.default.createDirectory(at: bodyDir, withIntermediateDirectories: true)
        let bodyURL = bodyDir.appendingPathComponent("\(segmentId).body")
        let contentType = try MultipartBody.writeTo(
            fileURL: bodyURL,
            boundary: "PebbleAudioBoundary-\(segmentId)",
            textFields: plan.textFields,
            file: plan.file
        )
        jobStore.save(
            CloudUploadJob(
                jobId: segmentId,
                provider: cloudProvider.selectedProvider(),
                phase: .uploading,
                bodyFilePath: bodyURL.path,
                createdAtMs: nowMs()
            )
        )
        await queue.markUploading(segmentId)
        var headers = plan.headers
        headers["Content-Type"] = contentType
        await uploader.enqueue(
            CloudUploadRequest(
                jobId: segmentId,
                url: plan.url,
                headers: headers,
                bodyFilePath: bodyURL.path
            )
        )
    }

    func onOutcome(_ outcome: CloudUploadOutcome) async {
        guard let job = jobStore.load(jobId: outcome.jobId) else { return }
        deleteBody(job) // the transport is done with the body file either way
        guard outcome.isSuccess else {
            await fail(job, outcome.error ?? "upload failed (\(outcome.httpStatus))")
            return
        }
        guard let capable = cloudProvider.capable(job.provider) else {
            await fail(job, "cloud provider \(job.provider.rawValue) unavailable")
            return
        }
        do {
            switch try await capable.onUploadResponse(
                httpStatus: outcome.httpStatus, body: outcome.responseBody
            ) {
            case .done(let result):
                await complete(job, result)
            case .needsControlPlane(let controlState):
                var updated = job
                updated.phase = .awaitingControlPlane
                updated.sonioxFileId = controlState
                jobStore.save(updated)
                await runControlPlane(updated)
            }
        } catch {
            await handleStepError(error, job: job, fallbackMessage: "upload processing failed")
        }
    }

    private func runControlPlane(_ job: CloudUploadJob) async {
        guard let capable = cloudProvider.capable(job.provider) else {
            await fail(job, "cloud provider \(job.provider.rawValue) unavailable")
            return
        }
        guard let controlState = job.sonioxFileId else {
            await fail(job, "missing control-plane state")
            return
        }
        do {
            await complete(job, try await capable.completeControlPlane(controlState: controlState))
        } catch {
            await handleStepError(error, job: job, fallbackMessage: "control plane failed")
        }
    }

    private func handleStepError(_ error: Error, job: CloudUploadJob, fallbackMessage: String) async {
        if error is CancellationError { return }
        if case TranscriptionError.noSpeechDetected = error {
            await noSpeech(job)
            return
        }
        await fail(job, errorMessage(error) ?? fallbackMessage)
    }

    private func complete(_ job: CloudUploadJob, _ result: TranscriptionResult) async {
        // Durability order: transcript save BEFORE marking the task complete. Background uploads
        // are always cloud-primary, so provenance is honest RemoteOnly.
        await queue.saveTranscript(job.jobId, result, .remoteOnly)
        await queue.markComplete(job.jobId, result, .remoteOnly)
        cleanup(job)
    }

    private func fail(_ job: CloudUploadJob, _ message: String) async {
        await queue.markFailed(job.jobId, message, true)
        cleanup(job)
    }

    private func noSpeech(_ job: CloudUploadJob) async {
        await queue.markNoSpeech(job.jobId)
        cleanup(job)
    }

    private func cleanup(_ job: CloudUploadJob) {
        deleteBody(job)
        jobStore.delete(jobId: job.jobId)
    }

    private func deleteBody(_ job: CloudUploadJob) {
        try? FileManager.default.removeItem(atPath: job.bodyFilePath)
    }

    private func errorMessage(_ error: Error) -> String? {
        // Same stored shape the foreground processor writes, so one taxonomy classifies both:
        // a `URLError` keeps its numeric code, not only its translated sentence.
        if error is URLError { return storedFailureMessage(error) }
        if case TranscriptionError.transcriptionFailed(let message, _) = error { return message }
        if case TranscriptionError.providerUnavailable(let providerId) = error {
            return "provider unavailable: \(providerId)"
        }
        return (error as NSError).localizedDescription
    }
}
