package dev.audiocompanion.transcription

import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileTranscriptionQueueTest {

    private var clock = 1_000L

    private fun tempRoot(): Path {
        val dir = File.createTempFile("txqueue", null).apply { delete(); mkdirs() }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun queue(root: Path) = FileTranscriptionQueue(SystemFileSystem, root, { clock })

    @Test
    fun enqueueIsIdempotentAndDurable() {
        val root = tempRoot()
        val q = queue(root)
        val task = q.enqueue("seg-1")
        assertEquals(TaskState.Pending, task.state)
        clock += 5
        assertEquals(task, q.enqueue("seg-1"), "second enqueue must not reset the task")

        // Visible from a fresh instance (process restart).
        assertEquals(task, queue(root).load("seg-1"))
    }

    @Test
    fun lifecyclePendingRunningComplete_recordsProvenance() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")

        val running = assertNotNull(q.markRunning("seg-1"))
        assertEquals(TaskState.Running, running.state)
        assertEquals(1, running.attempts)

        val result = RoutedTranscription(
            text = "hello",
            modeUsed = TranscriptionMode.RemoteOnly,
            providerId = "cloud",
            modelUsed = "model-v2",
        )
        val complete = assertNotNull(q.markComplete("seg-1", result))
        assertEquals(TaskState.Complete, complete.state)
        assertEquals(TranscriptionMode.RemoteOnly, complete.modeUsed)
        assertEquals("cloud", complete.providerId)
        assertEquals("model-v2", complete.modelUsed)
        assertNull(q.nextRunnable())
    }

    @Test
    fun failedRetryableTasksAreRunnable_nonRetryableAreNot() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.markRunning("seg-1")
        q.markFailed("seg-1", "timeout", retryable = true)
        assertEquals("seg-1", q.nextRunnable()?.segmentId)

        q.markRunning("seg-1")
        q.markFailed("seg-1", "decode error", retryable = false)
        assertNull(q.nextRunnable())
        assertEquals(2, q.load("seg-1")?.attempts)
        assertEquals("decode error", q.load("seg-1")?.lastError)
    }

    @Test
    fun pendingIsPreferredOverRetryableFailed_oldestFirst() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-old-failed")
        q.markRunning("seg-old-failed")
        q.markFailed("seg-old-failed", "x", retryable = true)
        clock += 10
        q.enqueue("seg-a")
        clock += 10
        q.enqueue("seg-b")

        assertEquals("seg-a", q.nextRunnable()?.segmentId)
    }

    @Test
    fun noSpeechAndDisabledAreTerminal() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.enqueue("seg-2")
        q.markNoSpeech("seg-1")
        q.markDisabled("seg-2")
        assertEquals(TaskState.NoSpeech, q.load("seg-1")?.state)
        assertEquals(TaskState.Disabled, q.load("seg-2")?.state)
        assertNull(q.nextRunnable())
    }

    @Test
    fun recoverOnStart_returnsRunningTasksToPending() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.markRunning("seg-1")

        // Process death and restart.
        val q2 = queue(root)
        q2.recoverOnStart()
        val task = assertNotNull(q2.load("seg-1"))
        assertEquals(TaskState.Pending, task.state)
        assertEquals(1, task.attempts, "attempts survive recovery")
        assertEquals("seg-1", q2.nextRunnable()?.segmentId)
    }

    @Test
    fun deleteAllRemovesTasks() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.enqueue("seg-2")

        q.deleteAll()

        assertTrue(q.all().isEmpty())
        assertNull(q.load("seg-1"))
        assertNull(q.load("seg-2"))
    }

    @Test
    fun deleteRemovesSingleTask() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.enqueue("seg-2")

        q.delete("seg-1")

        assertNull(q.load("seg-1"))
        assertEquals("seg-2", q.load("seg-2")?.segmentId)
    }

    @Test
    fun atomicWrites_leaveNoTempFiles() {
        val root = tempRoot()
        val q = queue(root)
        q.enqueue("seg-1")
        q.markRunning("seg-1")
        q.markFailed("seg-1", "x", retryable = true)
        val dir = File(root.toString(), "transcription/queue")
        val leftovers = dir.listFiles().orEmpty().filter { it.name.endsWith(".tmp") }
        assertTrue(leftovers.isEmpty(), "temp files left behind: $leftovers")
    }
}
