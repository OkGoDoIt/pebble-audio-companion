package dev.audiocompanion.transcription

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
enum class CloudUploadPhase {
    /** The audio body is uploading on the background transport. */
    Uploading,

    /** (Soniox) the file is uploaded; the create/poll/fetch control plane still has to run. */
    AwaitingControlPlane,
}

@Serializable
data class CloudUploadJob(
    val jobId: String,
    val provider: CloudProvider,
    val phase: CloudUploadPhase = CloudUploadPhase.Uploading,
    /** Pre-assembled request body on disk, deleted when the job leaves the upload transport. */
    val bodyFilePath: String,
    /** (Soniox) the uploaded file id, once known. */
    val sonioxFileId: String? = null,
    val createdAtMs: Long,
)

/**
 * Durable record of background cloud-upload jobs, one JSON file per job under
 * `<root>/transcription/uploads/`, written via temp file + atomic rename so it survives process
 * death. The coordinator uses it to reconcile in-flight uploads after a relaunch and to find the
 * pre-assembled body files to clean up.
 */
class CloudUploadJobStore(
    private val fileSystem: FileSystem,
    root: Path,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val dir = Path(Path(root, "transcription"), "uploads")

    private fun jobPath(jobId: String) = Path(dir, "$jobId.upload.json")

    fun all(): List<CloudUploadJob> {
        if (!fileSystem.exists(dir)) return emptyList()
        return fileSystem.list(dir)
            .filter { it.name.endsWith(".upload.json") }
            .mapNotNull { path ->
                val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
                runCatching { json.decodeFromString(CloudUploadJob.serializer(), text) }.getOrNull()
            }
            .sortedBy { it.createdAtMs }
    }

    fun load(jobId: String): CloudUploadJob? {
        val path = jobPath(jobId)
        if (!fileSystem.exists(path)) return null
        val text = fileSystem.source(path).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(CloudUploadJob.serializer(), text) }.getOrNull()
    }

    fun save(job: CloudUploadJob) {
        fileSystem.createDirectories(dir)
        val tmp = Path(dir, "${job.jobId}.upload.json.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(CloudUploadJob.serializer(), job).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, jobPath(job.jobId))
    }

    fun delete(jobId: String) {
        fileSystem.delete(jobPath(jobId), mustExist = false)
        fileSystem.delete(Path(dir, "$jobId.upload.json.tmp"), mustExist = false)
    }
}
