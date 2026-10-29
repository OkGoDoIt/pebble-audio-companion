import AudioCodec
import Foundation

// Port of `core/transcription/.../BackgroundCloudUploadCoordinator.kt`.

/// A segment's audio ready to upload, in whichever container the coordinator asked for.
///
/// Two shapes, and which one arrives depends on the format the coordinator resolved BEFORE asking
/// (see `submitPending`):
///
///  - **PCM rungs** (`.flac`, `.wav`): `wav` holds the assembled RIFF/WAVE body and `packaged` is
///    nil. The provider encodes from it. This is what shipped before passthrough.
///  - **Passthrough** (`.oggSpeex`): `packaged` holds the finished Ogg and `wav` is EMPTY. The
///    audio source never materialised a WAV, because on that path nothing needs the samples —
///    which is the entire point (a 15-minute segment is 1.18 MB here instead of 28.9 MB, and the
///    28.9 MB `Data` was being held inside a background window with a jetsam ceiling).
///
/// `energy` is carried rather than recomputed. The silence gate needs decoded PCM, and after
/// passthrough the gate is the ONLY reason anything is decoded at all — so the audio source
/// measures it on the way past and hands the answer over, instead of the coordinator decoding a
/// second time to ask. Nil means "measure it from `wav`", which is what the PCM rungs and every
/// existing test do.
public struct SegmentAudio: Sendable {
    /// Assembled PCM/WAV body, or empty on the passthrough path.
    public let wav: Data
    public let sampleRateHz: Int
    /// Already-encoded upload body, when the audio source packaged one itself.
    public let packaged: CloudAudioBody?
    /// Energy of the decoded audio, measured during the decode the audio source already ran.
    public let energy: SegmentEnergyProfile?

    public init(
        wav: Data,
        sampleRateHz: Int,
        packaged: CloudAudioBody? = nil,
        energy: SegmentEnergyProfile? = nil
    ) {
        self.wav = wav
        self.sampleRateHz = sampleRateHz
        self.packaged = packaged
        self.energy = energy
    }

    /// The bytes to upload in `format`, encoding from `wav` when the audio source did not already
    /// package something.
    ///
    /// Never fails: `CloudAudioBody.encode` degrades to WAV rather than dropping a segment, and a
    /// `packaged` body is returned as-is even if it is not the requested format — the audio source
    /// already resolved that.
    ///
    /// Passthrough with nothing packaged means the audio source could not build a container for
    /// this segment (empty frames, or a frame size the Ogg mapping cannot carry) and fell back to
    /// decoding. Asking for `.oggSpeex` from PCM would then silently produce WAV, skipping the
    /// lossless rung that is perfectly available — so it resolves to `.flac` instead. A remux
    /// failure should cost 4% of the saving, not 96% of it.
    public func body(
        for format: CloudAudioFormat,
        onFallback: ((Error) -> Void)? = nil
    ) -> CloudAudioBody {
        if let packaged { return packaged }
        // Speex cannot be produced from decoded PCM, so a passthrough request that arrives here
        // with no packaged body falls to the PCM container.
        let fromPcm = format == .oggSpeex ? CloudUploadFormats.fromPcm : format
        return CloudAudioBody.encode(
            wav: wav, sampleRateHz: sampleRateHz, format: fromPcm, onFallback: onFallback)
    }

