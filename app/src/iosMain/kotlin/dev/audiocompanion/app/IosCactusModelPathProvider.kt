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
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask
import platform.Foundation.dataWithContentsOfURL
import platform.Foundation.writeToFile

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
            downloadAndExtract(modelPath)
            SystemFileSystem.sink(versionPath).buffered().use { sink ->
                sink.write(modelVersion.encodeToByteArray())
            }
        }
        modelPath
    }

    private fun downloadAndExtract(targetDir: String) {
        val tempZipPath = "${NSTemporaryDirectory()}cactus_download_$modelName.zip"
        val fileManager = NSFileManager.defaultManager
        try {
            downloadToFile(modelUrl(), tempZipPath)
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

    private fun downloadToFile(url: String, outputPath: String) {
        val nsUrl = NSURL.URLWithString(url)
            ?: throw IllegalArgumentException("Invalid URL: $url")
        val data = NSData.dataWithContentsOfURL(nsUrl)
            ?: throw IllegalStateException("Cactus model download failed for $url")
        if (!data.writeToFile(outputPath, atomically = true)) {
            throw IllegalStateException("Failed to write Cactus model download to $outputPath")
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
