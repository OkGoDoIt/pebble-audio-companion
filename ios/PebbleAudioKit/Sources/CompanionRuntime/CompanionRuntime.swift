import AppDB
import Foundation
import Intelligence
import LiveAudio
import Receiver
import SearchKit
import SegmentStore
import StatusUI
import Transcription

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
    private var stageObserver: (@Sendable (PipelineStage) -> Void)?

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
    }

    // --- published surfaces --------------------------------------------------------------------

    public nonisolated var receiverState: StateSubject<ReceiverSessionState> {
        environment.receiver.state
    }
    public nonisolated var watchServiceState: StateSubject<Int?> {
        environment.receiver.watchServiceState
    }
    public nonisolated var diagnostics: StateSubject<RuntimeDiagnostics> {
        environment.diagnostics.snapshot
    }
    public nonisolated var library: LibraryStore { environment.library }
    public nonisolated var captureIntent: CaptureIntent { environment.receiver.captureIntent }
    public nonisolated var isForeground: Bool { foreground.value }

    /// Wakes the pipeline early. Every settings change that could unblock work calls this —
    /// that is what makes pacing event-driven rather than poll-driven.
    public nonisolated func notifyConfigChanged() {
        wake.signal()
    }

    // --- lifecycle -----------------------------------------------------------------------------

    /// Startup: run the recovery order (which runs the legacy import first), start the receiver
    /// when the user's intent says to, then start the processing loop.
    public func start() async {
        await environment.startup.recoverIfNeeded()

        // Restoration relaunch: receive-only is applied BEFORE the receiver starts, so a
        // background wake never spins up transcription or AI.
        if environment.receiver.launchedInBackground {
            foreground.value = false
        }
        await environment.live.setForeground(foreground.value)

        if environment.settings.captureIntent != .off {
            await environment.receiver.start()
        }
        await environment.transcription.startUploader()
        await environment.live.start()
        await environment.recap.start()

        guard loopTask == nil else { return }
        let pass = PipelinePass(steps: makeSteps(), clock: clock, onStage: stageObserver ?? { _ in })
        let loop = PipelineLoop(pass: pass, wake: wake, clock: clock, log: log)
        loopTask = Task { await loop.run() }
        await refreshSnapshot(.manual)
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
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
        wake.signal()
        await refreshSnapshot(.pauseChanged)
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
        do {
            for deleted in try await environment.retention.enforce() {
                _ = await environment.cascade.deleteSegment(deleted)
            }
        } catch {
            log.failure("background retention", error)
        }
        await environment.transcription.submitPendingToUploader()
        await environment.diagnostics.refresh()
        await refreshSnapshot(.manual)
    }

    /// Bounded, cancellable catch-up burst for a BGProcessing window, where the app is legitimately
    /// awake (unlike a ~10 s Bluetooth wake). No-op in the foreground: the loop already drains
    /// there, and skipping avoids two concurrent `processNext` callers. The model is released in a
    /// non-cancellable finally, so an expiration never leaves it resident.
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
        return PipelineSteps(
            isForeground: { foreground.value },
            isCatchUpActive: { foreground.catchUpActive },
            releaseModel: { reason in await env.transcription.releaseModel(reason) },
            reconsiderDisabled: { try await env.transcription.reconsiderDisabled() },
            enqueueClosedSegments: { try await env.transcription.enqueueClosedSegments() },
            drainQueue: {
                try await env.transcription.drainQueue { await env.diagnostics.refresh() }
            },
            enrich: { try await env.enrichment.enrichPass() },
            donate: { ids in await env.enrichment.donate(conversationIds: ids) },
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
            onDiagnosticsDirty: { await env.diagnostics.refresh() }
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

    public var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// True while a sanctioned background catch-up burst holds the local model.
    public var catchUpActive: Bool {
        get { lock.withLock { _catchUpActive } }
        set { lock.withLock { _catchUpActive = newValue } }
    }
}
