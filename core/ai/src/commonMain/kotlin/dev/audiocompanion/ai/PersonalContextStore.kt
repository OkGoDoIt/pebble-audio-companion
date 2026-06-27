package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Durable store for [PersonalContext] at `<root>/ai/personal_context.json`, written via temp file +
 * atomic rename like other stores in this app.
 */
class FilePersonalContextStore(
    private val fileSystem: FileSystem,
    root: Path,
) {
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }
    private val aiDir = Path(root, "ai")
    private val contextPath = Path(aiDir, FILE_NAME)

    fun load(): PersonalContext {
        if (!fileSystem.exists(contextPath)) return PersonalContext()
        val text = fileSystem.source(contextPath).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(PersonalContext.serializer(), text) }
            .getOrDefault(PersonalContext())
    }

    fun save(context: PersonalContext): PersonalContext {
        write(context)
        return context
    }

    fun clear() {
        fileSystem.delete(contextPath, mustExist = false)
        fileSystem.delete(Path(aiDir, "$FILE_NAME.tmp"), mustExist = false)
    }

    private fun write(context: PersonalContext) {
        fileSystem.createDirectories(aiDir)
        val tmp = Path(aiDir, "$FILE_NAME.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(PersonalContext.serializer(), context).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, contextPath)
    }

    companion object {
        const val FILE_NAME = "personal_context.json"
    }
}
