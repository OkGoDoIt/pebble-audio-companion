import AppDB
import Foundation
import Intelligence
import LiveAudio
import Receiver
import SearchKit
import SegmentStore
import StatusUI
import Transcription
import WireProtocol

// The composition root. The KMP original was a 55-parameter god object that owned the receiver,
// the queue, the AI layer, the live audio, the UI's read model and the lifecycle at once. Here
// each of those is its own service and this type only WIRES them and owns the loop.
//
// Nothing in this file makes a policy decision: the order lives in `PipelinePass`, the startup
// order in `StartupSequencer`, the cascades in `DeleteCascade`, the notification rules in
// `LossEventEvaluator`.

/// Everything the runtime needs, already constructed. The app builds this once at launch.
public struct CompanionRuntimeEnvironment: Sendable {
    public var database: AppDatabase
    public var store: SegmentStore
    public var retention: RetentionManager
    public var settings: any RuntimeSettings
    public var clock: RuntimeClock

    public var receiver: ReceiverService
    public var transcription: TranscriptionService
    public var enrichment: EnrichmentService
    public var recap: RecapService
    public var live: LiveAudioService
    public var diagnostics: DiagnosticsService
    public var library: LibraryStore
    public var cascade: DeleteCascade
    public var deferredDeletes: DeferredDeleteBuffer
    public var startup: StartupSequencer
    public var snapshots: CoverageSnapshotService
    /// Shared foreground/catch-up policy — the pass and diagnostics read the same object.
    public var foreground: RuntimeForegroundState
    public var log: RuntimeLog

    public init(
        database: AppDatabase,
        store: SegmentStore,
        retention: RetentionManager,
        settings: any RuntimeSettings,
        clock: RuntimeClock,
        receiver: ReceiverService,
        transcription: TranscriptionService,
        enrichment: EnrichmentService,
        recap: RecapService,
        live: LiveAudioService,
        diagnostics: DiagnosticsService,
        library: LibraryStore,
        cascade: DeleteCascade,
        deferredDeletes: DeferredDeleteBuffer,
        startup: StartupSequencer,
        snapshots: CoverageSnapshotService,
        foreground: RuntimeForegroundState = RuntimeForegroundState(),
        log: RuntimeLog = .silent
    ) {
        self.database = database
        self.store = store
        self.retention = retention
        self.settings = settings
        self.clock = clock
        self.receiver = receiver
        self.transcription = transcription
        self.enrichment = enrichment
        self.recap = recap
        self.live = live
        self.diagnostics = diagnostics
        self.library = library
        self.cascade = cascade
        self.deferredDeletes = deferredDeletes
        self.startup = startup
        self.snapshots = snapshots
        self.foreground = foreground
        self.log = log
    }
}

