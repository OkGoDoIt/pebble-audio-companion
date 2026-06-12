package dev.audiocompanion.app

import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileAiOutputStore
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

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
    private val receiverConfig: ReceiverConfig,
    private val nowMs: () -> Long,
    /** Null when the app ships without any AI provider wiring (AI screen shows setup state). */
    private val aiRouter: AiModeRouter? = null,
) {
    private val session = AudioReceiverSession(
        link = link,
        sink = store,
        policy = retention,
        resumeStore = resumeStore,
        config = receiverConfig,
        nowMs = nowMs,
    )

    val state: StateFlow<ReceiverSessionState> = session.state
    val diagnostics: StateFlow<AudioCompanionDiagnostics> get() = _diagnostics.asStateFlow()

    private val _diagnostics = MutableStateFlow(AudioCompanionDiagnostics())
    private var sessionJob: Job? = null
    private var transcriptionJob: Job? = null

    fun recoverDurableState() {
        store.recover()
        transcriptionQueue.recoverOnStart()
        retention.enforce().forEach { deletedSegmentId ->
            transcriptionQueue.delete(deletedSegmentId)
            transcriptStore.delete(deletedSegmentId)
        }
        enqueueClosedSegmentsForTranscription()
        refreshDiagnostics()
    }

    fun start(scope: CoroutineScope): Job {
        recoverDurableState()
        if (transcriptionJob == null) {
            transcriptionJob = scope.launch { runTranscriptionLoop() }
        }
        return sessionJob ?: session.start(scope).also { sessionJob = it }
    }

    fun stop() {
        sessionJob?.cancel()
        sessionJob = null
        transcriptionJob?.cancel()
        transcriptionJob = null
        refreshDiagnostics()
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

    suspend fun deleteAllLocalData() {
        stop()
        store.closeSegment(SegmentCloseReason.Interrupted)
        store.listSegments().forEach { store.deleteSegment(it.segmentId) }
        transcriptionQueue.deleteAll()
        transcriptStore.deleteAll()
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
        store.deleteSegment(segmentId)
        transcriptionQueue.delete(segmentId)
        transcriptStore.delete(segmentId)
        aiOutputStore.list()
            .filter { it.segmentIds == listOf(segmentId) }
            .forEach { aiOutputStore.delete(it.outputId) }
        refreshDiagnostics()
    }

    /** Durable segment snapshot for UI lists (file-backed; cheap at MVP scale). */
    fun listSegmentsForUi(): List<SegmentMeta> = store.listSegments()

    fun transcript(segmentId: String): SegmentTranscript? = transcriptStore.load(segmentId)

    fun listTranscripts(): List<SegmentTranscript> = transcriptStore.list()

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
            enqueueClosedSegmentsForTranscription()
            var processed = false
            while (transcriptionProcessor.processNext() != null) {
                processed = true
                refreshDiagnostics()
            }
            delay(if (processed) 1_000 else TRANSCRIPTION_POLL_MS)
        }
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
