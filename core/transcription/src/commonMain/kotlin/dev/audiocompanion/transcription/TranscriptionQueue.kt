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
 * Durable transcription queue. One JSON file per task under `<root>/transcription/queue/`,
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

    /**
     * In-memory index of tasks by segment id, the read source of truth (disk is the durable
     * mirror). Without it `all()`/`load()` re-list and re-parse every task file on each call, and
     * `refreshDiagnostics()` calls `all()` constantly. Copy-on-write immutable map, same lock-free
     * posture as `SegmentStore.metaIndex`.
     */
    private var index: Map<String, TranscriptionTask>? = null

    private fun taskPath(segmentId: String) = Path(queueDir, "$segmentId.task.json")

    private fun ensureIndex(): Map<String, TranscriptionTask> =
        index ?: buildIndexFromDisk().also { index = it }

    private fun buildIndexFromDisk(): Map<String, TranscriptionTask> {
        if (!fileSystem.exists(queueDir)) return emptyMap()
        val map = LinkedHashMap<String, TranscriptionTask>()
        fileSystem.list(queueDir)
            .filter { it.name.endsWith(".task.json") }
            .forEach { path ->
                val id = path.name.removeSuffix(".task.json")
                readFromDisk(id)?.let { map[id] = it }
            }
        return map
    }

    private fun readFromDisk(segmentId: String): TranscriptionTask? {
        val path = taskPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(TranscriptionTask.serializer(), text) }.getOrNull()
    }

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

    fun load(segmentId: String): TranscriptionTask? = ensureIndex()[segmentId]

    fun all(): List<TranscriptionTask> = ensureIndex().values.sortedBy { it.createdAtMs }

    /**
     * Oldest Pending task, or a retryable Failed one whose backoff has elapsed. Failed tasks
     * back off exponentially with [retryBackoffMs] so a persistently failing segment cannot
     * spin the worker loop.
     */
    fun nextRunnable(): TranscriptionTask? {
        val tasks = all()
        return tasks.firstOrNull { it.state == TaskState.Pending }
            ?: tasks.firstOrNull {
                it.state == TaskState.Failed && it.retryable &&
                    nowMs() >= it.updatedAtMs + retryBackoffMs(it.attempts)
            }
    }

    /**
     * Soonest time a Failed-retryable task becomes runnable, or null when nothing is waiting on
     * backoff. Lets the worker sleep precisely instead of polling.
     */
    fun nextRetryAtMs(): Long? = all()
        .filter { it.state == TaskState.Failed && it.retryable }
        .minOfOrNull { it.updatedAtMs + retryBackoffMs(it.attempts) }

    /**
     * Tasks parked as Disabled (no provider was usable when they ran) go back to Pending —
     * called when transcription becomes available again (model downloaded, key added, mode
     * changed). Returns the segment ids that were reset.
     */
    fun resetDisabled(): List<String> =
        all().filter { it.state == TaskState.Disabled }
            .map { task ->
                write(task.copy(state = TaskState.Pending, updatedAtMs = nowMs()))
                task.segmentId
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
            it.copy(
                state = TaskState.Failed,
                lastError = error,
                retryable = retryable && it.attempts < MAX_ATTEMPTS,
            )
        }

    fun markDisabled(segmentId: String): TranscriptionTask? = update(segmentId) {
        it.copy(state = TaskState.Disabled)
    }

    fun delete(segmentId: String) {
        fileSystem.delete(taskPath(segmentId), mustExist = false)
        fileSystem.delete(Path(queueDir, "$segmentId.task.json.tmp"), mustExist = false)
        index = index?.minus(segmentId)
    }

    fun deleteAll() {
        index = emptyMap()
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
        index?.let { index = it + (task.segmentId to task) }
    }

    companion object {
        /** After this many attempts a failing task stops retrying and stays Failed. */
        const val MAX_ATTEMPTS = 8

        /** Exponential backoff: 30 s, 1 m, 2 m, … capped at 30 m. */
        fun retryBackoffMs(attempts: Int): Long {
            val exponent = (attempts - 1).coerceIn(0, 6)
            return (30_000L shl exponent).coerceAtMost(30 * 60_000L)
        }
    }
}
