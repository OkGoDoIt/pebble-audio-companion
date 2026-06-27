package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Maps a diarization speaker label to a user-provided name (M5 speaker naming). */
@Serializable
data class SpeakerIdentity(
    val speakerLabel: String,
    val displayName: String,
    val knownPersonId: String? = null,
    val updatedAtMs: Long,
)

class FileSpeakerIdentityStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val dir = Path(Path(root, "ai"), "speakers")

    private fun path(label: String) = Path(dir, "${label.hashCode()}.speaker.json")

    fun save(identity: SpeakerIdentity): SpeakerIdentity {
        val stamped = identity.copy(updatedAtMs = nowMs())
        write(stamped)
        return stamped
    }

    fun load(speakerLabel: String): SpeakerIdentity? {
        val p = path(speakerLabel)
        if (!fileSystem.exists(p)) return null
        val text = fileSystem.source(p).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SpeakerIdentity.serializer(), text) }.getOrNull()
    }

    fun list(): List<SpeakerIdentity> =
        if (!fileSystem.exists(dir)) emptyList()
        else fileSystem.list(dir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { entry ->
                val text = fileSystem.source(entry).buffered().use { it.readByteArray() }.decodeToString()
                runCatching { json.decodeFromString(SpeakerIdentity.serializer(), text) }.getOrNull()
            }

    private fun write(identity: SpeakerIdentity) {
        fileSystem.createDirectories(dir)
        val tmp = Path(dir, "${identity.speakerLabel.hashCode()}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(SpeakerIdentity.serializer(), identity).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, path(identity.speakerLabel))
    }

    companion object {
        const val SUFFIX = ".speaker.json"
    }
}
