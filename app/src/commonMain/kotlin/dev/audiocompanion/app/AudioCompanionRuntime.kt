package dev.audiocompanion.app

import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.ActionItemParser
import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.FileActionItemStore
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileCustomTemplateStore
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.ai.FileRuleStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.ai.FileSpeakerIdentityStore
import dev.audiocompanion.ai.PersonalContext
import dev.audiocompanion.ai.Rule
import dev.audiocompanion.ai.RuleRun
import dev.audiocompanion.ai.SavedAiTemplate
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.ai.SpeakerIdentity
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.storage.TranscriptionState as SegmentTranscriptionState
import dev.audiocompanion.transcription.BackgroundCloudUploadCoordinator
import dev.audiocompanion.transcription.FileTranscriptStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.LocalTranscriptionLifecycle
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TaskState
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.AudioReceiverSession
import dev.audiocompanion.transport.ReceiverConfig
import dev.audiocompanion.transport.ReceiverSessionState
import dev.audiocompanion.transport.ReceiverResumeStore
import dev.audiocompanion.transport.SegmentCloseReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.cancellation.CancellationException

data class AudioCompanionDiagnostics(
    val segmentCount: Int = 0,
    val openSegmentId: String? = null,
    val queuedTranscriptionTasks: Int = 0,
    val failedTranscriptionTasks: Int = 0,
    val lowStorage: Boolean = false,
    val pauseRequested: Boolean = false,
    val freeStorageHintKb: UInt = 0u,
    val aiOutputCount: Int = 0,
    /**
     * True when the app is backgrounded: audio is still received, but local transcription/AI are
     * deferred until the app returns to the foreground. Lets the UI show honest "paused" status
     * instead of implying work is happening.
     */
    val transcriptionPausedInBackground: Boolean = false,
    /**
     * Monotonic count of daily digest saves this process. Digest refreshes happen off the
     * segment/transcription event stream, so this is what makes a recap update reach the UI's
     * diagnostics-keyed durable reload.
     */
    val dailyDigestUpdates: Int = 0,
)

data class AudioCompanionSupportReport(
    val generatedAtMs: Long,
    val receiverState: String,
    val diagnostics: AudioCompanionDiagnostics,
    val includeContent: Boolean,
)

/**
 * Owns the durable receiver runtime for the third-party app.
 *
 * BLE adapters stay as raw GATT links. This runtime recovers on-disk state, starts the shared
 * receiver session, exposes diagnostics for UI, and keeps transcription/retention state colocated
 * with durable storage instead of the official Pebble mobile app.
 */
