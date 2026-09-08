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
    private let cloudHealth: CloudHealthMonitor?
    private let connectivityCheck: (any CloudConnectivityCheck)?
    private let uploader: BackgroundCloudUploadCoordinator?
    private let modelLifecycle: (any LocalTranscriptionLifecycle)?
    private let settings: any RuntimeSettings
    private let clock: RuntimeClock
    private let log: RuntimeLog

    /// Serializes queue processing so the foreground loop and a triggered catch-up burst never
    /// run `processNext` concurrently on the shared (process-singleton) runtime.
    private var draining = false

    private var uploaderTask: Task<Void, Never>?

    public init(
        queue: TranscriptionQueue,
        processor: TranscriptionProcessor,
        transcriptStore: FileTranscriptStore,
        store: SegmentStore,
        settings: any RuntimeSettings,
        clock: RuntimeClock,
        cloudHealth: CloudHealthMonitor? = nil,
        connectivityCheck: (any CloudConnectivityCheck)? = nil,
        uploader: BackgroundCloudUploadCoordinator? = nil,
        modelLifecycle: (any LocalTranscriptionLifecycle)? = nil,
        log: RuntimeLog = .silent
    ) {
        self.queue = queue
        self.processor = processor
        self.transcriptStore = transcriptStore
        self.store = store
        self.settings = settings
        self.clock = clock
        self.cloudHealth = cloudHealth
        self.connectivityCheck = connectivityCheck
        self.uploader = uploader
        self.modelLifecycle = modelLifecycle
        self.log = log
    }

    // --- startup ------------------------------------------------------------------------------

    public func recoverOnStart() throws {
        try queue.recoverOnStart()
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
    public func reconsiderDisabled() async throws -> Bool {
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
        let ids = await store.listSegments()
            .filter { !$0.isOpen && !$0.isFullyTranscribed }
            .map(\.segmentId)
        try processor.enqueueClosedSegments(ids)
    }

    /// Drains the queue to exhaustion under the processing mutex. Returns true when at least one
    /// task advanced. `onAdvance` fires per task so diagnostics stay live during a long drain.
    @discardableResult
    public func drainQueue(onAdvance: @Sendable () async -> Void = {}) async throws -> Bool {
        guard !draining else { return false }
        draining = true
        defer { draining = false }
        var processed = false
        while try await processor.processNext() != nil {
            processed = true
            await onAdvance()
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
        var processed = 0
        while processed < maxSegments {
            try Task.checkCancellation()
            guard try await processor.processNext() != nil else { break }
            processed += 1
            await onAdvance()
        }
        return processed
    }

    public func nextRetryAtMs() throws -> Int64? {
        try processor.nextRetryAtMs()
    }

    // --- model residency ------------------------------------------------------------------------

    public func releaseModel(_ reason: String) async {
        await modelLifecycle?.releaseModel(reason: reason)
    }

    public func releaseModelIfIdle(idleTimeoutMs: Int64) async {
        await modelLifecycle?.releaseModelIfIdle(nowMs: clock.nowMs, idleTimeoutMs: idleTimeoutMs)
    }

    // --- background hand-off --------------------------------------------------------------------

    /// Hands pending cloud-primary segments to the suspension-proof upload transport so they keep
    /// transcribing while the app is suspended. Called on background entry (app still alive) and
    /// in the BGProcessing window — never during a short Bluetooth wake.
    public func submitPendingToUploader() async {
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
        if try queue.requeue(segmentId) == nil {
            _ = try queue.enqueue(segmentId)
        }
        try await store.updateTranscriptionState(segmentId, .pending)
    }

    /// Authenticated probe against the selected cloud provider; publishes immediately to
    /// `cloudHealth` (an explicit Test Connection never waits for the 3-failure streak).
    public func testCloudConnection() async {
        guard let connectivityCheck, let cloudHealth else { return }
        cloudHealth.reportChecking()
        cloudHealth.reportImmediate(await connectivityCheck.checkConnectivity())
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