/// The runtime the app talks to.
public actor CompanionRuntime {
    public let environment: CompanionRuntimeEnvironment
    private let wake: WakeChannel
    private let foreground: RuntimeForegroundState
    private let clock: RuntimeClock
    private let log: RuntimeLog

    private var loopTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    private var stageObserver: (@Sendable (PipelineStage) -> Void)?
    /// Which parts of the processing pass are actually working. Written by the pass, read by
    /// Diagnostics and by the supervisor that acts on it.
    private let health: PipelineHealthMonitor
    /// Retention with its own pacing, built from the environment's manager + cascade so no caller
    /// has to re-derive "enforce, then cascade over everything it evicted" a fourth time.
    private let retention: RetentionService

    public init(
        environment: CompanionRuntimeEnvironment,
        wake: WakeChannel = WakeChannel(),
        onStage: (@Sendable (PipelineStage) -> Void)? = nil
    ) {
        self.environment = environment
        self.wake = wake
        self.clock = environment.clock
        self.log = environment.log
        self.foreground = environment.foreground
        self.stageObserver = onStage
        self.health = PipelineHealthMonitor(
            nowMs: { [clock = environment.clock] in clock.nowMs }, log: environment.log)
        self.retention = RetentionService(
            enforce: { limit in try await environment.retention.enforce(limit: limit) },
            cascadeDeleted: { _ = await environment.cascade.deleteSegment($0) },
            policy: { environment.settings.retentionConfig },
            clock: environment.clock,
            log: environment.log
        )
    }

    // --- published surfaces --------------------------------------------------------------------

    public nonisolated var receiverState: StateSubject<ReceiverSessionState> {
        environment.receiver.state
    }
    public nonisolated var watchServiceState: StateSubject<Int?> {
        environment.receiver.watchServiceState
    }
    /// What still backs the `.streaming` latch (see `Receiver.StreamEvidence`). The status layer
    /// weighs this instead of trusting the latch, so "Recording" is never asserted about a watch
    /// that stopped sending without a clean stop.
    public nonisolated var streamEvidence: StateSubject<StreamEvidence> {
        environment.receiver.streamEvidence
    }
    /// The bound watch's advertised name, or nil until one has been seen.
    public nonisolated var deviceName: StateSubject<String?> { environment.receiver.deviceName }
    /// The watch's last Info read (handshake, and again after an enable prompt). Diagnostics
    /// only — it carries the firmware version and the send-backpressure counter, which is how
    /// the app tells airtime loss apart from a spool that never freed.
    public nonisolated var orphanedFrameCount: StateSubject<Int> {
        environment.receiver.orphanedFrameCount
    }
    public nonisolated var watchInfo: StateSubject<InfoSnapshot?> {
        environment.receiver.watchInfo
    }
    public nonisolated var diagnostics: StateSubject<RuntimeDiagnostics> {
        environment.diagnostics.snapshot
    }
    /// Per-stage health of the processing pass: what ran, what threw, what is backed off, and
    /// whether the loop is still turning. The Diagnostics screen renders it; the status layer
    /// asks it whether transcription is quietly broken.
    public nonisolated var pipelineHealth: PipelineHealthMonitor { health }
    public nonisolated var library: LibraryStore { environment.library }
    /// Exposed for the one thing a screen legitimately triggers directly: a person overruling
    /// the automatic grouping. Grouping is derived, so their decision is invisible until it is
    /// recomputed, and waiting for the next scheduled pass would look like a switch that does
    /// nothing for several minutes.
    public nonisolated var enrichment: EnrichmentService { environment.enrichment }
    public nonisolated var captureIntent: CaptureIntent { environment.receiver.captureIntent }
    public nonisolated var isForeground: Bool { foreground.value }

    /// Wakes the pipeline early. Every settings change that could unblock work calls this —
    /// that is what makes pacing event-driven rather than poll-driven.
    public nonisolated func notifyConfigChanged() {
        wake.signal()
        // A settings change is the most common way a failure's CAUSE gets fixed — a new key, a
        // different provider, a model that finished downloading. Recordings that were given up on
        // should come back now, not in six hours.
        Task { await environment.transcription.reconsiderAfterConfigurationChange() }
    }

    // --- lifecycle -----------------------------------------------------------------------------

    /// Startup: run the recovery order (which runs the legacy import first), start the receiver
    /// when the user's intent says to, then start the processing loop.
    public func start() async {
        // THE VERY FIRST THING, ahead of every disk read. Bringing the radio up is seconds of
        // round trips — connect, discover, subscribe — and none of it needs the database, the
        // store or the recovery sweep. Dialling here overlaps that latency with the disk work
        // below instead of queueing behind it, which on a background launch is the difference
        // between a link that is ready when the wake budget runs out and one that never started.
        // It cannot prompt the watch: only an explicit enable request does that (plan 4.2).
        if environment.settings.captureIntent != .off {
            environment.receiver.dialLink()
            // Residency before recovery, so a headless launch is not suspended in the middle of
            // it — see `ReceiverService.holdResidencyThroughStartup`. Detached: activating the
            // audio session takes up to 1.6 s on the phone, and neither recovery nor the receiver
            // waits for that; it lands in parallel, well inside the wake budget.
            let receiver = environment.receiver
            Task.detached(priority: .userInitiated) { receiver.holdResidencyThroughStartup() }
        }
        let startedAtMs = clock.nowMs
        var lastStepMs = startedAtMs
        // Every step between "process alive" and "receiver started" is a step during which the
        // watch is capturing audio nobody is storing. The flight recorder therefore gets the cost
        // of each one, so that the next stall is measured rather than reasoned about.
        func noteStep(_ name: String) {
            let now = clock.nowMs
            log.write("startup: \(name) took \(now - lastStepMs) ms (\(now - startedAtMs) ms in)")
            lastStepMs = now
        }

        // The first coverage snapshot, early and OFF the receiver's path. Until this file exists
        // every widget on the Home Screen shows its "no data yet" state, and recovery on a
        // migrated container takes tens of seconds — so it is written concurrently rather than
        // after recovery. It used to be awaited HERE, in front of recovery and the receiver,
        // and it lists every segment in the store; on 2026-09-09 the receiver started 37 s and
        // then 9 min 23 s after the link was ready (the second across a background suspension)
        // while the watch overflowed a 6 s buffer. It is rewritten at the end of `start()` with
        // the real receiver state; this first one only has to be honest.
        let earlySnapshot = Task { await self.refreshSnapshot(.manual) }

        // Only the store-critical half. `SegmentStore.recover()` must run before any segment
        // opens, so the receiver genuinely waits for it — but nothing else in the order has that
        // constraint, and making the microphone wait for the retention sweep and the
        // transcription catch-up is what let a ~10 s Core Bluetooth wake expire with a restored
        // link and nobody consuming it.
        await environment.startup.recoverBeforeReceiving()
        await environment.receiver.markStoreRecovered()
        noteStep("store recovery")

        // Restoration relaunch: receive-only is applied BEFORE the receiver starts, so a
        // background wake never spins up transcription or AI.
        //
        // THIS IS THE LAST WORD ON `foreground` FOR THE WHOLE LAUNCH, and everything above it can
        // take tens of seconds (`recoverBeforeReceiving()` on a migrated container), so by the
        // time it runs the app may well be on screen with its `didBecomeActive` already spent —
        // and `setForeground` is a transition guard, so a demotion here could not be undone
        // without a background round trip. That is what left Today and Library with no live
        // conversation for the whole of a healthy recording on 2026-09-08. The latch is therefore
        // cleared by `.didBecomeActive` (see `AppLifecycleCoordinator`), which is the only
        // statement in the system that a scene actually came up.
        if environment.receiver.launchedInBackground {
            foreground.value = false
        }
        await environment.live.setForeground(foreground.value)

        // BEFORE the receiver: the live-audio tap only delivers events emitted after a
        // subscriber attaches, and the realtime cloud transcriber can only join a segment it
        // saw open. Starting the receiver first leaves a window where the first segment of the
        // session opens unheard, and live cloud transcription is dead until the next rotation.
        await environment.live.start()

        if environment.settings.captureIntent != .off {
            await environment.receiver.start()
        }
        noteStep("receiver start")

        // Everything past this point is catch-up on audio that is ALREADY durable, so it runs
        // after the receive path is live rather than in front of it.
        await earlySnapshot.value
        noteStep("first snapshot")
        await environment.startup.recoverRemainder()
        noteStep("remaining recovery")
        // The startup order already ran the identical sweep (`StartupStep.retentionEnforce`), so
        // the first pipeline pass must not immediately repeat it — this is bookkeeping, not work.
        await retention.noteSweptElsewhere()
        await environment.transcription.startUploader()
        await environment.recap.start()

        guard loopTask == nil else { return }
        startLoop()
        startSupervisor()
        await refreshSnapshot(.manual)
    }

    private func startLoop() {
        let pass = PipelinePass(
            steps: makeSteps(), clock: clock, health: health, onStage: stageObserver ?? { _ in })
        let loop = PipelineLoop(pass: pass, wake: wake, clock: clock, health: health, log: log)
        // `.utility`, not the default: everything on this loop is deferrable work that the user
        // is not waiting on tap-for-tap, and the scheduler puts utility work on the efficiency
        // cores at lower clocks. The UI reads the results through database observation and
        // never blocks on a pass.
        loopTask = Task(priority: .utility) { await loop.run() }
    }

    private func startSupervisor() {
        guard supervisorTask == nil else { return }
        let environment = self.environment
        let supervisor = PipelineSupervisor(
            health: health,
            clock: clock,
            recoveries: [
                // A drain that keeps throwing is not a per-task failure — the tasks have their
                // own attempts and backoff. It is the queue itself being stuck: a task left
                // Running by a process that died mid-transcription, or an upload the transport
                // no longer knows about. Both are exactly what the START-UP recovery repairs,
                // and there was no way to reach it again without relaunching the app.
                PipelineRecovery(stage: .drainQueue) {
                    await environment.transcription.recoverStuckWork()
                }
            ],
            restartLoop: { [weak self] in await self?.restartLoop() },
            log: log
        )
        supervisorTask = Task(priority: .utility) { await supervisor.run() }
    }

    /// Replaces a wedged loop. The old task is cancelled and given a moment to unwind; if it is
    /// stuck somewhere that ignores cancellation we start the new one anyway, because a
    /// duplicate pass is recoverable (the drain holds its own mutex, every other stage is
    /// re-entrant by construction) and a dead pipeline is not.
    private func restartLoop() async {
        guard let previous = loopTask else { return }
        previous.cancel()
        loopTask = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await previous.value }
            group.addTask { [clock] in try? await clock.sleep(ms: 2_000) }
            await group.next()
            group.cancelAll()
        }
        startLoop()
        wake.signal()
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        supervisorTask?.cancel()
        supervisorTask = nil
        await environment.recap.stop()
        await environment.live.stop()
        await environment.transcription.stopUploader()
        await environment.receiver.stop()
    }

    /// Foreground/background policy. Receiving is unaffected; only the heavy processing half and
    /// the live decode move.
    public func setForeground(_ value: Bool) async {
        guard foreground.value != value else { return }
        foreground.value = value
        await environment.live.setForeground(value)
        if !value {
            // Background entry, app still alive: release the model (interrupting in-flight work)
            // and hand cloud-primary pending segments to the suspension-proof transport. Neither
            // belongs in a ~10 s Bluetooth wake.
            await environment.transcription.releaseModel("background")
            await environment.transcription.submitPendingToUploader()
            await environment.deferredDeletes.commitAll()
            await refreshSnapshot(.appBackgrounded)
        } else {
            await reconcilePendingTranscriptions()
            // Foreground entry: everything the phone knows about the watch may be hours old, and
            // the status card is about to be read. Ask the watch what it is doing BEFORE the
            // snapshot is written, so neither the card nor the widget re-publishes a "Recording"
            // that only a stale latch was holding up. Re-applying the capture intent (which is
            // all the surface coordinator does here) never probed the link.
            await environment.receiver.verifyWatchState()
            // ...and act on the answer. A watch that says it is recording while we hold no stream
            // is the deadlock the user reported; asking and then filing the answer away is what
            // made "leave the app and come back" a coin flip instead of a fix.
            environment.receiver.recoverIfWatchIsRecordingWithoutUs()
            // The app is awake and cheap work is allowed again, so bring the widget's file up to
            // date immediately rather than leaving it on whatever the last background write said.
            await refreshSnapshot(.manual)
        }
        wake.signal()
        await environment.diagnostics.refresh()
    }

    /// System memory warning.
    public func releaseLocalModel(reason: String) async {
        await environment.transcription.releaseModel(reason)
    }

    // --- user-facing operations -------------------------------------------------------------------

    /// Explicit Start (status card, Settings): arm the one-shot watch prompt, then apply intent.
    public func startCapture() async {
        await environment.receiver.armWatchEnableRequest()
        await environment.receiver.applyCaptureIntent(.active)
        // Setting the intent only tells the SESSION what to want; the session observes the link
        // rather than dialling it, so without this the watch is never actually contacted and the
        // screen waits forever. "Start Recording" is an explicit user gesture, so it connects —
        // this is the same call the Connect / Find Watch buttons make, and it is idempotent when
        // a link is already up.
        environment.receiver.reconnect()
        wake.signal()
        await refreshSnapshot(.pauseChanged)
    }

    /// A capture change asked for by a surface that is not the status card: Control Center, a
    /// widget button, Siri, Shortcuts, and the Settings "Background audio" master switch. One
    /// entry point, so no surface can invent its own half of the sequence.
    ///
    /// `.active` deliberately routes through `startCapture()` rather than `setCaptureIntent`.
    /// Setting the intent only tells the SESSION what to want; the session observes the link
    /// instead of dialling it, so an intent that merely set the preference left the watch
    /// uncontacted and the toggle looking broken. This is the same fix Today's Start button
    /// needed, shared rather than re-derived.
    public func applyExternalCaptureIntent(_ intent: CaptureIntent) async {
        switch intent {
        case .active:
            await startCapture()
        case .paused, .off:
            await setCaptureIntent(intent, source: .intent)
        }
    }

    /// Pause / Resume / Off — the plan-6.1 tri-state, including the pause journal.
    public func setCaptureIntent(_ intent: CaptureIntent, source: PauseSource = .statusCard) async {
        await environment.receiver.applyCaptureIntent(intent, source: source)
        wake.signal()
        await refreshSnapshot(.pauseChanged)
        await environment.diagnostics.refresh()
    }

    public func reconnect() async {
        environment.receiver.reconnect()
    }

    /// Foreground-entry catch-up: re-scan durable storage so every closed, not-yet-transcribed
    /// segment is queued (segments that close while backgrounded are only enqueued here), then
    /// wake the loop. Safe to call repeatedly and independent of the receiver.
    public func reconcilePendingTranscriptions() async {
        await environment.startup.recoverIfNeeded()
        do { try await environment.transcription.enqueueClosedSegments() } catch {
            log.failure("reconcile enqueue", error)
        }
        wake.signal()
        await environment.diagnostics.refresh()
    }

    /// Light maintenance for a BGProcessing wake: retention cleanup, the upload hand-off and a
    /// diagnostics refresh. It deliberately never starts STT/AI/WAV export and never changes the
    /// receiver's run state — Core Bluetooth restoration owns the receive path, and a
    /// processing-task timeout must not be able to disable recording.
    public func runBackgroundMaintenance() async {
        await environment.startup.recoverIfNeeded()
        // Unconditional: a BGProcessing window exists to do exactly this, so it is not turned
        // away by the pipeline's interval.
        await retention.sweep()
        await environment.transcription.submitPendingToUploader()
        await environment.diagnostics.refresh()
        await refreshSnapshot(.manual)
    }

    /// Bounded, cancellable catch-up burst for a BGProcessing window, where the app is legitimately
    /// awake (unlike a ~10 s Bluetooth wake). No-op in the foreground: the loop already drains
    /// there, and skipping avoids two concurrent `processNext` callers. The model is released in a
    /// non-cancellable finally, so an expiration never leaves it resident.
    /// The charger window's body: clear as much backlog as the window allows.
    ///
    /// Distinct from `runCatchUpBurst` in exactly two ways — a far larger segment budget, and it
    /// consults `BackgroundWorkPolicy` first. iOS granting this window means the SYSTEM is idle
    /// and on power; it says nothing about whether the user has asked to conserve (Low Power Mode)
    /// or whether the phone is already too hot to help. Both of those override it.
    ///
    /// Returns the number of segments processed, and logs the reason when it declines, so a
    /// backlog that is not moving can explain itself instead of looking like a bug.
    @discardableResult
    public func runChargingCatchUp() async -> Int {
        let decision = BackgroundWorkPolicy.decide(
            environment.settings.backgroundCatchUp, foreground.devicePower
        )
        guard case .run = decision else {
            if case .hold(let reason) = decision {
                log.write("charging catch-up declined: \(reason.rawValue)")
            }
            // Still worth the cheap half: uploads cost us almost nothing and the system does the
            // transfer. Declining to spend the CPU is not a reason to sit on finished segments.
            await environment.transcription.submitPendingToUploader()
            return 0
        }
        log.write("charging catch-up started")
        let processed = await runCatchUpBurst(
            maxSegments: BackgroundTaskPolicy.chargingCatchUpMaxSegments
        )
        log.write("charging catch-up processed \(processed) segment(s)")
        return processed
    }

    /// The light BGProcessing window's catch-up: the ordinary bounded burst, gated on the same
    /// policy as the charger window.
    ///
    /// It was not gated, and the flight recorder shows the consequence: iOS granted the light
    /// task roughly every half hour through a night on battery, and each grant ran a
    /// ten-segment local-transcription burst that the user's own setting ("While Charging") said
    /// should not happen. The maintenance half of the window still runs unconditionally; this
    /// only decides whether the CPU and the neural engine are spent on a phone that is not
    /// plugged in, is in Low Power Mode, or is already hot.
    @discardableResult
    public func runBackgroundCatchUpIfAllowed() async -> Int {
        let decision = BackgroundWorkPolicy.decide(
            environment.settings.backgroundCatchUp, foreground.devicePower
        )
        guard case .run = decision else {
            if case .hold(let reason) = decision {
                log.write("background catch-up declined: \(reason.rawValue)")
            }
            return 0
        }
        return await runCatchUpBurst()
    }

    @discardableResult
    public func runCatchUpBurst(
        maxSegments: Int = PipelinePacing.catchUpMaxSegments
    ) async -> Int {
        guard !foreground.value else { return 0 }
        foreground.catchUpActive = true
        var processed = 0
        do {
            await environment.startup.recoverIfNeeded()
            if try await environment.transcription.reconsiderDisabled() {
                await environment.diagnostics.refresh()
            }
            try await environment.transcription.enqueueClosedSegments()
            processed = try await environment.transcription.drainQueue(maxSegments: maxSegments) {
                await self.environment.diagnostics.refresh()
            }
        } catch is CancellationError {
        } catch {
            log.failure("catch-up burst", error)
        }
        // Never leave the model resident after a background burst, even when the BGProcessing
        // expiration handler cancelled us mid-drain. A detached task does not inherit
        // cancellation — this is the Swift equivalent of the ported `withContext(NonCancellable)`.
        let transcription = environment.transcription
        await Task.detached {
            await transcription.releaseModel("background catch-up")
        }.value
        foreground.catchUpActive = false
        return processed
    }

    /// `handleEventsForBackgroundURLSession`.
    public func handleBackgroundUploadEvents() async {
        await environment.transcription.reconcileUploader()
        wake.signal()
    }

    public func reprocessSegment(_ segmentId: String) async {
        do { try await environment.transcription.reprocessSegment(segmentId) } catch {
            log.failure("reprocess", error)
        }
        wake.signal()
        await environment.diagnostics.refresh()
    }

    @discardableResult
    public func deleteSegment(_ segmentId: String) async -> Bool {
        let deleted = await environment.cascade.deleteSegment(segmentId)
        await environment.diagnostics.refresh()
        await refreshSnapshot(.manual)
        return deleted
    }

    /// "Delete All Recordings" — everything, including the one still being recorded.
    ///
    /// Four steps, in this order, because each one is a hole an earlier version left behind:
    /// 1. Close the open segment THROUGH THE RECEIVER. `DeleteCascade` refuses an open segment
    ///    (its store `precondition` would trap), so a loop over `listSegments()` silently
    ///    skipped the recording in progress and it reappeared in the Library the moment it
    ///    closed. Going straight at the store instead was worse: it left the receiver session
    ///    holding a stream context over a segment that no longer existed, appending into nothing
    ///    and checkpointing it as received — see `ReceiverService.closeOpenSegment`.
    /// 2. Cascade every segment: audio, transcript, follow-ups, single-source AI outputs,
    ///    quoting recaps, annotations and the search-index rows.
    /// 3. Sweep transcription state that has no segment left to hang off — queue tasks and
    ///    transcript files orphaned by an earlier interrupted delete or a crash mid-cascade.
    ///    Without it "delete all" can leave a queue that keeps retrying vanished audio.
    /// 4. Put the live stream back into a fresh segment. Deleting recordings is not a request to
    ///    stop recording; the watch is still streaming and its buffered audio is still ours to
    ///    collect. This runs AFTER the cascade so the re-announced stream cannot reattach to a
    ///    segment that is about to be deleted.
    ///
    /// Returns how many segments were destroyed.
    @discardableResult
    public func deleteAllRecordings() async -> Int {
        await environment.receiver.closeOpenSegment()
        var deleted = 0
        for meta in await environment.store.listSegments()
        where await environment.cascade.deleteSegment(meta.segmentId) {
            deleted += 1
        }
        do { try await environment.transcription.deleteAllTranscriptionData() } catch {
            log.failure("delete all transcription data", error)
        }
        await environment.receiver.resumeAfterBulkDelete()
        await environment.diagnostics.refresh()
        await refreshSnapshot(.manual)
        return deleted
    }

    /// Conversation delete with the 5 s undo window. The token goes to the app's snackbar; call
    /// `commitDelete` when the window closes or `restoreDelete` on Undo.
    public func deleteConversation(id: String) async -> PendingConversationDelete {
        let token = await environment.deferredDeletes.deleteConversation(id: id)
        return token
    }

    @discardableResult
    public func commitDelete(_ token: PendingConversationDelete) async -> [String] {
        let deleted = await environment.deferredDeletes.commit(token)
        await environment.diagnostics.refresh()
        await refreshSnapshot(.manual)
        return deleted
    }

    @discardableResult
    public func restoreDelete(_ token: PendingConversationDelete) async -> Bool {
        await environment.deferredDeletes.restore(token)
    }

    public func testCloudConnection() async {
        await environment.transcription.testCloudConnection()
    }

    public func supportReport() async -> SupportReport {
        let diagnostics = await environment.diagnostics.refresh()
        return SupportReport(
            generatedAtMs: clock.nowMs,
            receiverState: String(describing: environment.receiver.state.value),
            captureIntent: String(describing: environment.receiver.captureIntent),
            diagnostics: diagnostics
        )
    }

    // --- snapshot ---------------------------------------------------------------------------------

    /// Refreshes the App Group coverage snapshot the widget renders from.
    public func refreshSnapshot(_ trigger: CoverageSnapshotTrigger) async {
        await environment.snapshots.refresh(trigger)
    }

    // --- pipeline wiring ---------------------------------------------------------------------------

    private func makeSteps() -> PipelineSteps {
        let env = environment
        let foreground = self.foreground
        let log = self.log
        let retention = self.retention
        let health = self.health
        return PipelineSteps(
            isForeground: { foreground.value },
            isCatchUpActive: { foreground.catchUpActive },
            releaseModel: { reason in await env.transcription.releaseModel(reason) },
            reconsiderDisabled: { try await env.transcription.reconsiderDisabled() },
            enqueueClosedSegments: { try await env.transcription.enqueueClosedSegments() },
            // Each drained task is progress for the loop watchdog: a backlog of a dozen
            // segments is one stage that legitimately runs for many minutes.
            drainQueue: {
                try await env.transcription.drainQueue {
                    health.progressed()
                    await env.diagnostics.refresh()
                }
            },
            // Self-paced inside the service: normally an interval check and nothing else. This is
            // what makes "Keep audio" take effect while the app is open instead of at the next
            // launch — a settings write wakes the loop, and the changed policy is itself the
            // trigger.
            enforceRetentionIfDue: { !(await retention.sweepIfDue()).isEmpty },
            regroup: { try await env.enrichment.regroupPass() },
            enrich: { try await env.enrichment.enrichPass() },
            donate: { ids in await env.enrichment.donate(conversationIds: ids) },
            extractFollowUps: { try await env.enrichment.followUpPass() },
            refreshRecap: { await env.recap.refresh() },
            liveLocalPass: { try await env.live.localLivePass() },
            liveCloudPrune: { await env.live.cloudLivePrune() },
            exportWavIfEnabled: { try await env.live.exportWavIfEnabled() },
            releaseModelIfIdle: {
                await env.transcription.releaseModelIfIdle(
                    idleTimeoutMs: PipelinePacing.modelIdleTimeoutMs
                )
            },
            isFollowingOpenSegment: { await env.live.isFollowingOpenSegment() },
            nextRetryAtMs: {
                do { return try await env.transcription.nextRetryAtMs() } catch {
                    log.failure("next retry", error)
                    return nil
                }
            },
            onDiagnosticsDirty: { await env.diagnostics.refresh() },
            refreshCoverageSnapshot: {
                await env.snapshots.refreshIfDue(
                    .pipelinePass,
                    minIntervalMs: foreground.value
                        ? CoverageSnapshotService.foregroundHeartbeatMs
                        : CoverageSnapshotService.backgroundHeartbeatMs
                )
            },
            submitPendingUploads: { await env.transcription.submitPendingToUploader() },
            backgroundWorkDecision: {
                BackgroundWorkPolicy.decide(
                    env.settings.backgroundCatchUp, foreground.devicePower
                )
            },
            isThermallyThrottled: {
                let throttled = foreground.devicePower.thermalState >= .serious
                // Say so once per transition. The device-power line already records the thermal
                // state itself; this names what the pipeline did about it.
                if foreground.noteThermalHold(throttled) {
                    log.write(
                        throttled
                            ? "pipeline: holding model work until the phone cools down"
                            : "pipeline: phone cooled down; model work resumes")
                }
                return throttled
            }
        )
    }
}

