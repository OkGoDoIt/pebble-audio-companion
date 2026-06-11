package dev.audiocompanion.app

import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.TaskState
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.AudioReceiverSession
import dev.audiocompanion.transport.ReceiverConfig
import dev.audiocompanion.transport.ReceiverSessionState
import dev.audiocompanion.transport.ReceiverResumeStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class AudioCompanionDiagnostics(
    val segmentCount: Int = 0,
    val openSegmentId: String? = null,
    val queuedTranscriptionTasks: Int = 0,
    val failedTranscriptionTasks: Int = 0,
    val lowStorage: Boolean = false,
    val pauseRequested: Boolean = false,
    val freeStorageHintKb: UInt = 0u,
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
    private val receiverConfig: ReceiverConfig,
    private val nowMs: () -> Long,
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

    fun recoverDurableState() {
        store.recover()
        transcriptionQueue.recoverOnStart()
        retention.enforce()
        refreshDiagnostics()
    }

    fun start(scope: CoroutineScope): Job {
        recoverDurableState()
        return sessionJob ?: session.start(scope).also { sessionJob = it }
    }

    fun stop() {
        sessionJob?.cancel()
        sessionJob = null
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
        )
    }
}
