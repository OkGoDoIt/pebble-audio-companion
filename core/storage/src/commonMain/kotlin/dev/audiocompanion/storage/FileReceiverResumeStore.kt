package dev.audiocompanion.storage

import dev.audiocompanion.transport.ReceiverResumeState
import dev.audiocompanion.transport.ReceiverResumeStore
import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
private data class ResumeStateJson(
    val lastStreamId: UInt,
    val lastContiguousSequence: UInt? = null,
    val lastSampleIndex: ULong = 0u,
)

/**
 * Persisted receiver resume state (`receiver_state.json`, plan 6.2 step 5): survives process
 * death so a reconnect can resume from the last stream id/sequence. Written via temp file +
 * atomic rename.
 */
class FileReceiverResumeStore(
    private val fileSystem: FileSystem,
    private val root: Path,
) : ReceiverResumeStore {

    private val json = Json { ignoreUnknownKeys = true }
    private val path = Path(root, "receiver_state.json")
    private val tmpPath = Path(root, "receiver_state.json.tmp")

    override suspend fun save(state: ReceiverResumeState) {
        fileSystem.createDirectories(root)
        val payload = ResumeStateJson(
            lastStreamId = state.lastStreamId,
            lastContiguousSequence = state.lastContiguousSequence,
            lastSampleIndex = state.lastSampleIndex,
        )
        fileSystem.sink(tmpPath).buffered().use { sink ->
            sink.write(json.encodeToString(ResumeStateJson.serializer(), payload).encodeToByteArray())
        }
        fileSystem.atomicMove(tmpPath, path)
    }

    override suspend fun load(): ReceiverResumeState? {
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        val parsed = runCatching { json.decodeFromString(ResumeStateJson.serializer(), text) }
            .getOrNull() ?: return null
        return ReceiverResumeState(
            lastStreamId = parsed.lastStreamId,
            lastContiguousSequence = parsed.lastContiguousSequence,
            lastSampleIndex = parsed.lastSampleIndex,
        )
    }

    override suspend fun clear() {
        fileSystem.delete(path, mustExist = false)
        fileSystem.delete(tmpPath, mustExist = false)
    }
}
