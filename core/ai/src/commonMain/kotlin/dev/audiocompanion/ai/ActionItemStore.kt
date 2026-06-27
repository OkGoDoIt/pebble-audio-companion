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

@Serializable
data class ExtractedActionItems(
    val items: List<ExtractedActionItem>,
)

@Serializable
data class ExtractedActionItem(
    val task: String,
    val owner: String = "",
    val due: String = "",
    val sourceSegmentId: String = "",
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
    private val json = Json { ignoreUnknownKeys = true }

    fun parse(raw: String, sourceSegmentId: String, nowMs: Long, idPrefix: String = sourceSegmentId): List<ActionItem> {
        parseStructured(raw, sourceSegmentId, nowMs, idPrefix)?.let { return it }
        if (raw.contains("no action items", ignoreCase = true)) return emptyList()
        val lines = raw.lines()
            .mapNotNull(::cleanActionLine)
            .filterNot { line ->
                val normalized = line.lowercase()
                normalized.startsWith("here are ") ||
                    normalized.startsWith("action items") ||
                    normalized.startsWith("owner:") ||
                    normalized == "tasks" ||
                    normalized == "task"
            }
            .distinct()
        return lines.mapIndexed { index, text ->
            ActionItem(
                id = "$idPrefix-action-$index",
                text = text,
                sourceSegmentId = sourceSegmentId,
                createdAtMs = nowMs,
            )
        }
    }

    fun parseStructured(
        raw: String,
        fallbackSourceSegmentId: String,
        nowMs: Long,
        idPrefix: String = fallbackSourceSegmentId,
    ): List<ActionItem>? {
        val parsed = runCatching {
            json.decodeFromString(ExtractedActionItems.serializer(), raw.trim())
        }.getOrNull() ?: return null
        return parsed.items
            .mapIndexedNotNull { index, item ->
                val task = item.task.trim()
                if (task.isBlank()) return@mapIndexedNotNull null
                val owner = item.owner.trim()
                val due = item.due.trim()
                val text = buildString {
                    append(task)
                    if (owner.isNotBlank()) append(". Owner: ").append(owner)
                    if (due.isNotBlank()) append(". Due: ").append(due)
                }
                ActionItem(
                    id = "$idPrefix-action-$index",
                    text = text,
                    sourceSegmentId = item.sourceSegmentId.trim().ifBlank { fallbackSourceSegmentId },
                    createdAtMs = nowMs,
                )
            }
    }

    fun displayText(items: List<ActionItem>): String =
        if (items.isEmpty()) {
            "No action items found."
        } else {
            items.joinToString("\n") { "- [ ] ${it.text}" }
        }

    private fun cleanActionLine(rawLine: String): String? {
        var line = rawLine.trim()
        if (line.isBlank()) return null
        line = line
            .replace(Regex("^#{1,6}\\s+"), "")
            .replace(Regex("^[-*+]\\s*"), "")
            .replace(Regex("^\\d+[.)]\\s*"), "")
            .replace(Regex("^\\[\\s*[xX]?\\s*]\\s*"), "")
            .trim()
        if (line.isBlank()) return null
        line = line
            .replace(Regex("\\*\\*([^*]+)\\*\\*"), "$1")
            .replace(Regex("\\*([^*]+)\\*"), "$1")
            .replace(Regex("__([^_]+)__"), "$1")
            .replace(Regex("_([^_]+)_"), "$1")
            .replace(Regex("\\s+—\\s+Owner:", RegexOption.IGNORE_CASE), ". Owner:")
            .replace(Regex("\\s+-\\s+Owner:", RegexOption.IGNORE_CASE), ". Owner:")
            .replace(Regex("\\s+"), " ")
            .trim()
        return line.takeIf { it.isNotBlank() }
    }
}