/// Foreground policy + catch-up flag, readable synchronously from the pass closures.
///
/// Shared (not owned by `CompanionRuntime`) so `DiagnosticsService` reports the same truth the
/// pass acts on — the KMP version kept two copies and they drifted.
public final class RuntimeForegroundState: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    private var _catchUpActive = false

    public init(foreground: Bool = true) { self._value = foreground }

    /// The device conditions `BackgroundWorkPolicy` judges on. Lives here because this is the one
    /// object the pass closures already read synchronously, and the decision has to be made inside
    /// a non-async closure.
    private var _devicePower = DevicePowerSnapshot()
    public var devicePower: DevicePowerSnapshot {
        get { lock.withLock { _devicePower } }
        set { lock.withLock { _devicePower = newValue } }
    }

    public var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// True while a sanctioned background catch-up burst holds the local model.
    public var catchUpActive: Bool {
        get { lock.withLock { _catchUpActive } }
        set { lock.withLock { _catchUpActive = newValue } }
    }

    private var _thermalHoldAnnounced = false

    /// Records whether the pipeline is currently holding model work for heat. Returns true when
    /// that changed, so the caller can log the transition exactly once.
    public func noteThermalHold(_ holding: Bool) -> Bool {
        lock.withLock {
            guard _thermalHoldAnnounced != holding else { return false }
            _thermalHoldAnnounced = holding
            return true
        }
    }
}
