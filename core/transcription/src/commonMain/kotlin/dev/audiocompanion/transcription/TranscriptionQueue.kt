package dev.audiocompanion.transcription

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
enum class TaskState {
    Pending,
    Running,
    Complete,
    NoSpeech,
    Failed,
    Disabled,
}

@Serializable
data class TranscriptionTask(
    val segmentId: String,
    val state: TaskState = TaskState.Pending,
    val attempts: Int = 0,
    val retryable: Boolean = true,
    val lastError: String? = null,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    /** Provenance: routing mode that produced the final transcript. */
    val modeUsed: TranscriptionMode? = null,
    val providerId: String? = null,
    val modelUsed: String? = null,
)

/**
 * DB-less durable transcription queue (plan 6.5; the DB-backed version is deferred together
 * with the segment index DB). One JSON file per task under `<root>/transcription/queue/`,
 * written via temp file + atomic rename, so the queue survives process death; [recoverOnStart]
 * returns tasks that died mid-run to Pending.
 */
class FileTranscriptionQueue(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val queueDir = Path(Path(root, "transcription"), "queue")

    private fun taskPath(segmentId: String) = Path(queueDir, "$segmentId.task.json")

    /** Adds a Pending task for [segmentId]; no-op when a task already exists. */
    fun enqueue(segmentId: String): TranscriptionTask {
        load(segmentId)?.let { return it }
        val task = TranscriptionTask(
            segmentId = segmentId,
            createdAtMs = nowMs(),
            updatedAtMs = nowMs(),
        )
        write(task)
        return task
    }

    fun load(segmentId: String): TranscriptionTask? {
        val path = taskPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(TranscriptionTask.serializer(), text) }.getOrNull()
    }

    fun all(): List<TranscriptionTask> {
        if (!fileSystem.exists(queueDir)) return emptyList()
        return fileSystem.list(queueDir)
            .filter { it.name.endsWith(".task.json") }
            .mapNotNull { load(it.name.removeSuffix(".task.json")) }
            .sortedBy { it.createdAtMs }
    }

    /** Oldest Pending task, or a retryable Failed one when no Pending exists. */
    fun nextRunnable(): TranscriptionTask? {
        val tasks = all()
        return tasks.firstOrNull { it.state == TaskState.Pending }
            ?: tasks.firstOrNull { it.state == TaskState.Failed && it.retryable }
    }

    fun markRunning(segmentId: String): TranscriptionTask? = update(segmentId) {
        it.copy(state = TaskState.Running, attempts = it.attempts + 1)
    }

    fun markComplete(segmentId: String, result: RoutedTranscription): TranscriptionTask? =
        update(segmentId) {
            it.copy(
                state = TaskState.Complete,
                lastError = null,
                modeUsed = result.modeUsed,
                providerId = result.providerId,
                modelUsed = result.modelUsed,
            )
        }

    fun markNoSpeech(segmentId: String): TranscriptionTask? = update(segmentId) {
        it.copy(state = TaskState.NoSpeech, lastError = null)
    }

    fun markFailed(segmentId: String, error: String, retryable: Boolean): TranscriptionTask? =
        update(segmentId) {
            it.copy(state = TaskState.Failed, lastError = error, retryable = retryable)
        }

    fun markDisabled(segmentId: String): TranscriptionTask? = update(segmentId) {
        it.copy(state = TaskState.Disabled)
    }

    fun deleteAll() {
        if (!fileSystem.exists(queueDir)) return
        fileSystem.list(queueDir)
            .filter { it.name.endsWith(".task.json") || it.name.endsWith(".task.json.tmp") }
            .forEach { fileSystem.delete(it, mustExist = false) }
    }

    /** Process-restart recovery: tasks that died mid-run go back to Pending. */
    fun recoverOnStart() {
        all().filter { it.state == TaskState.Running }
            .forEach { write(it.copy(state = TaskState.Pending, updatedAtMs = nowMs())) }
    }

    private fun update(
        segmentId: String,
        transform: (TranscriptionTask) -> TranscriptionTask,
    ): TranscriptionTask? {
        val task = load(segmentId) ?: return null
        val updated = transform(task).copy(updatedAtMs = nowMs())
        write(updated)
        return updated
    }

    private fun write(task: TranscriptionTask) {
        fileSystem.createDirectories(queueDir)
        val tmp = Path(queueDir, "${task.segmentId}.task.json.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(TranscriptionTask.serializer(), task).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, taskPath(task.segmentId))
    }
}
