package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** One extracted action item linked to its source segment. */
@Serializable
data class ActionItem(
    val id: String,
    val text: String,
    val done: Boolean = false,
    val sourceSegmentId: String,
    val createdAtMs: Long,
)

class FileActionItemStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val itemsDir = Path(Path(root, "ai"), "action_items")

    private fun path(id: String) = Path(itemsDir, "$id.action.json")

    fun save(item: ActionItem): ActionItem {
        val stamped = if (item.createdAtMs == 0L) item.copy(createdAtMs = nowMs()) else item
        write(stamped)
        return stamped
    }

    fun load(id: String): ActionItem? {
        val p = path(id)
        if (!fileSystem.exists(p)) return null
        val text = fileSystem.source(p).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(ActionItem.serializer(), text) }.getOrNull()
    }

    fun list(): List<ActionItem> =
        if (!fileSystem.exists(itemsDir)) emptyList()
        else fileSystem.list(itemsDir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { load(it.name.removeSuffix(SUFFIX)) }
            .sortedByDescending { it.createdAtMs }

    fun delete(id: String) {
        fileSystem.delete(path(id), mustExist = false)
    }

    fun deleteAll() {
        if (!fileSystem.exists(itemsDir)) return
        fileSystem.list(itemsDir)
            .filter { it.name.endsWith(SUFFIX) || it.name.endsWith("$SUFFIX.tmp") }
            .forEach { fileSystem.delete(it, mustExist = false) }
    }

    fun setDone(id: String, done: Boolean): ActionItem? {
        val existing = load(id) ?: return null
        return save(existing.copy(done = done))
    }

    private fun write(item: ActionItem) {
        fileSystem.createDirectories(itemsDir)
        val tmp = Path(itemsDir, "${item.id}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(ActionItem.serializer(), item).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, path(item.id))
    }

    companion object {
        const val SUFFIX = ".action.json"
    }
}

/** Parses action-item template output into structured items. */
object ActionItemParser {
    fun parse(raw: String, sourceSegmentId: String, nowMs: Long, idPrefix: String = sourceSegmentId): List<ActionItem> {
        val lines = raw.lines()
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .map { line ->
                line.removePrefix("-").removePrefix("*").trim()
                    .removePrefix("[ ]").removePrefix("[x]").removePrefix("[X]").trim()
            }
            .filter { it.isNotBlank() }
        return lines.mapIndexed { index, text ->
            ActionItem(
                id = "$idPrefix-action-$index",
                text = text,
                sourceSegmentId = sourceSegmentId,
                createdAtMs = nowMs,
            )
        }
    }
}
