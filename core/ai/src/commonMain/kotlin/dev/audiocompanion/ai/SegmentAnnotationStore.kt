package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * AI-generated title + summary for one segment, used by timeline/Library rows (ux plan
 * Sections 8/9). Distinct from [AiOutput]: annotations are row decoration generated
 * automatically under the user's AI consent/mode settings, not user-requested outputs.
 */
@Serializable
data class SegmentAnnotation(
    val segmentId: String,
    val title: String? = null,
    val summary: String? = null,
    val modeUsed: AiProcessingMode? = null,
    val providerId: String? = null,
    val modelUsed: String? = null,
    val createdAtMs: Long,
    /** Total generation attempts (live + final) so far; informational. */
    val attempts: Int = 0,
    val lastError: String? = null,
    /**
     * True once the annotation was generated from the complete, durable transcript of a closed
     * segment. While a conversation is still live, provisional annotations are refreshed and stay
     * `false` until the authoritative final pass replaces them.
     */
    val isFinal: Boolean = false,
    /** Length of the transcript text last summarized; drives the live-refresh growth gate. */
    val sourceCharCount: Int = 0,
    /** Final-pass attempts only, so a broken provider cannot spin the authoritative pass forever. */
    val finalAttempts: Int = 0,
) {
    val hasContent: Boolean get() = !title.isNullOrBlank() || !summary.isNullOrBlank()
}

/**
 * File-backed annotation storage: one
 * `<root>/ai/annotations/<segment_id>.annotation.json` per segment, written via temp file +
 * atomic rename like every other durable store in this app.
 */
class FileSegmentAnnotationStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
    }
    private val annotationsDir = Path(Path(root, "ai"), "annotations")

    private fun annotationPath(segmentId: String) = Path(annotationsDir, "$segmentId$SUFFIX")

    fun save(annotation: SegmentAnnotation): SegmentAnnotation {
        val stamped = annotation.copy(createdAtMs = nowMs())
        write(stamped)
        return stamped
    }

    fun load(segmentId: String): SegmentAnnotation? {
        val path = annotationPath(segmentId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(SegmentAnnotation.serializer(), text) }.getOrNull()
    }

    fun list(): List<SegmentAnnotation> {
        if (!fileSystem.exists(annotationsDir)) return emptyList()
        return fileSystem.list(annotationsDir)
            .filter { it.name.endsWith(SUFFIX) }
            .mapNotNull { load(it.name.removeSuffix(SUFFIX)) }
            .sortedBy { it.createdAtMs }
    }

    fun delete(segmentId: String) {
        fileSystem.delete(annotationPath(segmentId), mustExist = false)
    }

    fun deleteAll() {
        if (!fileSystem.exists(annotationsDir)) return
        fileSystem.list(annotationsDir)
            .filter { it.name.endsWith(SUFFIX) || it.name.endsWith("$SUFFIX.tmp") }
            .forEach { fileSystem.delete(it, mustExist = false) }
    }

    private fun write(annotation: SegmentAnnotation) {
        fileSystem.createDirectories(annotationsDir)
        val tmp = Path(annotationsDir, "${annotation.segmentId}$SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(SegmentAnnotation.serializer(), annotation).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, annotationPath(annotation.segmentId))
    }

    companion object {
        const val SUFFIX = ".annotation.json"
    }
}