class AudioCompanionRuntime(
    private val link: AudioGattLink,
    private val store: SegmentStore,
    private val retention: RetentionManager,
    private val resumeStore: ReceiverResumeStore,
    private val transcriptionQueue: FileTranscriptionQueue,
    private val transcriptionProcessor: TranscriptionProcessor,
    private val transcriptStore: FileTranscriptStore,
    private val aiOutputStore: FileAiOutputStore,
    private val annotationStore: FileSegmentAnnotationStore,
    private val receiverConfig: ReceiverConfig,
    private val nowMs: () -> Long,
    /** Null when the app ships without any AI provider wiring (AI screen shows setup state). */
    private val aiRouter: AiModeRouter? = null,
    /** Live waveform source; null disables the tee (e.g. in receiver-only tests). */
    val liveMonitor: LiveAudioMonitor? = null,
    /** Rolling transcript preview of the open segment; null disables live transcription. */
    private val liveTranscriber: LiveTranscriber? = null,
    /** Segment playback; null on platforms/tests without an audio output path. */
    val playback: SegmentPlaybackController? = null,
    /** Stored-segment waveform builder; null when no decoder exists (tests). */
    private val waveformBuilder: SegmentWaveformBuilder? = null,
    /** User-visible WAV exporter; null in tests or bare receiver builds without a decoder. */
    private val exportManager: AudioExportManager? = null,
    /** Off by default; when true, closed segments are mirrored into WAV files. */
    private val automaticWavExportEnabled: () -> Boolean = { false },
    /**
     * The user's current "record in the background" intent (the Start/Stop toggle). Drives the
     * session's declarative reconcile so a restart reliably resumes the watch.
     */
    private val desiredEnabled: () -> Boolean = { true },
    /**
     * Releases the resident local transcription model on background/idle/memory pressure; null in
     * tests and builds without a local model.
     */
    private val localTranscriptionLifecycle: LocalTranscriptionLifecycle? = null,
    /**
     * Suspension-proof background cloud-upload transport for cloud-primary modes (iOS only for
     * now); null disables it (Android, tests, local-only builds).
     */
    private val backgroundUploadCoordinator: BackgroundCloudUploadCoordinator? = null,
    /** Real-time cloud transcription of the open segment (foreground, opt-in); null disables it. */
    private val cloudLiveTranscriber: CloudLiveTranscriber? = null,
    /** Live-audio fan-out feeding [cloudLiveTranscriber]; null disables real-time streaming. */
    private val liveAudioTap: LiveAudioTap? = null,
    /** User-owned personal context for transcription biasing and AI grounding; null in bare tests. */
    private val personalContextCoordinator: PersonalContextCoordinator? = null,
    private val personalContextImporter: PersonalContextImporter? = null,
    private val digestStore: FileDailyDigestStore? = null,
    private val actionItemStore: FileActionItemStore? = null,
    private val customTemplateStore: FileCustomTemplateStore? = null,
    private val ruleStore: FileRuleStore? = null,
    private val speakerIdentityStore: FileSpeakerIdentityStore? = null,
    val navigationState: NavigationState = NavigationState(),
    private val transcriptIndexDonator: TranscriptIndexDonator? = null,
    private val askRetriever: AskRetriever? = null,
    private val ruleEvaluator: RuleEvaluator? = null,
    /** Shared cloud-health state, written by the router and the explicit test; null in tests. */
    private val cloudHealthMonitor: CloudHealthMonitor? = null,
    /** The selected cloud provider's self-test, for the Settings connectivity check; null disables it. */
    private val cloudConnectivityCheck: dev.audiocompanion.transcription.CloudConnectivityCheck? = null,
) {
    private val enrichmentWorker = SegmentEnrichmentWorker(
        annotations = annotationStore,
        router = aiRouter,
        nowMs = nowMs,
    )
    private var dailyRecapEngine: DailyRecapEngine? = null
    private var digestUpdateCount = 0
    private val defaultPersonalContextFlow = MutableStateFlow(PersonalContext()).asStateFlow()
    private val watchEnableRequestArmed = MutableStateFlow(false)

    private val session = AudioReceiverSession(
        link = link,
        sink = liveMonitor?.let {
            TeeSegmentSink(
                store = store,
                monitor = it,
                nowMs = nowMs,
                tap = liveAudioTap,
                onSegmentClosed = { transcriptionWakeups.trySend(Unit) },
            )
        } ?: store,
        policy = retention,
        resumeStore = resumeStore,
        config = receiverConfig,
        nowMs = nowMs,
        desiredEnabled = desiredEnabled,
        consumeEnableRequestPermission = ::consumeWatchEnableRequestPermission,
    )

    val state: StateFlow<ReceiverSessionState> = session.state

    /**
     * Raw watch service state (protocol ServiceState) from the Info read and STATE_CHANGED
     * pushes; null when unknown/disconnected. Lets the UI mirror the watch's own Settings
     * status (paused by dictation, low battery, disabled on watch, …).
     */
    val watchServiceState: StateFlow<Int?> = session.watchServiceState

    val diagnostics: StateFlow<AudioCompanionDiagnostics> get() = _diagnostics.asStateFlow()

    private val _diagnostics = MutableStateFlow(AudioCompanionDiagnostics())
    private val emptyLiveTranscriptPreviews =
        MutableStateFlow<Map<String, LiveTranscriptPreview>>(emptyMap())
    private val lifecycleMutex = Mutex()
    /** Serializes queue processing so the foreground loop and a triggered catch-up never run
     *  `processNext` concurrently on the shared (process-singleton) runtime. */
    private val processingMutex = Mutex()
    private var durableStateRecovered = false
    private var sessionJob: Job? = null
    private var transcriptionJob: Job? = null
    private var uploadCoordinatorJob: Job? = null
    private var livePreviewMergeJob: Job? = null
    private val transcriptionWakeups = Channel<Unit>(Channel.CONFLATED)

    /** Scope the processing loop runs on, captured at [start]; used to release the model promptly. */
    private var processingScope: CoroutineScope? = null

    /**
     * Foreground/background processing policy (plan: "Split receive from process"). The receive
     * path (BLE connect/subscribe/append/checkpoint) always runs regardless of this. This only
     * gates the heavy processing loop so a short Core Bluetooth background wake stays cheap.
     */
    private val foreground = MutableStateFlow(true)

    /**
     * True while a sanctioned background catch-up burst ([runCatchUpBurst]) holds the local model.
     * The suppressed background loop checks this so it does not release the model out from under an
     * in-progress burst.
     */
    private val backgroundCatchUpActive = MutableStateFlow(false)

    /**
     * Switches the processing policy. Receiving is unaffected. On entering the background it stops
     * decoding the live waveform, releases the local model promptly (interrupting any in-flight
     * inference), and wakes the loop so it begins deferring; on returning to the foreground it
     * wakes the loop to resume.
     */
    fun setForeground(value: Boolean) {
        if (foreground.value == value) return
        foreground.value = value
        cloudLiveTranscriber?.setForeground(value)
        if (!value) {
            liveMonitor?.setActive(false)
            processingScope?.launch { localTranscriptionLifecycle?.releaseModel("background") }
            // Hand any pending cloud-primary segments to the suspension-proof upload transport so
            // they keep transcribing while the app is suspended. Done here (background entry, app
            // still alive) rather than during the short Bluetooth wakes.
            processingScope?.launch {
                try {
                    backgroundUploadCoordinator?.submitPending()
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    logBackgroundFailure("upload submit", t)
                }
            }
        }
        transcriptionWakeups.trySend(Unit)
        refreshDiagnostics()
    }

    /** Releases the resident local transcription model now (e.g. on a system memory warning). */
    suspend fun releaseLocalModel(reason: String) {
        localTranscriptionLifecycle?.releaseModel(reason)
    }

    /** App-wide cloud transcription health, for Settings status and the failure banner. */
    val cloudHealth: StateFlow<CloudHealth> =
        cloudHealthMonitor?.state ?: MutableStateFlow(CloudHealth()).asStateFlow()

    /**
     * Runs an authenticated probe against the currently-selected cloud provider and publishes the
     * result to [cloudHealth]. Called when the user enters an API key, switches provider, or taps
     * "Test connection" in Settings. No-op when no cloud provider is wired.
     */
    suspend fun testCloudConnection() {
        val check = cloudConnectivityCheck ?: return
        val monitor = cloudHealthMonitor ?: return
        monitor.reportChecking()
        try {
            monitor.reportImmediate(check.checkConnectivity())
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            monitor.reportImmediate(
                dev.audiocompanion.transcription.CloudConnectivityResult.Failed(
                    t.message ?: "Cloud connectivity test failed.",
                ),
            )
        }
    }

    /**
     * User-requested re-transcribe: forces the segment's task back to Pending (clearing prior
     * attempts/terminal state) and wakes the loop so it re-runs under the *current* transcription
     * mode — e.g. to upgrade an old on-device transcript to cloud accuracy after enabling cloud. The
     * existing transcript stays visible until the new one replaces it. No-op for the open segment.
     */
    fun reprocessSegment(segmentId: String) {
        val meta = store.readMeta(segmentId) ?: return
        if (meta.isOpen) return
        if (transcriptionQueue.requeue(segmentId) == null) {
            transcriptionQueue.enqueue(segmentId)
        }
        store.updateTranscriptionState(segmentId, SegmentTranscriptionState.Pending)
        transcriptionWakeups.trySend(Unit)
        refreshDiagnostics()
    }

    /**
     * Foreground-entry catch-up: re-scan durable storage so every closed, not-yet-transcribed
     * segment is queued, then wake the processing loop. Segments that close while the app is
     * backgrounded are only enqueued by the foreground pass, so opening the app must re-scan and
     * enqueue them; the queue's newest-first ordering then transcribes the most recent audio first
     * while the older backlog still drains. Safe to call repeatedly and independent of the receiver.
     */
    fun reconcilePendingTranscriptions() {
        recoverDurableStateIfNeeded()
        enqueueClosedSegmentsForTranscription()
        transcriptionWakeups.trySend(Unit)
        refreshDiagnostics()
    }

    /**
     * Bounded, opportunistic catch-up for an iOS BGProcessingTask window, where the app is
     * legitimately awake (unlike a ~10s Core Bluetooth wake). Transcribes up to [maxSegments] queued
     * segments, then releases the local model. Each step is still gated by the per-process memory
     * guard, so it defers rather than risks a kill when the budget is tight, and it is fully
     * cancellable — the BGProcessing expiration handler cancels it cleanly. Returns the number of
     * tasks advanced.
     *
     * No-op in the foreground: the normal processing loop already drains the queue there, and
     * skipping avoids two concurrent `processNext` callers.
     */
    suspend fun runCatchUpBurst(maxSegments: Int = BACKGROUND_CATCHUP_MAX_SEGMENTS): Int {
        if (foreground.value) return 0
        backgroundCatchUpActive.value = true
        try {
            recoverDurableStateIfNeeded()
            if (transcriptionProcessor.reconsiderDisabled().isNotEmpty()) {
                refreshDiagnostics()
            }
            enqueueClosedSegmentsForTranscription()
            var processed = 0
            while (processed < maxSegments && transcriptionProcessor.processNext() != null) {
                processed += 1
                refreshDiagnostics()
            }
            return processed
        } finally {
            // Never leave the model resident after a background burst, even on cancellation.
            withContext(NonCancellable) {
                localTranscriptionLifecycle?.releaseModel("background catch-up")
            }
            backgroundCatchUpActive.value = false
        }
    }

    fun recoverDurableState() {
        recoverDurableStateIfNeeded()
    }

    private fun recoverDurableStateIfNeeded() {
        if (durableStateRecovered) {
            refreshDiagnostics()
            return
        }
        store.recover()
        transcriptionQueue.recoverOnStart()
        retention.enforce().forEach { deletedSegmentId ->
            transcriptionQueue.delete(deletedSegmentId)
            transcriptStore.delete(deletedSegmentId)
            annotationStore.delete(deletedSegmentId)
        }
        enqueueClosedSegmentsForTranscription()
        durableStateRecovered = true
        refreshDiagnostics()
    }

    suspend fun start(scope: CoroutineScope): Job =
        lifecycleMutex.withLock {
            recoverDurableStateIfNeeded()
            processingScope = scope
            if (dailyRecapEngine == null && digestStore != null) {
                dailyRecapEngine = DailyRecapEngine(
                    listSegments = store::listSegments,
                    transcriptTextOf = { transcriptStore.load(it)?.text },
                    digestStore = digestStore,
                    aiRouter = aiRouter,
                    onDigestSaved = { digest ->
                        digestUpdateCount += 1
                        refreshDiagnostics()
                        // Same-day regenerations reuse the id "day-<dateKey>", so this
                        // replaces the day's index entry instead of accumulating copies.
                        transcriptIndexDonator?.donateDigest(digest)
                    },
                    nowMs = nowMs,
                ).also { it.start(scope) }
            }
            if (transcriptionJob == null) {
                transcriptionJob = scope.launch { runTranscriptionLoop() }
            }
            if (livePreviewMergeJob == null) {
                cloudLiveTranscriber?.start(scope)
                livePreviewMergeJob = scope.launch {
                    combine(
                        liveTranscriber?.previews ?: emptyLiveTranscriptPreviews,
                        cloudLiveTranscriber?.previews ?: emptyLiveTranscriptPreviews,
                    ) { local, cloud -> local + cloud }
                        .collect { _liveTranscriptPreviews.value = it }
                }
            }
            if (backgroundUploadCoordinator != null && uploadCoordinatorJob == null) {
                uploadCoordinatorJob = backgroundUploadCoordinator.start(scope)
                // Re-attach to uploads that may have completed while we were suspended/terminated.
                scope.launch {
                    try {
                        backgroundUploadCoordinator.reconcile()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (t: Throwable) {
                        logBackgroundFailure("upload reconcile", t)
                    }
                }
            }
            sessionJob ?: session.start(scope).also { sessionJob = it }
        }

    /**
     * Arms exactly one phone-initiated watch enable prompt. Automatic lifecycle reconnects may
     * resume an already-enabled watch, but only an explicit Start/Settings action should ask the
     * watch to turn Background Audio on.
     */
    fun armWatchEnableRequest() {
        watchEnableRequestArmed.value = true
        val deniedDisabled = (state.value as? ReceiverSessionState.Denied)
            ?.status == dev.audiocompanion.protocol.AuthStatus.DeniedDisabled
        if (deniedDisabled) {
            link.resync()
        }
    }

    /**
     * User-facing "Reconnect": force a fresh GATT session now without changing the recording
     * intent. Used as the manual escape hatch when the link is stuck connecting or appears
     * half-dead, complementing the automatic keepalive/watchdog recovery.
     */
    fun reconnect() {
        link.resync()
    }

    private fun consumeWatchEnableRequestPermission(): Boolean {
        val armed = watchEnableRequestArmed.value
        watchEnableRequestArmed.value = false
        return armed
    }

    fun stop() {
        sessionJob?.cancel()
        sessionJob = null
        watchEnableRequestArmed.value = false
        transcriptionJob?.cancel()
        transcriptionJob = null
        refreshDiagnostics()
    }

    /**
     * User-initiated Stop: tell the watch to pause capture (so its Settings show Paused and it
     * does not stream into a void), then tear the receiver down and drop the GATT connection.
     * The watch keeps the pause across disconnects; the next start resumes it (the session
     * auto-sends RESUME on re-authorization).
     */
    suspend fun stopReceiving() {
        session.requestPause()
        if (desiredEnabled()) {
            // Fast Stop -> Start: the user turned recording back on while the pause request was
            // in flight. Tearing down now would strand that restart (a dead session with the
            // intent on). Keep the live session and just undo the pause instead. Callers set the
            // intent to false before calling stopReceiving, so this only triggers on a real race.
            session.requestResume()
            return
        }
        stop()
        link.disconnect()
    }

    /**
     * Light maintenance for an iOS BGProcessingTask wake (plan: "Fix BGProcessing usage"):
     * retention cleanup and a diagnostics refresh only. It deliberately never starts STT/AI/WAV
     * export and never changes the receiver's run state or the user's background-recording intent —
     * Core Bluetooth restoration owns the receive path, and a processing-task timeout must not be
     * able to disable recording. Heavy catch-up belongs in the foreground or a user-started task.
     */
    suspend fun runBackgroundMaintenance() {
        recoverDurableStateIfNeeded()
        retention.enforce().forEach { deletedSegmentId ->
            transcriptionQueue.delete(deletedSegmentId)
            transcriptStore.delete(deletedSegmentId)
            annotationStore.delete(deletedSegmentId)
        }
        // The BGProcessing window has time to decode + hand off any newly pending cloud uploads.
        backgroundUploadCoordinator?.submitPending()
        refreshDiagnostics()
    }

    /**
     * Processes up to [maxSegments] pending transcriptions now, regardless of foreground state, then
     * releases the local model. This is the in-process catch-up the Android WorkManager worker runs
     * when the app is otherwise idle (the analog of the iOS BGProcessing burst); it reuses the
     * synchronous pipeline and is serialized against the foreground loop. Returns tasks advanced.
     */
    suspend fun runCatchUpNow(maxSegments: Int = BACKGROUND_CATCHUP_MAX_SEGMENTS): Int {
        recoverDurableStateIfNeeded()
        return processingMutex.withLock {
            if (transcriptionProcessor.reconsiderDisabled().isNotEmpty()) refreshDiagnostics()
            enqueueClosedSegmentsForTranscription()
            var processed = 0
            try {
                while (processed < maxSegments && transcriptionProcessor.processNext() != null) {
                    processed += 1
                    refreshDiagnostics()
                }
            } finally {
                withContext(NonCancellable) {
                    localTranscriptionLifecycle?.releaseModel("catch-up done")
                }
            }
            processed
        }
    }

    fun refreshDiagnostics() {
        val tasks = transcriptionQueue.all()
        _diagnostics.value = AudioCompanionDiagnostics(
            segmentCount = store.listSegments().size,
            openSegmentId = store.openSegmentId,
            queuedTranscriptionTasks = tasks.count { it.state == TaskState.Pending || it.state == TaskState.Running },
            failedTranscriptionTasks = tasks.count { it.state == TaskState.Failed },
            lowStorage = retention.lowStorage,
            pauseRequested = retention.pauseRequested,
            freeStorageHintKb = retention.freeStorageHintKb(),
            aiOutputCount = aiOutputStore.list().size,
            transcriptionPausedInBackground = !foreground.value,
            dailyDigestUpdates = digestUpdateCount,
        )
    }

    val audioExportDirectory: String?
        get() = exportManager?.directory

    suspend fun deleteAllLocalData() {
        stop()
        link.disconnect()
        playback?.stop()
        store.closeSegment(SegmentCloseReason.Interrupted)
        transcriptIndexDonator?.removeAll()
        store.listSegments().forEach { store.deleteSegment(it.segmentId) }
        transcriptionQueue.deleteAll()
        transcriptStore.deleteAll()
        annotationStore.deleteAll()
        aiOutputStore.deleteAll()
        digestStore?.deleteAll()
        actionItemStore?.deleteAll()
        customTemplateStore?.deleteAll()
        ruleStore?.deleteAll()
        speakerIdentityStore?.deleteAll()
        personalContextCoordinator?.clear(processingScope ?: CoroutineScope(NonCancellable))
        resumeStore.clear()
        refreshDiagnostics()
    }

    /**
     * Deletes one segment and everything linked only to it: encoded audio, metadata, the
     * transcription task, the transcript, and AI outputs whose source set was just this segment.
     */
    fun deleteSegmentData(segmentId: String) {
        if (segmentId == store.openSegmentId) return
        if (playback?.state?.value?.segmentId == segmentId) playback.stop()
        store.deleteSegment(segmentId)
        transcriptionQueue.delete(segmentId)
        transcriptStore.delete(segmentId)
        annotationStore.delete(segmentId)
        aiOutputStore.list()
            .filter { segmentId in it.segmentIds }
            .forEach { aiOutputStore.delete(it.outputId) }
        val removedActionItemIds = actionItemStore?.let { store ->
            store.list()
                .filter { it.sourceSegmentId == segmentId }
                .onEach { store.delete(it.id) }
                .map { it.id }
        }.orEmpty()
        val removedDigestIds = digestStore?.let { store ->
            store.list()
                .filter { segmentId in it.segmentIds }
                .onEach { store.delete(it.dateKey) }
                .map { "day-${it.dateKey}" }
        }.orEmpty()
        processingScope?.launch {
            transcriptIndexDonator?.remove(segmentId)
            removedActionItemIds.forEach { transcriptIndexDonator?.remove(it) }
            removedDigestIds.forEach { transcriptIndexDonator?.remove(it) }
        }
        refreshDiagnostics()
    }

    suspend fun exportSegmentAudio(segmentId: String): AudioExportResult {
        val manager = exportManager ?: return AudioExportResult("", emptyList())
        return manager.exportSegment(segmentId, overwrite = true)
    }

    suspend fun exportAllAudio(): AudioExportResult {
        val manager = exportManager ?: return AudioExportResult("", emptyList())
        return manager.exportAllClosedSegments(overwrite = true)
    }

    /** Durable segment snapshot for UI lists (file-backed; cheap at MVP scale). */
    fun listSegmentsForUi(): List<SegmentMeta> = store.listSegments()

    fun transcript(segmentId: String): SegmentTranscript? = transcriptStore.load(segmentId)

    /**
     * Rolling live transcript of a still-recording (or just-closed, not yet fully transcribed)
     * segment, or null. UI-preview only; the durable transcript supersedes it.
     */
    fun liveTranscript(segmentId: String): String? =
        _liveTranscriptPreviews.value[segmentId]?.text?.takeIf { it.isNotBlank() }
            ?: liveTranscriber?.textFor(segmentId)

    /** Full live-preview progress (text + transcribed boundary) for waveform coloring. */
    fun liveTranscriptPreview(segmentId: String): LiveTranscriptPreview? =
        _liveTranscriptPreviews.value[segmentId] ?: liveTranscriber?.previewFor(segmentId)

    /**
     * Live preview progress as a flow so visible screens can update without a tab reload. Merges
     * the local chunk-based previews with the real-time cloud previews (cloud overrides local for
     * the same open segment); populated by a collector started in [start].
     */
    private val _liveTranscriptPreviews =
        MutableStateFlow<Map<String, LiveTranscriptPreview>>(emptyMap())
    val liveTranscriptPreviews: StateFlow<Map<String, LiveTranscriptPreview>> =
        _liveTranscriptPreviews.asStateFlow()

    fun listTranscripts(): List<SegmentTranscript> = transcriptStore.list()

    fun annotation(segmentId: String): SegmentAnnotation? = annotationStore.load(segmentId)

    /**
     * Color-codable waveform of a stored segment, decoded from the durable frame log off the
     * UI path. Null when no decoder is wired. Cached for the most recent segment.
     */
    suspend fun segmentWaveform(segmentId: String): SegmentWaveform? {
        val builder = waveformBuilder ?: return null
        val meta = store.readMeta(segmentId) ?: return null
        return builder.build(meta) { store.readFrames(segmentId) }
    }

    // --- AI (manual MVP flow: durable transcripts in, durable outputs out) ----------------------

    suspend fun isAiAvailable(): Boolean = aiRouter?.isAvailable() == true

    /**
     * Runs one manual AI template over the durable transcripts of [segmentIds] and persists the
     * output with provenance. Throws [AiException] subtypes for unavailability/consent issues so
     * the UI can show actionable copy.
     */
    suspend fun runAi(
        prompt: AiPromptTemplate,
        segmentIds: List<String>,
        userConsentedToRemote: Boolean,
    ): AiOutput {
        val router = aiRouter ?: throw AiException.ProviderUnavailable("none-configured")
        val transcripts = segmentIds.mapNotNull { segmentId ->
            transcriptStore.load(segmentId)?.let { transcript ->
                TranscriptExcerpt(
                    segmentId = segmentId,
                    text = transcript.text,
                    startTimeMs = store.readMeta(segmentId)?.startTimeMs?.toLong(),
                )
            }
        }
        if (transcripts.isEmpty()) {
            throw AiException.ProviderFailed("No transcripts available for the selected segments")
        }
        val request = AiRunRequest(
            requestId = "ai-${nowMs()}-${aiRunCounter++}",
            prompt = prompt,
            transcripts = transcripts,
        )
        val result = router.run(request)
        val outputResult = if (prompt.id == AiPromptTemplates.ActionItems.id) {
            val items = persistActionItems(result.text, segmentIds)
            result.copy(text = ActionItemParser.displayText(items))
        } else {
            result
        }
        val output = aiOutputStore.save(request, outputResult, userConsentedToRemote)
        refreshDiagnostics()
        return output
    }

    suspend fun runAsk(
        question: String,
        segmentIds: List<String>,
        userConsentedToRemote: Boolean,
    ): AiOutput {
        val router = aiRouter ?: throw AiException.ProviderUnavailable("none-configured")
        val excerpts = segmentIds.mapNotNull { segmentId ->
            transcriptStore.load(segmentId)?.let { transcript ->
                val meta = store.readMeta(segmentId)
                TranscriptExcerpt(
                    segmentId = segmentId,
                    text = transcript.text,
                    startTimeMs = meta?.startTimeMs?.toLong(),
                    endTimeMs = meta?.let { segmentEndTimeMs(it) },
                )
            }
        }
        if (excerpts.isEmpty()) {
            throw AiException.ProviderFailed("No transcripts available for the selected segments")
        }
        val gapSummaries = segmentIds.associateWith { id ->
            store.readMeta(id)?.let(::askGapSummary)
        }
        val chunks = askRetriever?.retrieve(question, excerpts, gapSummaries = gapSummaries)
            ?: excerpts.map { excerpt ->
                AskRetriever.RetrievedChunk(
                    segmentId = excerpt.segmentId,
                    text = excerpt.text,
                    startTimeMs = excerpt.startTimeMs,
                    endTimeMs = excerpt.endTimeMs,
                    gapSummary = gapSummaries[excerpt.segmentId],
                )
            }
        // Number sources by the order the output will store them in (distinct excerpt order), so a
        // model `[n]` citation maps directly back to output.segmentIds[n-1] in the answer view.
        val sourceOrder = excerpts.map { it.segmentId }.distinct()
        val context = (askRetriever ?: AskRetriever()).formatForPrompt(chunks) { id ->
            sourceOrder.indexOf(id).takeIf { it >= 0 }?.plus(1)
        }
        val request = AiRunRequest(
            requestId = "ask-${nowMs()}-${aiRunCounter++}",
            prompt = AiPromptTemplate(
                id = AiPromptTemplates.Ask.id,
                title = AiPromptTemplates.Ask.title,
                systemPrompt = AiPromptTemplates.Ask.systemPrompt,
                userPrompt = "Question: $question\n\nTranscripts:\n$context",
            ),
            transcripts = excerpts,
        )
        val augmented = router.run(request)
        val output = aiOutputStore.save(request, augmented, userConsentedToRemote)
        refreshDiagnostics()
        return output
    }

    private fun segmentEndTimeMs(meta: SegmentMeta): Long =
        meta.startTimeMs.toLong() + (meta.frameCount * meta.frameDurationMs)

    private fun askGapSummary(meta: SegmentMeta): String? {
        if (meta.gaps.isEmpty()) return null
        val missingMs = meta.gaps.sumOf { it.missingFrameCount.toLong() * meta.frameDurationMs }
        return "${meta.gaps.size} gap${if (meta.gaps.size == 1) "" else "s"}, " +
            "about ${missingMs}ms missing; answer may be incomplete for this segment."
    }

    fun updateAiOutputText(outputId: String, text: String): AiOutput? {
        val updated = aiOutputStore.updateText(outputId, text)
        if (updated != null) refreshDiagnostics()
        return updated
    }

    fun listDailyDigests(): List<DailyDigest> = digestStore?.list().orEmpty()

    fun listActionItems(): List<ActionItem> = actionItemStore?.list().orEmpty()

    fun setActionItemDone(id: String, done: Boolean): ActionItem? =
        actionItemStore?.setDone(id, done)

    fun listCustomTemplates(): List<SavedAiTemplate> = customTemplateStore?.list().orEmpty()

    fun saveCustomTemplate(title: String, userPrompt: String): SavedAiTemplate? {
        val store = customTemplateStore ?: return null
        return store.save(
            SavedAiTemplate(
                id = "custom-${nowMs()}",
                title = title,
                systemPrompt = AiPromptTemplates.custom(userPrompt).systemPrompt,
                userPrompt = userPrompt,
                createdAtMs = nowMs(),
            ),
        )
    }

    fun deleteCustomTemplate(id: String) {
        customTemplateStore?.delete(id)
    }

    fun listRules(): List<Rule> = ruleStore?.listRules().orEmpty()

    fun saveRule(rule: Rule): Rule? = ruleStore?.saveRule(rule)

    fun deleteRule(id: String) {
        ruleStore?.deleteRule(id)
    }

    fun listRuleRuns(ruleId: String? = null): List<RuleRun> = ruleStore?.listRuns(ruleId).orEmpty()

    fun listSpeakerIdentities(): List<SpeakerIdentity> = speakerIdentityStore?.list().orEmpty()

    fun saveSpeakerIdentity(speakerLabel: String, displayName: String): SpeakerIdentity? {
        val store = speakerIdentityStore ?: return null
        return store.save(
            SpeakerIdentity(
                speakerLabel = speakerLabel,
                displayName = displayName,
                updatedAtMs = nowMs(),
            ),
        )
    }

    private suspend fun donateEnrichedSegments() {
        val donator = transcriptIndexDonator ?: return
        store.listSegments().forEach { meta ->
            val annotation = annotationStore.load(meta.segmentId) ?: return@forEach
            donator.donateSegment(
                segmentId = meta.segmentId,
                annotation = annotation,
                fullTranscript = transcriptStore.load(meta.segmentId)?.text,
                startDateMs = meta.startTimeMs.toLong(),
            )
        }
    }

    private suspend fun persistActionItems(raw: String, segmentIds: List<String>): List<ActionItem> {
        val store = actionItemStore ?: return emptyList()
        val donator = transcriptIndexDonator
        val sourceId = segmentIds.firstOrNull() ?: return emptyList()
        val savedItems = mutableListOf<ActionItem>()
        ActionItemParser.parse(raw, sourceId, nowMs()).forEach { item ->
            val saved = store.save(item)
            savedItems += saved
            donator?.donateActionItem(saved)
        }
        return savedItems
    }

    fun listAiOutputs(): List<AiOutput> = aiOutputStore.list()

    fun deleteAiOutput(outputId: String) {
        aiOutputStore.delete(outputId)
        refreshDiagnostics()
    }

    val personalContext: StateFlow<PersonalContext> =
        personalContextCoordinator?.state ?: defaultPersonalContextFlow

    fun setPersonalContextProfileText(text: String?) {
        val coordinator = personalContextCoordinator ?: return
        val scope = processingScope ?: return
        coordinator.setProfileText(text, scope)
    }

    fun clearPersonalContext() {
        val coordinator = personalContextCoordinator ?: return
        val scope = processingScope ?: return
        coordinator.clear(scope)
    }

    fun importContactsIntoPersonalContext() {
        importPersonalContext { importer, timestamp -> importer.importContacts(timestamp) }
    }

    fun importCalendarIntoPersonalContext() {
        importPersonalContext { importer, timestamp -> importer.importCalendar(timestamp) }
    }

    private fun importPersonalContext(
        block: suspend (PersonalContextImporter, Long) -> PersonalContextImport,
    ) {
        val coordinator = personalContextCoordinator ?: return
        val importer = personalContextImporter ?: return
        val scope = processingScope ?: return
        scope.launch {
            try {
                val imported = block(importer, nowMs())
                coordinator.mergeImported(imported, scope)
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                logBackgroundFailure("personal context import", t)
            }
        }
    }

    suspend fun refreshDailyDigests() {
        dailyRecapEngine?.refreshDigests()
    }

    private var aiRunCounter = 0

    suspend fun revokeReceiverLocally() {
        stop()
        link.disconnect()
        resumeStore.clear()
        refreshDiagnostics()
    }

    fun buildSupportReport(includeContent: Boolean): AudioCompanionSupportReport {
        refreshDiagnostics()
        return AudioCompanionSupportReport(
            generatedAtMs = nowMs(),
            receiverState = state.value.toString(),
            diagnostics = diagnostics.value,
            includeContent = includeContent,
        )
    }

    private suspend fun runTranscriptionLoop() {
        while (true) {
            val sleepMs = try {
                runTranscriptionPass()
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                logBackgroundFailure("transcription loop", t)
                TRANSCRIPTION_FAILURE_BACKOFF_MS
            }
            withTimeoutOrNull(sleepMs) { transcriptionWakeups.receive() }
        }
    }

    private suspend fun runTranscriptionPass(): Long {
        if (!foreground.value) {
            // Background: receive-only. Defer all heavy processing (local STT, live preview, AI
            // enrichment, WAV export) and release the local model so a ~10s Bluetooth wake stays
            // cheap and the app is not a jetsam target. Pending segments stay queued and are
            // transcribed when the app returns to the foreground (or in a BGProcessing catch-up
            // burst). Yield the model to an in-progress burst instead of releasing it under it.
            if (!backgroundCatchUpActive.value) {
                localTranscriptionLifecycle?.releaseModel("background")
            }
            return BACKGROUND_PROCESSING_SLEEP_MS
        }
        // Segments parked while no provider was usable become eligible again the moment
        // one is (model downloaded, key added, mode changed).
        if (transcriptionProcessor.reconsiderDisabled().isNotEmpty()) {
            refreshDiagnostics()
        }
        enqueueClosedSegmentsForTranscription()
        var processed = false
        processingMutex.withLock {
            while (transcriptionProcessor.processNext() != null) {
                processed = true
                refreshDiagnostics()
            }
        }
        // Row titles/summaries: a provisional pass refreshes the open segment from the live
        // preview, and a final authoritative pass follows transcription of closed segments. The
        // worker is a no-op when AI is not configured; rows then show transcript snippets instead.
        if (enrichmentWorker.enrich(store.listSegments(), transcriptStore::load, ::liveTranscript).isNotEmpty()) {
            refreshDiagnostics()
            donateEnrichedSegments()
        }
        runCatching { dailyRecapEngine?.refreshDigests() }
        ruleEvaluator?.let { evaluator ->
            runCatching { evaluator.evaluateDueRules() }
        }
        // Live preview of the open segment, after the durable closed-segment work (same
        // loop, so a possibly single-instance native model is never used concurrently).
        liveTranscriber?.let { live ->
            if (live.processOnce()) processed = true
            live.prune { segmentId -> transcriptStore.load(segmentId) != null }
        }
        cloudLiveTranscriber?.prune { segmentId -> transcriptStore.load(segmentId) != null }
        exportClosedSegmentsIfEnabled()
        // Shrink the foreground footprint between bursts: release the resident local model once it
        // has been idle. It reloads lazily on the next segment (selected-model changes are also
        // picked up here, since the reload uses the current model).
        if (!processed) {
            localTranscriptionLifecycle?.releaseModelIfIdle(nowMs(), LOCAL_MODEL_IDLE_TIMEOUT_MS)
        }
        // Sleep until the poll interval elapses, a failed task's backoff expires, or a
        // config change (model downloaded, key/mode/consent changed) wakes the loop.
        return when {
            processed -> 1_000L
            // While recording, wake often enough that the live preview feels live.
            store.openSegmentId != null && liveTranscriber != null -> LIVE_PREVIEW_POLL_MS
            else -> {
                val retryInMs = transcriptionProcessor.nextRetryAtMs()?.let { it - nowMs() }
                retryInMs?.coerceIn(1_000L, TRANSCRIPTION_POLL_MS) ?: TRANSCRIPTION_POLL_MS
            }
        }
    }

    /** Wakes the transcription loop early; call after transcription settings change. */
    fun notifyTranscriptionConfigChanged() {
        transcriptionWakeups.trySend(Unit)
    }

    fun notifyExportConfigChanged() {
        transcriptionWakeups.trySend(Unit)
    }

    private suspend fun exportClosedSegmentsIfEnabled() {
        val manager = exportManager ?: return
        if (!automaticWavExportEnabled()) return
        manager.exportAllClosedSegments(overwrite = false)
    }

    private fun enqueueClosedSegmentsForTranscription() {
        transcriptionProcessor.enqueueClosedSegments(
            store.listSegments()
                .filter { !it.isOpen && !it.isFullyTranscribed }
                .map { it.segmentId },
        )
    }

    companion object {
        private const val TRANSCRIPTION_POLL_MS = 30_000L
        private const val LIVE_PREVIEW_POLL_MS = 5_000L
        private const val TRANSCRIPTION_FAILURE_BACKOFF_MS = 5_000L

        /** Long idle sleep while backgrounded; [setForeground] wakes the loop on return. */
        private const val BACKGROUND_PROCESSING_SLEEP_MS = 60_000L

        /** Release the resident local model after this much foreground idle time. */
        private const val LOCAL_MODEL_IDLE_TIMEOUT_MS = 30_000L

        /**
         * Cap on segments transcribed per BGProcessing catch-up burst. Keeps a single background
         * window bounded; anything not reached stays queued for the next window or the foreground.
         */
        const val BACKGROUND_CATCHUP_MAX_SEGMENTS = 10

        fun segmentTranscriptionState(state: TaskState): SegmentTranscriptionState = when (state) {
            TaskState.Pending -> SegmentTranscriptionState.Pending
            TaskState.Running -> SegmentTranscriptionState.Running
            TaskState.Uploading -> SegmentTranscriptionState.Uploading
            TaskState.Complete -> SegmentTranscriptionState.Complete
            TaskState.NoSpeech -> SegmentTranscriptionState.NoSpeech
            TaskState.Failed -> SegmentTranscriptionState.Failed
            TaskState.Disabled -> SegmentTranscriptionState.Disabled
        }
    }
}
