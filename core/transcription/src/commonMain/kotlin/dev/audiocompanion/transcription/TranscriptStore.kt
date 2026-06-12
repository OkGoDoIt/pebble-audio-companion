package dev.audiocompanion.transcription

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Durable transcript for one segment, with the provenance required by the guide: provider,
 * model, mode used, and creation time. Stored beside (not inside) the segment metadata so the
 * transcript survives independent of receive-path rewrites.
 */
@Serializable
data class SegmentTranscript(
    val segmentId: String,
    val text: String,
    val modeUsed: TranscriptionMode,
    val providerId: String,
    val modelUsed: String? = null,
    val createdAtMs: Long,
    val segments: List<TranscriptSegment> = emptyList(),
    val words: List<TranscriptWord> = emptyList(),
)

/**
 * File-backed transcript storage: one `<root>/transcription/transcripts/<segment_id>.transcript.json`
 * per transcribed segment, written via temp file + atomic rename like every other durable store
 * in this app.
 */
class FileTranscriptStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }
    private val transcriptsDir = Path(Path(root, "transcription"), "transcripts")

    private fun transcriptPath(segmentId: String) = Path(transcriptsDir, "$segmentId.transcript.json")

    fun save(segmentId: String, result: RoutedTranscription): SegmentTranscript {
        val transcript = SegmentTranscript(
            segmentId = segmentId,
            text = result.text,
            modeUsed = result.modeUsed,
            providerId = result.providerId,
            modelUsed = result.modelUsed,
            createdAtMs = nowMs(),
            segments = result.segments,
            words = result.words,
        )
        write(transcript)
        return transcript
    }

    fun load(segmentId: String): SegmentTranscript? {
        val path = transcriptPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SegmentTranscript.serializer(), text) }.getOrNull()
    }

    fun list(): List<SegmentTranscript> {
        if (!fileSystem.exists(transcriptsDir)) return emptyList()
        return fileSystem.list(transcriptsDir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { load(it.name.removeSuffix(SUFFIX)) }
            .sortedBy { it.createdAtMs }
    }

    fun delete(segmentId: String) {
        fileSystem.delete(transcriptPath(segmentId), mustExist = false)
    }

    fun deleteAll() {
        if (!fileSystem.exists(transcriptsDir)) return
        fileSystem.list(transcriptsDir)
            .filter { it.name.endsWith(SUFFIX) || it.name.endsWith("$SUFFIX.tmp") }
            .forEach { fileSystem.delete(it, mustExist = false) }
    }

    private fun write(transcript: SegmentTranscript) {
        fileSystem.createDirectories(transcriptsDir)
        val tmp = Path(transcriptsDir, "${transcript.segmentId}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(SegmentTranscript.serializer(), transcript).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, transcriptPath(transcript.segmentId))
    }

    companion object {
        const val SUFFIX = ".transcript.json"
    }
}