    /// The silence gate's input: the pre-measured profile, or one taken from `wav`.
    ///
    /// `floorRms` only scales the diagnostic `bucketsAboveFloor`; the verdict itself is made on
    /// `loudestWindowRms`, which is floor-independent — so a profile measured elsewhere with the
    /// default floor gives the identical answer here.
    public func energyProfile(floorRms: Double) -> SegmentEnergyProfile {
        energy ?? SegmentEnergy.profile(wav: wav, sampleRateHz: sampleRateHz, floorRms: floorRms)
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
        /// Marks the task NoSpeech (terminal, not a failure), naming who decided it.
        public var markNoSpeech: @Sendable (_ segmentId: String, _ decidedBy: String) async -> Void
        /// `FileTranscriptionQueue.resetAbandonedUploads`: Uploading tasks whose job id is NOT in
        /// the transport's in-flight set go back to Pending; returns the reset segment ids.
        /// `graceMs` is a registration grace — see `TranscriptionQueue.resetAbandonedUploads`.
        public var resetAbandonedUploads:
            @Sendable (_ inFlight: Set<String>, _ graceMs: Int64) async -> [String]

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
            markNoSpeech: @escaping @Sendable (String, String) async -> Void,
            resetAbandonedUploads: @escaping @Sendable (Set<String>, Int64) async -> [String]
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
    /// Asked for a specific container, so the passthrough path can skip materialising a WAV
    /// nothing on it would read. See `SegmentAudio`.
    private let audioSource:
        @Sendable (_ segmentId: String, _ format: CloudAudioFormat) async -> SegmentAudio?
    /// Diagnostics sink for a decision the user never sees: which container a segment went up in.
    private let log: @Sendable (String) -> Void
    private let bodyDir: URL
    private let nowMs: @Sendable () -> Int64
    private let cloudPrimary: @Sendable () -> Bool
    /// How long a freshly-submitted upload is left alone before `reconcile` may consider it
    /// abandoned. Covers the window between the queue being marked `Uploading` and the transport
    /// registering the URLSession task, in which the job is in neither set.
    public static let uploadRegistrationGraceMs: Int64 = 5 * 60_000

    private let maxConcurrentUploads: Int

    /// Submitting and reconciling each read what the transport holds and act on it across several
    /// awaits, and actor isolation does not stop them interleaving at those awaits. Interleaved, a
    /// reconcile cleaned up a job a submission had saved but not yet marked `Uploading`, deleting
    /// the body URLSession was handed next; URLSession raised "Cannot read file" and the app died
    /// (2026-10-29, woken in the background with the phone locked). So they take turns.
    private var transportBusy = false
    private var transportWaiters: [CheckedContinuation<Void, Never>] = []

    /// Loudest-second RMS below which a segment is settled as `.noSpeech` instead of uploaded,
    /// or nil to disable the check. See `SegmentEnergy.provableSilenceFloorRms`.
    private let silenceFloorRms: Double?

    public init(
        uploader: any BackgroundUploader,
        cloudProvider: SelectableCloudTranscriptionProvider,
        jobStore: CloudUploadJobStore,
        queue: QueueHooks,
        audioSource: @escaping @Sendable (_ segmentId: String, _ format: CloudAudioFormat) async ->
            SegmentAudio?,
        bodyDir: URL,
        nowMs: @escaping @Sendable () -> Int64,
        cloudPrimary: @escaping @Sendable () -> Bool,
        maxConcurrentUploads: Int = BackgroundCloudUploadCoordinator.defaultMaxConcurrentUploads,
        silenceFloorRms: Double? = SegmentEnergy.provableSilenceFloorRms,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.uploader = uploader
        self.cloudProvider = cloudProvider
        self.jobStore = jobStore
        self.queue = queue
        self.audioSource = audioSource
        self.log = log
        self.bodyDir = bodyDir
        self.nowMs = nowMs
        self.cloudPrimary = cloudPrimary
        self.maxConcurrentUploads = maxConcurrentUploads
        self.silenceFloorRms = silenceFloorRms
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
    /// Re-attaches to whatever the transport actually has, and returns anything it does not to
    /// `Pending`.
    ///
    /// `registrationGraceMs` defaults to zero, which is right at LAUNCH: the session has just been
    /// restored, it knows every task it owns, and nothing has been submitted in this process yet,
    /// so an `Uploading` task missing from its in-flight set is definitively abandoned and should
    /// come back immediately. A PERIODIC reconcile needs the grace instead, because it can land in
    /// the window between marking a task `Uploading` and the transport registering it.
    public func reconcile(registrationGraceMs: Int64 = 0) async {
        await takeTransportTurn()
        defer { endTransportTurn() }
        await uploader.reconcile()
        let inFlight = await uploader.inFlightJobIds()
        _ = await queue.resetAbandonedUploads(inFlight, registrationGraceMs)
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
        await sweepOrphanedBodies(inFlight: inFlight, graceMs: registrationGraceMs)
    }

    /// Deletes staged multipart bodies that no job record refers to any more.
    ///
    /// `cleanup` removes the body and then the job record, so anything that drops the record by
    /// another route — or a process death between the two writes — leaves a body behind that
    /// NOTHING will ever look at again. They are not small: on a real device this had accumulated
    /// seven files totalling 160 MB, the oldest more than two months old, against 780 MB of actual
    /// audio. Retention cannot help, because it sweeps the segment store and has never known this
    /// directory exists.
    ///
    /// Keyed off the filename, which is `<segmentId>.body`, so a body is orphaned exactly when its
    /// segment has no job, is not in flight, and is not marked `Uploading`. The modification-time
    /// grace covers the window in `enqueueUpload` between writing the body and saving the job.
    private func sweepOrphanedBodies(inFlight: Set<String>, graceMs: Int64) async {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: bodyDir, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        let known = Set(jobStore.all().map(\.jobId))
        // Deliberately the REAL clock, not the injected `nowMs`: the value it is compared against
        // is a filesystem modification date, which the filesystem stamps from the real clock. A
        // cutoff derived from injected time would be comparing two different clocks, which is
        // wrong in production the moment they diverge and silently untestable besides.
        let cutoff = Date().addingTimeInterval(-Double(graceMs) / 1000)
        for file in files where file.pathExtension == "body" {
            let segmentId = file.deletingPathExtension().lastPathComponent
            if known.contains(segmentId) || inFlight.contains(segmentId) { continue }
            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            guard modified <= cutoff else { continue }
            if await queue.isUploading(segmentId) { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// Hands eligible Pending cloud segments to the background uploader, up to the concurrency
    /// cap.
    public func submitPending() async throws {
        guard cloudPrimary() else { return }
        await takeTransportTurn()
        defer { endTransportTurn() }
        // An account that has refused (402/401/403) gets nothing new — every segment sent to it
        // would be encoded and uploaded in full only to be refused. See `CloudAccountHold`.
        guard !cloudProvider.isSendingHeld else { return }
        guard let capable = cloudProvider.activeUploadCapable else { return }
        guard await cloudProvider.isAvailableForBackgroundUpload() else { return }
        var budget = max(0, maxConcurrentUploads - (await queue.uploadingSegmentIds()).count)
        if budget == 0 { return }
        // A constant for this provider, and what the audio source is told to produce.
        let format = capable.uploadFormat
        for segmentId in await queue.pendingSegmentIds() {
            if budget == 0 { break }
            guard let audio = await audioSource(segmentId, format) else {
                await failUnassembled(segmentId)
                continue
            }
            // The last point at which this audio is still on the device. A segment that
            // demonstrably contains no voice is settled here rather than uploaded, so the user
            // neither pays for it nor receives the sentences a provider invents out of room tone.
            // Terminal `.noSpeech`, not a failure: the audio stays in the spool and the transcript
            // view shows the span as quiet. See `SegmentEnergy.provableSilenceFloorRms`.
            //
            // Passthrough does NOT skip this. It removes the decode that existed to build an
            // upload, not the decode this gate needs — the audio source still decodes, streaming,
            // and hands the profile over in `SegmentAudio.energy` so the samples are read once and
            // never assembled.
            if let silenceFloorRms {
                let profile = audio.energyProfile(floorRms: silenceFloorRms)
                if profile.isProvablySilent(floorRms: silenceFloorRms) {
                    await queue.markNoSpeech(
                        segmentId,
                        SegmentEnergy.silenceVerdict(
                            loudestWindowRms: profile.loudestWindowRms, floorRms: silenceFloorRms))
                    continue
                }
            }
            let body = audio.body(for: format)
            guard let plan = await capable.uploadPlan(audio: body, sampleRateHz: audio.sampleRateHz)
            else {
                // The provider declined to plan this segment. `uploadPlan` refuses for exactly two
                // reasons — no consent/key, and a body over its single-request limit — and those
                // two want opposite outcomes, so they are told apart rather than lumped together.
                //
                // The consent/key half is a CONFIGURATION problem and must stay Pending: the very
                // next pass sends it once a key is back. `isAvailable()` is literally that same
                // predicate and was checked at the top of this pass, so the only way it is the
                // reason is a settings change landing mid-pass — which is why it is re-asked here,
                // on the refusal path only, where the ordinary pass never pays for it.
                //
                // What is left is the size limit, which is a property of the audio and will not
                // change on its own: the ladder only ever downgrades to LARGER containers, so a
                // body too big at this rung is too big at every rung below it. That gets a
                // terminal state instead of being re-offered every pass forever — retryable,
                // because the foreground processor CAN still transcribe it (the synchronous path
                // chunks segments the single-request API will not take), with the message
                // `TranscriptionFailureKind` reads as `.recordingTooLong`, which the safety-net
                // sweep leaves alone and Diagnostics shows.
                //
                // Unreachable at passthrough's 4% of the WAV and comfortable at FLAC's ~31%; it
                // would only come back if BOTH rungs were refused and a long segment fell all the
                // way to raw WAV.
                log("no upload plan for \(segmentId) as \(body.format.rawValue) (\(body.bytes.count) bytes)")
                guard await cloudProvider.isAvailableForBackgroundUpload() else { continue }
                await queue.markFailed(
                    segmentId,
                    "upload body of \(body.bytes.count) bytes as \(body.format.rawValue) exceeds "
                        + "the provider's single-request limit",
                    true
                )
                continue
            }
            try await enqueueUpload(segmentId: segmentId, plan: plan, format: body.format)
            budget -= 1
        }
    }

    /// A Pending segment whose audio could not be assembled at all.
    ///
    /// `audioSource` returns nil for a segment with no readable metadata sidecar, or whose frames
    /// will not decode to anything — see `BackgroundUploadWiring.audioSource`. Both used to
    /// `continue`, which left the task Pending, which meant the very next background pass picked
    /// the same segment up, re-read the spool, re-attempted the decode, and dropped it again.
    /// Forever, invisibly, and at the cost of a full decode per pass on a phone that is supposed
    /// to be asleep. (`TranscriptionService.enqueueClosedSegments` already refuses to enqueue a
    /// zero-frame segment, so this is genuinely broken or missing audio, not an empty recording.)
    ///
    /// The honest outcome is `Failed`, not `NoSpeech`: the gate that claims silence refuses to do
    /// so from audio it could not measure (`TranscriptionProcessor.provablySilent` "fails OPEN"),
    /// and inferring "nobody spoke" from a decode failure would render a hole in the record as
    /// calm quiet — the one conflation this product does not make.
    ///
    /// Retryable, and that is what keeps a TRANSIENT failure transient. Nothing here increments
    /// `attempts` (only `markRunning`/`markUploading` do), so the task stays eligible: the
    /// foreground processor's `nextRunnable` picks up a retryable failure once the backoff has
    /// elapsed and runs it through the ordinary ladder, where a sidecar that was merely unreadable
    /// before first unlock succeeds and a genuinely corrupt segment exhausts its eight attempts and
    /// settles. What it does NOT do any more is sit in the background pass's Pending list, because
    /// `pendingSegmentIds` does not return Failed tasks — which is the whole point.
    ///
    /// The wording matters: `TranscriptionFailureKind.classify` reads "failed to read audio" as
    /// `.audioUnreadable`, whose `isWorthRevisiting` is false, so the six-hourly revival sweep
    /// leaves it alone rather than re-decoding a broken spool file twice a day.
    /// No `log` call of its own: `markFailed` is the hook that already writes the user's only
    /// window onto a background upload that died (`BackgroundUploadWiring.queueHooks`), and it
    /// writes this message verbatim.
    private func failUnassembled(_ segmentId: String) async {
        await queue.markFailed(
            segmentId, "failed to read audio for \(segmentId) (no metadata, or it did not decode)",
            true
        )
    }

    private func enqueueUpload(
        segmentId: String, plan: CloudUploadPlan, format: CloudAudioFormat
    ) async throws {
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
                createdAtMs: nowMs(),
                // Recorded so the outcome — which arrives in a later process, after a relaunch,
                // with nothing else in scope — can be attributed to the container that produced it.
                uploadFormat: format
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
        if case TranscriptionError.noSpeechDetected(let reason) = error {
            // Real speech-free audio, not a container problem: the provider read the file.
            await noSpeech(job, reason: "\(job.provider.rawValue): \(reason)")
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
        cloudProvider.noteSuccess(provider: job.provider)
    }

    private func fail(_ job: CloudUploadJob, _ message: String) async {
        await queue.markFailed(job.jobId, message, true)
        cleanup(job)
        // A refusal about the ACCOUNT stops every other upload to it, not just this one.
        cloudProvider.noteFailureMessage(message, provider: job.provider)
    }

    private func noSpeech(_ job: CloudUploadJob, reason: String) async {
        await queue.markNoSpeech(job.jobId, reason)
        cleanup(job)
    }

    private func takeTransportTurn() async {
        guard transportBusy else {
            transportBusy = true
            return
        }
        await withCheckedContinuation { transportWaiters.append($0) }
    }

    private func endTransportTurn() {
        if transportWaiters.isEmpty {
            transportBusy = false
        } else {
            transportWaiters.removeFirst().resume()
        }
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
