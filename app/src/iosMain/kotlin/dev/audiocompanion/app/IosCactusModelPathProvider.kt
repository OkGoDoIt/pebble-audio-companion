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

class IosCactusModelPathProvider : CactusModelPathProvider {
    override val modelName: String = STT_MODEL_NAME
    override val modelVersion: String = STT_MODEL_VERSION

    private val cachesDir: String
        get() = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory,
            NSUserDomainMask,
            true,
        ).first() as String

    private val modelsDir: String get() = "$cachesDir/models"

    override fun isModelDownloaded(): Boolean {
        val modelPath = "$modelsDir/$modelName"
        val configPath = Path(modelPath, "config.txt")
        val versionPath = Path(modelPath, VERSION_FILE)
        return SystemFileSystem.exists(configPath) &&
            readVersion(versionPath) == modelVersion
    }

    override suspend fun getModelPath(): String = withContext(Dispatchers.Default) {
        val modelPath = "$modelsDir/$modelName"
        val configPath = Path(modelPath, "config.txt")
        val versionPath = Path(modelPath, VERSION_FILE)
        val needsDownload = !SystemFileSystem.exists(configPath) ||
            readVersion(versionPath) != modelVersion

        if (needsDownload) {
            downloadAndExtract(modelPath) { _, _ -> }
            SystemFileSystem.sink(versionPath).buffered().use { sink ->
                sink.write(modelVersion.encodeToByteArray())
            }
        }
        modelPath
    }

    override suspend fun downloadModel(onProgress: (Long, Long) -> Unit) {
        withContext(Dispatchers.Default) {
            if (isModelDownloaded()) return@withContext
            val modelPath = "$modelsDir/$modelName"
            val versionPath = Path(modelPath, VERSION_FILE)
            downloadAndExtract(modelPath, onProgress)
            SystemFileSystem.sink(versionPath).buffered().use { sink ->
                sink.write(modelVersion.encodeToByteArray())
            }
        }
    }

    private suspend fun downloadAndExtract(targetDir: String, onProgress: (Long, Long) -> Unit) {
        val tempZipPath = "${NSTemporaryDirectory()}cactus_download_$modelName.zip"
        val fileManager = NSFileManager.defaultManager
        try {
            downloadToFile(modelUrl(), tempZipPath, onProgress)
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
        url: String,
        outputPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val nsUrl = NSURL.URLWithString(url)
            ?: throw IllegalArgumentException("Invalid URL: $url")
        suspendCancellableCoroutine { continuation ->
            val delegate = DownloadDelegate(
                outputPath = outputPath,
                onProgress = onProgress,
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

    private fun modelUrl(): String =
        "$HF_BASE/$modelName/resolve/$modelVersion/weights/${modelName.lowercase()}-int8.zip"

    companion object {
        private const val HF_BASE = "https://huggingface.co/Cactus-Compute"
        private const val STT_MODEL_NAME = "parakeet-tdt-0.6b-v3"
        private const val STT_MODEL_VERSION = "v1.10"
        private const val VERSION_FILE = ".cactus_version"
    }
}
