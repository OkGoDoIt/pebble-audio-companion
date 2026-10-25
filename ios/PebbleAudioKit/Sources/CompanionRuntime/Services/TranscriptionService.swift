import AppDB
import Foundation
import Receiver
import SegmentStore
import Transcription

/// The transcription half of the pipeline: queue + processor + mode router + cloud health +
/// the background upload hand-off. Provider *selection* is settings-driven — the router reads
/// `settings.transcriptionMode` on every call, so a mode change takes effect on the next pass
/// without rebuilding anything.
public actor TranscriptionService {
    private let queue: TranscriptionQueue
    private let processor: TranscriptionProcessor
    private let transcriptStore: FileTranscriptStore
    private let store: SegmentStore
    private let database: AppDatabase
    private let cloudHealth: CloudHealthMonitor?
    private let connectivityCheck: (any CloudConnectivityCheck)?
    private let uploader: BackgroundCloudUploadCoordinator?
    private let modelLifecycle: (any LocalTranscriptionLifecycle)?
    /// The cloud backends and their shared account hold: probed on a schedule and by Test
    /// Connection so a paused account resumes by itself once it takes work again.
    private let cloudAccounts: SelectableCloudTranscriptionProvider?
    /// The words a surface shows for a stored failure message (the app's `Copy`), used where this
    /// service publishes to cloud health itself. Identity by default (tests).
    private let cloudFailureText: @Sendable (String) -> String
    private let settings: any RuntimeSettings
    private let clock: RuntimeClock
    private let log: RuntimeLog
    private var probingCloudAccount = false

    /// Serializes queue processing so the foreground loop and a triggered catch-up burst never
    /// run `processNext` concurrently on the shared (process-singleton) runtime.
    private var draining = false

    private var uploaderTask: Task<Void, Never>?

    public init(
        queue: TranscriptionQueue,
        processor: TranscriptionProcessor,
        transcriptStore: FileTranscriptStore,
        store: SegmentStore,
        database: AppDatabase,
        settings: any RuntimeSettings,
        clock: RuntimeClock,
        cloudHealth: CloudHealthMonitor? = nil,
        connectivityCheck: (any CloudConnectivityCheck)? = nil,
        uploader: BackgroundCloudUploadCoordinator? = nil,
        modelLifecycle: (any LocalTranscriptionLifecycle)? = nil,
        cloudAccounts: SelectableCloudTranscriptionProvider? = nil,
        cloudFailureText: @escaping @Sendable (String) -> String = { $0 },
        log: RuntimeLog = .silent
    ) {
        self.queue = queue
        self.processor = processor
        self.transcriptStore = transcriptStore
        self.store = store
        self.database = database
        self.settings = settings
        self.clock = clock
        self.cloudHealth = cloudHealth
        self.connectivityCheck = connectivityCheck
        self.uploader = uploader
        self.modelLifecycle = modelLifecycle
        self.cloudAccounts = cloudAccounts
        self.cloudFailureText = cloudFailureText
        self.log = log
    }

    // --- startup ------------------------------------------------------------------------------

    public func recoverOnStart() throws {
        try queue.recoverOnStart()
        let swept = ScratchFileSweep.run()
        if swept.files > 0 {
            log.write(
                "startup: removed \(swept.files) orphaned transcription scratch file(s), "
                    + "\(swept.bytes / 1_048_576) MB")
        }
        // Cloud health lives in memory; a hold outlives the process. Without this a relaunched
        // app shows a neutral cloud row for an account it is still refusing to send to.
        if let hold = heldCloudAccount() {
            cloudHealth?.reportImmediate(
                .failed(message: cloudFailureText(CloudAccountHold.pausedMessage(hold))))
        }
    }

    /// Starts the background-upload coordinator and re-attaches to uploads that may have finished
    /// while the process was suspended or terminated. Idempotent.
    public func startUploader() {
        guard let uploader, uploaderTask == nil else { return }
        uploaderTask = Task { await uploader.start().value }
        // Re-attach to uploads that may have completed while we were suspended or terminated.
        Task { await uploader.reconcile() }
    }

    public func stopUploader() {
        uploaderTask?.cancel()
        uploaderTask = nil
    }

    // --- pipeline steps -----------------------------------------------------------------------

    /// Segments parked while no provider was usable become eligible the moment one is (model
    /// downloaded, key added, mode changed). Returns true when anything changed.
    public func reconsiderDisabled(foreground: Bool = false) async throws -> Bool {
        // First, because a held cloud account that turns out to take work again is exactly what
        // un-parks the Disabled tasks below — in this same pass.
        await probeHeldCloudAccountIfDue(foreground: foreground)
        // Both kinds of parked work, in one stage, because they are the same question asked of two
        // states: is there anything we gave up on that could succeed now? `Disabled` is "no
        // provider was usable"; an exhausted `Failed` is "the provider was usable and the world
        // was not". The revival is time-gated, so running it on every pass costs a query.
        let unparked = try await processor.reconsiderDisabled().isEmpty == false
        let revived = try await reviveAbandonedFailures() > 0
        // Same question, third state: an upload the transport has quietly forgotten.
        await reconcileUploaderIfDue()
        return unparked || revived
    }

    /// The user just changed something that could fix a failure — a key, a provider, a mode, a
    /// model. Revive immediately rather than making them wait out the safety-net interval.
    public func reconsiderAfterConfigurationChange() async {
        do {
            _ = try await reviveAbandonedFailures(immediate: true)
        } catch {
            log.failure("revive after configuration change", error)
        }
    }

    /// Gives up-for-dead recordings another chance, so "everything is eventually transcribed" is
    /// a guarantee rather than a hope.
    ///
    /// A task stops retrying after eight attempts, and the backoff ladder reaches that in about an
    /// hour. That suits a burst of failures and badly misreads an OUTAGE: an hour on a plane, on
    /// the Underground, or with a key that expired overnight, and those recordings were dead with
    /// no automatic path back and no manual one either.
    ///
    /// Two cadences, because there are two different reasons a cause goes away:
    ///
    /// - `immediate` is the user fixing something — a new key, a different provider, a model that
    ///   finished downloading. They just acted; they should not wait hours to see it work.
    /// - Otherwise a slow sweep, so an outage that ended quietly (the phone found Wi-Fi at 3am)
    ///   still resolves itself without anyone doing anything.
    ///
    /// Only reasons that CAN go away are revived. Audio the provider refused, audio too long for
    /// it, and audio we cannot read are left failed: retrying those forever would spend battery
    /// and money on something that cannot succeed, and they stay visible in Diagnostics, which is
    /// the honest outcome.
    @discardableResult
    public func reviveAbandonedFailures(immediate: Bool = false) async throws -> Int {
        let revived = try queue.reviveExhausted(
            notAttemptedWithinMs: immediate ? 0 : Self.failureRevivalIntervalMs
        ) { task in
            TranscriptionFailureKind.classify(task.lastError).isWorthRevisiting
        }
        if !revived.isEmpty {
            log.write(
                "revived \(revived.count) abandoned transcription task(s)"
                    + (immediate ? " after a configuration change" : "")
            )
        }
        return revived.count
    }

    /// How long an exhausted task rests before the safety-net sweep tries it again. Long enough
    /// that a genuinely broken provider is not hammered, short enough that a day's recordings are
    /// never stranded overnight.
    static let failureRevivalIntervalMs: Int64 = 6 * 60 * 60 * 1000

    /// Enqueues every closed, not-yet-transcribed segment. Safe to call repeatedly.
    public func enqueueClosedSegments() async throws {
        let closed = await store.listSegments()
            // `frameCount > 0` is not fussiness: a segment with no audio cannot produce a
            // transcript, so enqueuing one buys a task that fails, retries its whole ladder, and
            // then sits in Diagnostics as a permanent failure — noise in exactly the list a person
            // reads when something is actually wrong. Segments open and close with no frames
            // routinely (a stream that starts and immediately drops), and three such phantoms were
            // already on the real device.
            .filter { !$0.isOpen && $0.frameCount > 0 }
        // "No speech" verdicts from before they named their author are heard again once — see
        // `TranscriptionQueue.requeueUnexplainedNoSpeech`. A query that finds nothing after the
        // first pass, because every verdict reached since carries its author.
        let requeued = try processor.requeueUnexplainedNoSpeech(
            among: Set(closed.map(\.segmentId)))
        if !requeued.isEmpty {
            log.write(
                "requeued \(requeued.count) \"no speech\" verdict(s) from before they were "
                    + "attributed; some were an interrupted model read as silence")
        }
        try processor.enqueueClosedSegments(
            closed.filter { !$0.isFullyTranscribed }.map(\.segmentId))
    }

    /// Drains the queue to exhaustion under the processing mutex. Returns true when at least one
    /// task advanced. `onAdvance` fires per task so diagnostics stay live during a long drain,
    /// and `shouldContinue` is asked before each task after the first: a drain that was allowed
    /// to start (the phone was on a charger) stops at the next task boundary once it no longer
    /// is. On 2026-09-18 a 21-segment local backlog kept a pass at 22 CPU-s/min for eight
    /// minutes after the cable came out, because the charger policy was only read at the top
    /// of the pass.
    @discardableResult
    public func drainQueue(
        shouldContinue: @Sendable () -> Bool = { true },
        isForeground: @Sendable () -> Bool = { false },
        onAdvance: @Sendable () async -> Void = {}
    ) async throws -> Bool {
        guard !draining else { return false }
        draining = true
        defer { draining = false }
        resetOrphanedRunningTasks()
        var processed = false
        while try await nextTaskAfterCheckingTheHold(foreground: isForeground()) != nil {
            processed = true
            await onAdvance()
            guard shouldContinue() else { break }
        }
        return processed
    }

    /// Advances at most `maxSegments` tasks (the BGProcessing / WorkManager catch-up shape).
    /// Cancellable; the caller owns model release.
    public func drainQueue(
        maxSegments: Int, onAdvance: @Sendable () async -> Void = {}
    ) async throws -> Int {
        guard !draining else { return 0 }
        draining = true
        defer { draining = false }
        resetOrphanedRunningTasks()
        var processed = 0
        while processed < maxSegments {
            try Task.checkCancellation()
            guard try await nextTaskAfterCheckingTheHold(foreground: false) != nil else { break }
            processed += 1
            await onAdvance()
        }
        return processed
    }

    /// One task, after a held cloud account's check if one is due.
    ///
    /// The check used to run only at the start of a pass and on the way into the background, and
    /// a drain is ONE stage that can run for hours over a backlog. On 2026-09-30 a raised Soniox
    /// limit sat unused while the on-device model worked through 245 queued segments: the
    /// on-screen check was due at 15:06 and ran at 15:11, when the app left the screen. Between
    /// segments it costs an in-memory comparison unless a check is actually due.
    private func nextTaskAfterCheckingTheHold(foreground: Bool) async throws
        -> TranscriptionTask?
    {
        await probeHeldCloudAccountIfDue(foreground: foreground)
        return try await processor.processNext()
    }

    public func nextRetryAtMs() throws -> Int64? {
        try processor.nextRetryAtMs()
    }

    /// Any task still `Running` when a drain starts is an orphan: this service's `draining` flag
    /// is the only way into the processor, and it is held right now. `processNext` puts an
    /// interrupted task back itself; this catches whatever else can leave one behind.
    private func resetOrphanedRunningTasks() {
        do {
            try queue.recoverOnStart()
        } catch {
            log.failure("queue orphan reset", error)
        }
    }

    // --- model residency ------------------------------------------------------------------------

    public func releaseModel(_ reason: String) async {
        await modelLifecycle?.releaseModel(reason: reason)
    }
    /// The soft release (see `LocalTranscriptionLifecycle.releaseModelWhenIdle`).
    public func releaseModelWhenIdle(_ reason: String) async {
        await modelLifecycle?.releaseModelWhenIdle(reason: reason)
    }


    public func releaseModelIfIdle(idleTimeoutMs: Int64) async {
        await modelLifecycle?.releaseModelIfIdle(nowMs: clock.nowMs, idleTimeoutMs: idleTimeoutMs)
    }

    // --- background hand-off --------------------------------------------------------------------

    /// Hands pending cloud-primary segments to the suspension-proof upload transport so they keep
    /// transcribing while the app is suspended. Called on background entry (app still alive) and
    /// in the BGProcessing window — never during a short Bluetooth wake.
    public func submitPendingToUploader() async {
        // The receive-only background pass is the only pass a phone off the charger runs, so a
        // held account is checked here too (on its schedule — normally a no-op).
        await probeHeldCloudAccountIfDue(foreground: false)
        guard let uploader, settings.cloudIsPrimaryTranscription else { return }
        do {
            try await uploader.submitPending()
        } catch is CancellationError {
        } catch {
            log.failure("upload submit", error)
        }
    }

    /// `handleEventsForBackgroundURLSession` — re-attach to whatever finished while suspended.
    public func reconcileUploader() async {
        await uploader?.reconcile()
    }

    /// Periodic re-attach, for the hole a long-lived process opens.
    ///
    /// `reconcile` otherwise runs only at launch, on a background-URLSession event, and when the
    /// supervisor escalates. That was enough when the app was short-lived; it now stays resident
    /// for days, so an upload that dies without ever producing a delegate callback would leave its
    /// task in `Uploading` — invisible, and never transcribed — until the next relaunch. This is
    /// time-gated and carries the registration grace, so it cannot race a submission in progress.
    public func reconcileUploaderIfDue() async {
        guard let uploader else { return }
        let now = clock.nowMs
        guard now - lastUploaderReconcileMs >= Self.uploaderReconcileIntervalMs else { return }
        lastUploaderReconcileMs = now
        await uploader.reconcile(
            registrationGraceMs: BackgroundCloudUploadCoordinator.uploadRegistrationGraceMs
        )
    }

    private var lastUploaderReconcileMs: Int64 = 0
    static let uploaderReconcileIntervalMs: Int64 = 15 * 60_000

    /// Un-stick the queue mid-session: tasks left `Running` by work that died, and uploads the
    /// transport no longer knows about, go back where they can be picked up again.
    ///
    /// This is exactly `recoverOnStart` + the uploader reconcile — repairs that existed but
    /// could only be reached by relaunching the app. `PipelineSupervisor` calls it when the
    /// drain stage has failed enough times that waiting longer has stopped being a plan; a
    /// drain that is merely idle never gets here, and a drain that is genuinely in flight is
    /// skipped outright, so no task is reset out from under work that is still doing it. (A
    /// drain WEDGED holding that mutex is the loop watchdog's problem, not this one's:
    /// cancelling the loop unwinds the task and releases it.)
    public func recoverStuckWork() async {
        guard !draining else { return }
        do { try queue.recoverOnStart() } catch { log.failure("queue recovery", error) }
        await uploader?.reconcile()
    }

    // --- user actions ----------------------------------------------------------------------------

    /// User-requested re-transcribe: forces the task back to Pending (clearing prior attempts and
    /// terminal state) so it re-runs under the CURRENT mode — e.g. upgrading an old on-device
    /// transcript to cloud accuracy. The existing transcript stays visible until replaced.
    /// No-op for the open segment.
    public func reprocessSegment(_ segmentId: String) async throws {
        guard let meta = await store.readMeta(segmentId), !meta.isOpen else { return }
        let names = try await LegacySpeakerMigration.anchorBeforeReprocessing(
            segmentId: segmentId, transcript: transcriptStore.loadWithoutWords(segmentId),
            database: database, nowMs: clock.nowMs)
        if names.unanchoredAssignments > 0 {
            log.write("retranscription: \(names.unanchoredAssignments) old speaker assignment(s) need review; no reliable audio range")
        }
        if try queue.requeue(segmentId) == nil {
            _ = try queue.enqueue(segmentId)
        }
        try await store.updateTranscriptionState(segmentId, .pending)
    }

    /// Authenticated probe against the selected cloud provider; publishes immediately to
    /// `cloudHealth` (an explicit Test Connection never waits for the 3-failure streak).
    ///
    /// A key check alone cannot say whether the account will pay for a transcription — Soniox's
    /// `GET /v1/transcriptions` answers 200 for an empty account — so once the key is accepted the
    /// account itself is checked with one second of silence (`probeAccount`). That is also what
    /// lifts a hold the moment the user has topped up, instead of at the next scheduled check.
    public func testCloudConnection() async {
        guard let connectivityCheck, let cloudHealth else { return }
        cloudHealth.reportChecking()
        let keyCheck = await connectivityCheck.checkConnectivity()
        guard case .ok = keyCheck, let cloudAccounts else {
            cloudHealth.reportImmediate(keyCheck)
            return
        }
        let provider = settings.cloudTranscriptionProvider
        switch await cloudAccounts.probeAccount(provider) {
        case .accepted, .inconclusive:
            // Inconclusive (offline mid-check, provider trouble) says nothing new about the
            // account; the key check's answer stands.
            cloudHealth.reportImmediate(keyCheck)
        case .refused:
            if let hold = cloudAccounts.hold?.active(for: provider) {
                cloudHealth.reportImmediate(
                    .failed(message: cloudFailureText(CloudAccountHold.pausedMessage(hold))))
            } else {
                cloudHealth.reportImmediate(keyCheck)
            }
        }
    }

    /// Checks a held cloud account when its schedule says to (see `CloudAccountHold`). Cheap and
    /// silent when nothing is held, which is always the ordinary case.
    public func probeHeldCloudAccountIfDue(foreground: Bool) async {
        guard let cloudAccounts, let hold = cloudAccounts.hold, settings.cloudTranscriptionEnabled
        else { return }
        let provider = settings.cloudTranscriptionProvider
        guard !probingCloudAccount, hold.isProbeDue(provider: provider, foreground: foreground)
        else { return }
        probingCloudAccount = true
        defer { probingCloudAccount = false }
        let outcome = await cloudAccounts.probeAccount(provider)
        switch outcome {
        case .accepted:
            cloudHealth?.reportImmediate(.ok(detail: nil))
        case .refused(let kind):
            let next = hold.active(for: provider).map { ($0.nextProbeAtMs - clock.nowMs) / 60_000 }
            log.write(
                "cloud: \(provider.rawValue) account check: still refused (\(kind.rawValue)); "
                    + "next check in \(next ?? 0) min")
        case .inconclusive(let why):
            log.write("cloud: \(provider.rawValue) account check inconclusive: \(why)")
        }
    }

    /// The hold in force for the selected provider, if any.
    public nonisolated func heldCloudAccount() -> CloudAccountHold.Hold? {
        guard let cloudAccounts, settings.cloudTranscriptionEnabled else { return nil }
        return cloudAccounts.hold?.active(for: settings.cloudTranscriptionProvider)
    }

    // --- queries -----------------------------------------------------------------------------

    public func allTasks() throws -> [TranscriptionTask] { try queue.all() }

    public func transcript(_ segmentId: String) -> SegmentTranscript? {
        transcriptStore.load(segmentId)
    }

    public func hasTranscript(_ segmentId: String) -> Bool {
        transcriptStore.load(segmentId) != nil
    }

    // --- cascade support ------------------------------------------------------------------------

    public func deleteTranscriptionData(_ segmentId: String) throws {
        try queue.delete(segmentId)
        try transcriptStore.delete(segmentId)
    }

    public func deleteAllTranscriptionData() throws {
        try queue.deleteAll()
        try transcriptStore.deleteAll()
    }

    /// Range-delete cascade: the words spoken in `mediaRangeMs` of this segment's stored audio
    /// leave its transcript, and cannot come back with a transcript that lands later
    /// (`FileTranscriptStore.redact`). The task's state is deliberately left alone: the turns
    /// that remain are timed on a clock the delete did not move, so a finished transcript is
    /// still the transcript of what is left, and re-running it would spend a transcription to
    /// arrive at the same turns.
    public func redactTranscript(_ segmentId: String, mediaRangeMs: Range<Int64>) throws {
        try transcriptStore.redact(segmentId, mediaRangeMs: mediaRangeMs)
    }

    /// Delete cascade: destroys the upload body staged for this segment, which holds its audio
    /// as it was when the body was assembled.
    ///
    /// A cloud-primary segment handed to the background transport sits on disk as
    /// `upload-bodies/<segmentId>.body` until the OS has finished with it — minutes on a good
    /// network, hours when the upload is waiting for Wi-Fi. Deleting the recording, or part of
    /// it, left that copy where it was.
    ///
    ///  - `forgetJob: true` — the whole segment is gone. The job record goes as well, which is
    ///    what makes the coordinator drop the upload's outcome when it arrives (it looks the
    ///    job up first) instead of saving a transcript for a recording that no longer exists.
    ///  - `forgetJob: false` — part of the segment was silenced. The job stays, so the outcome
    ///    is still handled: an upload that had not started fails for want of its body and is
    ///    retried from the silenced audio; one that was already on its way completes, and the
    ///    transcript it brings back is cut by the redaction in `FileTranscriptStore.save`.
    ///
    /// What this cannot do is recall an upload in flight: the transport has no cancel.
    ///
    /// The paths are derived from the segment store's root, which is the root the upload
    /// wiring stages under (`BackgroundUploadWiring.makeCoordinator(root:)`), and from the job
    /// record itself where there is one.
    public func discardStagedUpload(_ segmentId: String, forgetJob: Bool) {
        let root = store.rootURL
        let jobs = CloudUploadJobStore(root: root)
        var paths: Set<String> = [
            BackgroundCloudUploadCoordinator.defaultBodyDir(root: root)
                .appendingPathComponent("\(segmentId).body").path
        ]
        if let job = jobs.load(jobId: segmentId) { paths.insert(job.bodyFilePath) }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.removeItem(atPath: path) } catch {
                log.failure("staged upload delete", error)
            }
        }
        if forgetJob { jobs.delete(jobId: segmentId) }
    }
}

/// The sink to hand `TranscriptionModeRouter(onRemoteOutcome:)` when building the router.
///
/// Real transcription attempts and the explicit Test Connection share one health vocabulary, but
/// NOT one urgency: attempts go through `report` (3 consecutive failures before Failed surfaces —
/// the streaming paths self-heal, so a single blip is not worth alarming anyone about), while
/// `testCloudConnection` publishes immediately. `NotConfigured` always surfaces at once: no key is
/// not a transient failure.
public func cloudOutcomeSink(
    _ monitor: CloudHealthMonitor?
) -> @Sendable (CloudConnectivityResult) -> Void {
    { result in monitor?.report(result) }
}
