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
    private val selectedModelId: () -> String = { LocalTranscriptionModels.DEFAULT_MODEL_ID },
) : CactusModelPathProvider {
    override val modelName: String
        get() = selectedModel().modelNameForProvenance
    override val modelVersion: String
        get() = selectedModel().modelVersionForProvenance

    private val appContext = context.applicationContext
    private val modelsDir: File
        get() = appContext.filesDir.resolve("models").also { it.mkdirs() }

    override fun isModelDownloaded(): Boolean = isModelDownloaded(selectedModel().id)

    fun isModelDownloaded(modelId: String): Boolean {
        val model = LocalTranscriptionModels.byId(modelId)
        val modelDir = modelsDir.resolve(model.installDirectoryName)
        return modelDir.exists() && modelDir.resolve("config.txt").exists() &&
            modelDir.resolve(VERSION_FILE).readTextOrNull() == model.revision
    }

    override suspend fun getModelPath(): String = withContext(Dispatchers.IO) {
        val model = selectedModel()
        val modelDir = modelsDir.resolve(model.installDirectoryName)
        if (!isModelDownloaded(model.id)) {
            throw IllegalStateException("${model.displayName} is not downloaded")
        }
        modelDir.absolutePath
    }

    override suspend fun downloadModel(onProgress: (Long, Long) -> Unit) {
        downloadModel(selectedModel().id, onProgress)
    }

    suspend fun downloadModel(modelId: String, onProgress: (Long, Long) -> Unit) {
        withContext(Dispatchers.IO) {
            val model = LocalTranscriptionModels.byId(modelId)
            val modelDir = modelsDir.resolve(model.installDirectoryName)
            val versionFile = modelDir.resolve(VERSION_FILE)
            if (!isModelDownloaded(model.id)) {
                downloadAndExtract(model, modelDir, onProgress)
                versionFile.writeText(model.revision)
            }
        }
    }

    private suspend fun downloadAndExtract(
        model: LocalTranscriptionModelSpec,
        targetDir: File,
        onProgress: (Long, Long) -> Unit,
    ) {
        val tempZip = File(appContext.cacheDir, "cactus_download_${model.id}.zip")
        try {
            downloadToFile(model, tempZip, onProgress)
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

    private suspend fun downloadToFile(
        model: LocalTranscriptionModelSpec,
        outputFile: File,
        onProgress: (Long, Long) -> Unit,
    ) {
        val connection = URL(modelUrl(model)).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        try {
            val code = connection.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("Cactus model download failed: HTTP $code")
            }
            val totalBytes = connection.contentLengthLong
                .takeIf { it > 1024 }
                ?: model.downloadBytes
            var received = 0L
            connection.inputStream.use { input ->
                FileOutputStream(outputFile).use { output ->
                    val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        received += read
                        onProgress(received, totalBytes)
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

    private fun selectedModel(): LocalTranscriptionModelSpec =
        LocalTranscriptionModels.byId(selectedModelId())

    private fun modelUrl(model: LocalTranscriptionModelSpec): String =
        "$HF_BASE/${model.repository}/resolve/${model.revision}/${model.archivePath}"

    private fun File.readTextOrNull(): String? =
        if (exists()) readText().trim() else null

    companion object {
        private const val HF_BASE = "https://huggingface.co"
        private const val VERSION_FILE = ".cactus_version"
        private const val DOWNLOAD_BUFFER_BYTES = 256 * 1024
    }
}
