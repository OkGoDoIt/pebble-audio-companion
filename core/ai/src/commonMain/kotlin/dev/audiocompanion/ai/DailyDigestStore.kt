package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** End-of-day AI digest aggregating segment summaries for one local calendar day. */
@Serializable
data class DailyDigest(
    val dateKey: String,
    val text: String,
    val segmentIds: List<String> = emptyList(),
    val modeUsed: AiProcessingMode? = null,
    val providerId: String? = null,
    val modelUsed: String? = null,
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    val createdAtMs: Long,
)

class FileDailyDigestStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val digestDir = Path(Path(root, "ai"), "digests")

    private fun path(dateKey: String) = Path(digestDir, "$dateKey.digest.json")

    fun save(digest: DailyDigest): DailyDigest {
        val stamped = digest.copy(createdAtMs = nowMs())
        write(stamped)
        return stamped
    }

    fun load(dateKey: String): DailyDigest? {
        val p = path(dateKey)
        if (!fileSystem.exists(p)) return null
        val text = fileSystem.source(p).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(DailyDigest.serializer(), text) }.getOrNull()
    }

    fun list(): List<DailyDigest> {
        if (!fileSystem.exists(digestDir)) return emptyList()
        return fileSystem.list(digestDir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { entry ->
                val key = entry.name.removeSuffix(SUFFIX)
                load(key)
            }
            .sortedByDescending { it.createdAtMs }
    }

    fun delete(dateKey: String) {
        fileSystem.delete(path(dateKey), mustExist = false)
    }

    private fun write(digest: DailyDigest) {
        fileSystem.createDirectories(digestDir)
        val tmp = Path(digestDir, "${digest.dateKey}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(DailyDigest.serializer(), digest).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, path(digest.dateKey))
    }

    companion object {
        const val SUFFIX = ".digest.json"
    }
}
