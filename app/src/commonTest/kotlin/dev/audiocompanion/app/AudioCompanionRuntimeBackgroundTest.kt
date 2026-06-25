package dev.audiocompanion.app

import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.storage.FileReceiverResumeStore
import dev.audiocompanion.storage.FreeSpaceProvider
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.LocalTranscriptionLifecycle
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.LinkState
import dev.audiocompanion.transport.ReceiverConfig
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Background processing policy (plan: "Split receive from process"). Receiving keeps running, but
 * the heavy processing loop must defer and release the local model while backgrounded so a short
 * Core Bluetooth wake stays cheap.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AudioCompanionRuntimeBackgroundTest {

    private class RecordingLifecycle : LocalTranscriptionLifecycle {
        val releaseReasons = mutableListOf<String>()
        var idleChecks = 0
            private set

        override suspend fun releaseModel(reason: String) {
            releaseReasons += reason
        }

        override suspend fun releaseModelIfIdle(nowMs: Long, idleTimeoutMs: Long) {
            idleChecks += 1
        }
    }

    /** A link that never connects: the receiver session idles and never reads/streams. */
    private class IdleGattLink : AudioGattLink {
        override val connectionState: StateFlow<LinkState> = MutableStateFlow(LinkState.Disconnected)
        override val lastError: StateFlow<String?> = MutableStateFlow(null)
        override suspend fun readInfo(): ByteArray = ByteArray(0)
        override suspend fun writeControl(message: ByteArray) {}
        override val controlNotifications: Flow<ByteArray> = emptyFlow()
        override val dataNotifications: Flow<ByteArray> = emptyFlow()
    }

    private fun newRuntime(): Pair<AudioCompanionRuntime, RecordingLifecycle> {
        val root = Path(SystemTemporaryDirectory, "runtime-bg-${Random.nextLong()}")
        SystemFileSystem.createDirectories(root)
        val nowMs = { 0L }
        val store = SegmentStore(SystemFileSystem, root, nowMs)
        val retention = RetentionManager(
            store = store,
            freeSpace = object : FreeSpaceProvider {
                override fun freeBytes(): Long = Long.MAX_VALUE
            },
            nowMs = nowMs,
        )
        val queue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val transcriptStore = FileTranscriptStore(SystemFileSystem, root, nowMs)
        val router = TranscriptionModeRouter(
            local = null,
            remote = null,
            mode = { TranscriptionMode.LocalOnly },
        )
        val lifecycle = RecordingLifecycle()
        val runtime = AudioCompanionRuntime(
            link = IdleGattLink(),
            store = store,
            retention = retention,
            resumeStore = FileReceiverResumeStore(SystemFileSystem, root),
            transcriptionQueue = queue,
            transcriptionProcessor = TranscriptionProcessor(
                queue = queue,
                router = router,
                pcmSource = { emptyFlow() },
                transcriptStore = transcriptStore,
            ),
            transcriptStore = transcriptStore,
            aiOutputStore = FileAiOutputStore(SystemFileSystem, root, nowMs),
            annotationStore = FileSegmentAnnotationStore(SystemFileSystem, root, nowMs),
            receiverConfig = ReceiverConfig(
                receiverId = Random.nextBytes(32),
                receiverName = "test",
            ),
            nowMs = nowMs,
            localTranscriptionLifecycle = lifecycle,
        )
        return runtime to lifecycle
    }

    @Test
    fun backgroundMarksTranscriptionPausedInDiagnostics() = runTest {
        val (runtime, _) = newRuntime()
        runtime.refreshDiagnostics()
        assertFalse(runtime.diagnostics.value.transcriptionPausedInBackground)

        runtime.setForeground(false)
        assertTrue(runtime.diagnostics.value.transcriptionPausedInBackground)

        runtime.setForeground(true)
        assertFalse(runtime.diagnostics.value.transcriptionPausedInBackground)
    }

    @Test
    fun backgroundReleasesLocalModel() = runTest {
        val (runtime, lifecycle) = newRuntime()
        runtime.start(backgroundScope)
        runCurrent() // let the initial foreground pass run and suspend

        runtime.setForeground(false)
        runCurrent() // background release runs

        assertTrue(
            lifecycle.releaseReasons.contains("background"),
            "expected the local model to be released on background; got ${lifecycle.releaseReasons}",
        )
    }

    @Test
    fun foregroundIdlePassChecksForModelRelease() = runTest {
        val (runtime, lifecycle) = newRuntime()
        runtime.start(backgroundScope)
        runCurrent()

        assertTrue(
            lifecycle.idleChecks > 0,
            "expected the foreground loop to evaluate idle model release",
        )
    }
}
