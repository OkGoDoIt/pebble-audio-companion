@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package dev.audiocompanion.app

import dev.audiocompanion.transcription.CactusModelPathProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.readString
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.SYSTEM
import okio.buffer
import okio.openZip
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.NSURLSessionDownloadDelegateProtocol
import platform.Foundation.NSURLSessionDownloadTask
import platform.Foundation.NSURLSessionTask
import platform.Foundation.NSUserDomainMask
import platform.darwin.NSObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class IosCactusModelPathProvider(
    private val selectedModelId: () -> String = { LocalTranscriptionModels.DEFAULT_MODEL_ID },
) : CactusModelPathProvider {
    override val modelName: String
        get() = selectedModel().modelNameForProvenance
    override val modelVersion: String
        get() = selectedModel().modelVersionForProvenance

    private val cachesDir: String
        get() = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory,
            NSUserDomainMask,
            true,
        ).first() as String

    private val modelsDir: String get() = "$cachesDir/models"

    override fun isModelDownloaded(): Boolean = isModelDownloaded(selectedModel().id)

    fun isModelDownloaded(modelId: String): Boolean {
        val model = LocalTranscriptionModels.byId(modelId)
        val modelPath = "$modelsDir/${model.installDirectoryName}"
        val configPath = Path(modelPath, "config.txt")
        val versionPath = Path(modelPath, VERSION_FILE)
        return SystemFileSystem.exists(configPath) &&
            readVersion(versionPath) == model.revision
    }

    override suspend fun getModelPath(): String = withContext(Dispatchers.Default) {
        val model = selectedModel()
        val modelPath = "$modelsDir/${model.installDirectoryName}"
        if (!isModelDownloaded(model.id)) {
            throw IllegalStateException("${model.displayName} is not downloaded")
        }
        modelPath
    }

    override suspend fun downloadModel(onProgress: (Long, Long) -> Unit) {
        downloadModel(selectedModel().id, onProgress)
    }

    suspend fun downloadModel(modelId: String, onProgress: (Long, Long) -> Unit) {
        withContext(Dispatchers.Default) {
            val model = LocalTranscriptionModels.byId(modelId)
            if (isModelDownloaded(model.id)) return@withContext
            val modelPath = "$modelsDir/${model.installDirectoryName}"
            val versionPath = Path(modelPath, VERSION_FILE)
            downloadAndExtract(model, modelPath, onProgress)
            SystemFileSystem.sink(versionPath).buffered().use { sink ->
                sink.write(model.revision.encodeToByteArray())
            }
        }
    }

    private suspend fun downloadAndExtract(
        model: LocalTranscriptionModelSpec,
        targetDir: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val tempZipPath = "${NSTemporaryDirectory()}cactus_download_${model.id}.zip"
        val fileManager = NSFileManager.defaultManager
        try {
            downloadToFile(model, tempZipPath, onProgress)
            if (fileManager.fileExistsAtPath(targetDir)) {
                fileManager.removeItemAtPath(targetDir, null)
            }
            fileManager.createDirectoryAtPath(
                targetDir,
                withIntermediateDirectories = true,
                attributes = null,
                error = null,
            )
            extractZip(tempZipPath, targetDir)
        } catch (e: Exception) {
            if (fileManager.fileExistsAtPath(targetDir)) {
                fileManager.removeItemAtPath(targetDir, null)
            }
            throw e
        } finally {
            if (fileManager.fileExistsAtPath(tempZipPath)) {
                fileManager.removeItemAtPath(tempZipPath, null)
            }
        }
    }

    /**
     * Streaming NSURLSession download with byte progress: the ~700 MB archive goes to a file,
     * never through memory (the previous dataWithContentsOfURL approach held it all in RAM and
     * reported no progress). Cancellation cancels the task.
     */
    private suspend fun downloadToFile(
        model: LocalTranscriptionModelSpec,
        outputPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val url = modelUrl(model)
        val nsUrl = NSURL.URLWithString(url)
            ?: throw IllegalArgumentException("Invalid URL: $url")
        suspendCancellableCoroutine { continuation ->
            val delegate = DownloadDelegate(
                outputPath = outputPath,
                onProgress = { written, total ->
                    onProgress(written, if (total > 1024) total else model.downloadBytes)
                },
                onDone = { error ->
                    if (error == null) {
                        continuation.resume(Unit)
                    } else {
                        continuation.resumeWithException(IllegalStateException(error))
                    }
                },
            )
            val session = NSURLSession.sessionWithConfiguration(
                NSURLSessionConfiguration.defaultSessionConfiguration,
                delegate = delegate,
                delegateQueue = null,
            )
            val task = session.downloadTaskWithURL(nsUrl)
            continuation.invokeOnCancellation {
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    private class DownloadDelegate(
        private val outputPath: String,
        private val onProgress: (Long, Long) -> Unit,
        private val onDone: (errorMessage: String?) -> Unit,
    ) : NSObject(), NSURLSessionDownloadDelegateProtocol {
        private var moveError: String? = null
        private var finished = false

        override fun URLSession(
            session: NSURLSession,
            downloadTask: NSURLSessionDownloadTask,
            didWriteData: Long,
            totalBytesWritten: Long,
            totalBytesExpectedToWrite: Long,
        ) {
            onProgress(totalBytesWritten, totalBytesExpectedToWrite.coerceAtLeast(0))
        }

        override fun URLSession(
            session: NSURLSession,
            downloadTask: NSURLSessionDownloadTask,
            didFinishDownloadingToURL: NSURL,
        ) {
            // The temp file is deleted when this callback returns: move it synchronously.
            val statusCode =
                (downloadTask.response as? NSHTTPURLResponse)?.statusCode?.toInt() ?: 0
            if (statusCode !in 200..299) {
                moveError = "Model download failed: HTTP $statusCode"
                return
            }
            val fileManager = NSFileManager.defaultManager
            if (fileManager.fileExistsAtPath(outputPath)) {
                fileManager.removeItemAtPath(outputPath, null)
            }
            val moved = didFinishDownloadingToURL.path?.let { tempPath ->
                fileManager.moveItemAtPath(tempPath, toPath = outputPath, error = null)
            } ?: false
            if (!moved) {
                moveError = "Failed to store the downloaded model archive"
            }
        }

        override fun URLSession(
            session: NSURLSession,
            task: NSURLSessionTask,
            didCompleteWithError: NSError?,
        ) {
            if (finished) return
            finished = true
            session.finishTasksAndInvalidate()
            onDone(didCompleteWithError?.localizedDescription ?: moveError)
        }
    }

    private fun extractZip(zipPath: String, targetDir: String) {
        val zipFs = FileSystem.SYSTEM.openZip(zipPath.toPath())
        val targetOkioPath = targetDir.toPath()
        val entries = mutableListOf<okio.Path>()
        zipFs.listRecursively("/".toPath()).forEach { entries.add(it) }

        for (entry in entries) {
            val entryName = entry.toString().removePrefix("/")
            if (entryName.isEmpty()) continue
            if (".." in entryName) {
                throw IllegalStateException("ZIP entry contains ..: $entryName")
            }
            val outputPath = targetOkioPath / entryName
            val metadata = zipFs.metadata(entry)
            if (metadata.isDirectory) {
                FileSystem.SYSTEM.createDirectories(outputPath)
            } else {
                outputPath.parent?.let { FileSystem.SYSTEM.createDirectories(it) }
                val bufferedSource = zipFs.source(entry).buffer()
                try {
                    val sink = FileSystem.SYSTEM.sink(outputPath)
                    try {
                        val bufferedSink = sink.buffer()
                        try {
                            bufferedSink.writeAll(bufferedSource)
                        } finally {
                            bufferedSink.close()
                        }
                    } finally {
                        sink.close()
                    }
                } finally {
                    bufferedSource.close()
                }
            }
        }
    }

    private fun readVersion(path: Path): String? =
        if (SystemFileSystem.exists(path)) {
            SystemFileSystem.source(path).buffered().use { it.readString() }.trim()
        } else {
            null
        }

    private fun selectedModel(): LocalTranscriptionModelSpec =
        LocalTranscriptionModels.byId(selectedModelId())

    private fun modelUrl(model: LocalTranscriptionModelSpec): String =
        "$HF_BASE/${model.repository}/resolve/${model.revision}/${model.archivePath}"

    companion object {
        private const val HF_BASE = "https://huggingface.co"
        private const val VERSION_FILE = ".cactus_version"
    }
}
