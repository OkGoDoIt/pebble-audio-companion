package dev.audiocompanion.app

import android.content.Context
import dev.audiocompanion.transcription.CactusModelPathProvider
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

class AndroidCactusModelPathProvider(
    context: Context,
) : CactusModelPathProvider {
    override val modelName: String = STT_MODEL_NAME
    override val modelVersion: String = STT_MODEL_VERSION

    private val appContext = context.applicationContext
    private val modelsDir: File
        get() = appContext.filesDir.resolve("models").also { it.mkdirs() }

    override fun isModelDownloaded(): Boolean {
        val modelDir = modelsDir.resolve(modelName)
        return modelDir.exists() && modelDir.resolve("config.txt").exists() &&
            modelDir.resolve(VERSION_FILE).readTextOrNull() == modelVersion
    }

    override suspend fun getModelPath(): String = withContext(Dispatchers.IO) {
        val modelDir = modelsDir.resolve(modelName)
        val versionFile = modelDir.resolve(VERSION_FILE)
        val needsDownload = !modelDir.exists() ||
            !modelDir.resolve("config.txt").exists() ||
            versionFile.readTextOrNull() != modelVersion

        if (needsDownload) {
            downloadAndExtract(modelDir)
            versionFile.writeText(modelVersion)
        }
        modelDir.absolutePath
    }

    private suspend fun downloadAndExtract(targetDir: File) {
        val tempZip = File(appContext.cacheDir, "cactus_download_$modelName.zip")
        try {
            downloadToFile(tempZip)
            if (targetDir.exists()) {
                targetDir.deleteRecursively()
            }
            targetDir.mkdirs()
            extractZip(tempZip, targetDir)
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            targetDir.deleteRecursively()
            throw e
        } finally {
            tempZip.delete()
        }
    }

    private suspend fun downloadToFile(outputFile: File) {
        val connection = URL(modelUrl()).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        try {
            val code = connection.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("Cactus model download failed: HTTP $code")
            }
            connection.inputStream.use { input ->
                FileOutputStream(outputFile).use { output ->
                    val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                    }
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun extractZip(zipFile: File, targetDir: File) {
        val targetPath = targetDir.canonicalPath
        ZipInputStream(zipFile.inputStream().buffered()).use { zip ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val entry = zip.nextEntry ?: break
                val outputFile = File(targetDir, entry.name)
                if (!outputFile.canonicalPath.startsWith(targetPath)) {
                    throw SecurityException("ZIP entry outside target dir: ${entry.name}")
                }
                if (entry.isDirectory) {
                    outputFile.mkdirs()
                } else {
                    outputFile.parentFile?.mkdirs()
                    FileOutputStream(outputFile).use { output ->
                        val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val read = zip.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                        }
                    }
                }
                zip.closeEntry()
            }
        }
    }

    private fun modelUrl(): String =
        "$HF_BASE/$modelName/resolve/$modelVersion/weights/${modelName.lowercase()}-int8.zip"

    private fun File.readTextOrNull(): String? =
        if (exists()) readText().trim() else null

    companion object {
        private const val HF_BASE = "https://huggingface.co/Cactus-Compute"
        private const val STT_MODEL_NAME = "parakeet-tdt-0.6b-v3"
        private const val STT_MODEL_VERSION = "v1.10"
        private const val VERSION_FILE = ".cactus_version"
        private const val DOWNLOAD_BUFFER_BYTES = 256 * 1024
    }
}
