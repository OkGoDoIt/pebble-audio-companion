package dev.audiocompanion.app

import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.storage.TranscriptionState as SegmentTranscriptionState
import dev.audiocompanion.transcription.FileTranscriptStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
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
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

data class AudioCompanionDiagnostics(
    val segmentCount: Int = 0,
    val openSegmentId: String? = null,
    val queuedTranscriptionTasks: Int = 0,
    val failedTranscriptionTasks: Int = 0,
    val lowStorage: Boolean = false,
    val pauseRequested: Boolean = false,
    val freeStorageHintKb: UInt = 0u,
    val aiOutputCount: Int = 0,
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
) {
    private val enrichmentWorker = SegmentEnrichmentWorker(
        annotations = annotationStore,
        router = aiRouter,
        nowMs = nowMs,
    )
    private val watchEnableRequestArmed = MutableStateFlow(false)

    private val session = AudioReceiverSession(
        link = link,
        sink = liveMonitor?.let { TeeSegmentSink(store, it, nowMs) } ?: store,
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
    private var durableStateRecovered = false
    private var sessionJob: Job? = null
    private var transcriptionJob: Job? = null
    private val transcriptionWakeups = Channel<Unit>(Channel.CONFLATED)

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
            if (transcriptionJob == null) {
                transcriptionJob = scope.launch { runTranscriptionLoop() }
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
        )
    }

    val audioExportDirectory: String?
        get() = exportManager?.directory

    suspend fun deleteAllLocalData() {
        stop()
        link.disconnect()
        playback?.stop()
        store.closeSegment(SegmentCloseReason.Interrupted)
        store.listSegments().forEach { store.deleteSegment(it.segmentId) }
        transcriptionQueue.deleteAll()
        transcriptStore.deleteAll()
        annotationStore.deleteAll()
        aiOutputStore.deleteAll()
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
            .filter { it.segmentIds == listOf(segmentId) }
            .forEach { aiOutputStore.delete(it.outputId) }
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
    fun liveTranscript(segmentId: String): String? = liveTranscriber?.textFor(segmentId)

    /** Full live-preview progress (text + transcribed boundary) for waveform coloring. */
    fun liveTranscriptPreview(segmentId: String): LiveTranscriptPreview? =
        liveTranscriber?.previewFor(segmentId)

    /** Live preview progress as a flow so visible screens can update without a tab reload. */
    val liveTranscriptPreviews: StateFlow<Map<String, LiveTranscriptPreview>> =
        liveTranscriber?.previews ?: emptyLiveTranscriptPreviews.asStateFlow()

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
        val output = aiOutputStore.save(request, result, userConsentedToRemote)
        refreshDiagnostics()
        return output
    }

    fun listAiOutputs(): List<AiOutput> = aiOutputStore.list()

    fun deleteAiOutput(outputId: String) {
        aiOutputStore.delete(outputId)
        refreshDiagnostics()
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
            // Segments parked while no provider was usable become eligible again the moment
            // one is (model downloaded, key added, mode changed).
            if (transcriptionProcessor.reconsiderDisabled().isNotEmpty()) {
                refreshDiagnostics()
            }
            enqueueClosedSegmentsForTranscription()
            var processed = false
            while (transcriptionProcessor.processNext() != null) {
                processed = true
                refreshDiagnostics()
            }
            // Row titles/summaries follow transcription (MVP requirement). The worker is a
            // no-op when AI is not configured; rows then show transcript snippets instead.
            if (enrichmentWorker.enrich(store.listSegments(), transcriptStore::load).isNotEmpty()) {
                refreshDiagnostics()
            }
            // Live preview of the open segment, after the durable closed-segment work (same
            // loop, so a possibly single-instance native model is never used concurrently).
            liveTranscriber?.let { live ->
                if (live.processOnce()) processed = true
                live.prune { segmentId -> transcriptStore.load(segmentId) != null }
            }
            exportClosedSegmentsIfEnabled()
            // Sleep until the poll interval elapses, a failed task's backoff expires, or a
            // config change (model downloaded, key/mode/consent changed) wakes the loop.
            val sleepMs = when {
                processed -> 1_000L
                // While recording, wake often enough that the live preview feels live.
                store.openSegmentId != null && liveTranscriber != null -> LIVE_PREVIEW_POLL_MS
                else -> {
                    val retryInMs = transcriptionProcessor.nextRetryAtMs()?.let { it - nowMs() }
                    retryInMs?.coerceIn(1_000L, TRANSCRIPTION_POLL_MS) ?: TRANSCRIPTION_POLL_MS
                }
            }
            withTimeoutOrNull(sleepMs) { transcriptionWakeups.receive() }
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

        fun segmentTranscriptionState(state: TaskState): SegmentTranscriptionState = when (state) {
            TaskState.Pending -> SegmentTranscriptionState.Pending
            TaskState.Running -> SegmentTranscriptionState.Running
            TaskState.Complete -> SegmentTranscriptionState.Complete
            TaskState.NoSpeech -> SegmentTranscriptionState.NoSpeech
            TaskState.Failed -> SegmentTranscriptionState.Failed
            TaskState.Disabled -> SegmentTranscriptionState.Disabled
        }
    }
}
