package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** User-saved custom AI prompt template (beyond built-ins). */
@Serializable
data class SavedAiTemplate(
    val id: String,
    val title: String,
    val systemPrompt: String,
    val userPrompt: String,
    val createdAtMs: Long,
)

class FileCustomTemplateStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val templateDir = Path(Path(root, "ai"), "templates")

    private fun path(id: String) = Path(templateDir, "$id.template.json")

    fun save(template: SavedAiTemplate): SavedAiTemplate {
        val stamped = template.copy(createdAtMs = if (template.createdAtMs == 0L) nowMs() else template.createdAtMs)
        write(stamped)
        return stamped
    }

    fun list(): List<SavedAiTemplate> =
        if (!fileSystem.exists(templateDir)) emptyList()
        else fileSystem.list(templateDir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { load(it.name.removeSuffix(SUFFIX)) }
            .sortedByDescending { it.createdAtMs }

    fun load(id: String): SavedAiTemplate? {
        val p = path(id)
        if (!fileSystem.exists(p)) return null
        val text = fileSystem.source(p).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SavedAiTemplate.serializer(), text) }.getOrNull()
    }

    fun delete(id: String) {
        fileSystem.delete(path(id), mustExist = false)
    }

    private fun write(template: SavedAiTemplate) {
        fileSystem.createDirectories(templateDir)
        val tmp = Path(templateDir, "${template.id}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(SavedAiTemplate.serializer(), template).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, path(template.id))
    }

    companion object {
        const val SUFFIX = ".template.json"

        fun toAiPromptTemplate(saved: SavedAiTemplate): AiPromptTemplate =
            AiPromptTemplate(
                id = saved.id,
                title = saved.title,
                systemPrompt = saved.systemPrompt,
                userPrompt = saved.userPrompt,
            )
    }
}
