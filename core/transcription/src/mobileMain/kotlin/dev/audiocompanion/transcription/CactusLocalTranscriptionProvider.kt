package dev.audiocompanion.transcription

import com.cactus.cactusDestroy
import com.cactus.cactusInit
import com.cactus.cactusStop
import com.cactus.cactusTranscribe
import com.cactus.isCactusSupported
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.io.Buffer
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlinx.io.readByteArray
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlin.random.Random

interface CactusModelPathProvider {
    val modelName: String
    val modelVersion: String
    fun isModelDownloaded(): Boolean
    suspend fun getModelPath(): String
}

expect suspend fun withHighPriorityTranscriptionThread(block: suspend () -> String): String
expect suspend fun getFreeTranscriptionMemoryMb(): Long
expect val minTranscriptionMemoryMb: Long

class CactusLocalTranscriptionProvider(
    private val modelProvider: CactusModelPathProvider,
    private val fileSystem: kotlinx.io.files.FileSystem = SystemFileSystem,
    private val tempDirectory: Path = SystemTemporaryDirectory,
) : TranscriptionProvider {
    override val id: String = "cactus-local"
    private val mutableStatus = MutableStateFlow(ProviderStatus.NotReady)
    override val status: StateFlow<ProviderStatus> = mutableStatus

    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private var modelHandle: Long = 0L
    private var initializedModel: String? = null

    /**
     * Available only when the model is already on disk: transcription must never trigger the
     * (large) model download implicitly — that is an explicit user action in Settings.
     */
    override suspend fun isAvailable(): Boolean =
        isCactusSupported() && modelProvider.isModelDownloaded()

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult = mutex.withLock {
        if (!isCactusSupported()) {
            mutableStatus.value = ProviderStatus.NotReady
            throw TranscriptionException.ProviderUnavailable(id)
        }
        val rawPath = tempPath("cactus_stt", "raw")
        val wavPath = tempPath("cactus_stt", "wav")
        try {
            val pcmBytes = writeRawPcm(rawPath, pcmChunks)
            if (pcmBytes < MIN_AUDIO_BYTES) {
                throw TranscriptionException.NoSpeechDetected("local audio too short")
            }
            writeWavFromRaw(rawPath, wavPath, pcmBytes, sampleRateHz)
            val handle = initModel()
            val text = runNativeTranscribe(handle, wavPath.toString())
            val cleaned = text.trim()
            if (isNoSpeech(cleaned)) {
                throw TranscriptionException.NoSpeechDetected("local model returned no speech")
            }
            TranscriptionResult(
                text = cleaned,
                providerId = id,
                modelUsed = "${modelProvider.modelName}:${modelProvider.modelVersion}",
            )
        } finally {
            deleteQuietly(rawPath)
            deleteQuietly(wavPath)
        }
    }

    private suspend fun initModel(): Long {
        if (modelHandle != 0L && initializedModel == modelProvider.modelName) {
            mutableStatus.value = ProviderStatus.Ready
            return modelHandle
        }
        mutableStatus.value = ProviderStatus.Initializing
        val path = try {
            modelProvider.getModelPath()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            mutableStatus.value = ProviderStatus.Error
            throw TranscriptionException.TranscriptionFailed("failed to resolve local model", e)
        }
        if (modelHandle != 0L) {
            cactusDestroy(modelHandle)
            modelHandle = 0L
        }
        modelHandle = try {
            cactusInit(path, null, false)
        } catch (e: Exception) {
            mutableStatus.value = ProviderStatus.Error
            throw TranscriptionException.TranscriptionFailed("failed to initialize local model", e)
        }
        initializedModel = modelProvider.modelName
        mutableStatus.value = ProviderStatus.Ready
        return modelHandle
    }

    private suspend fun runNativeTranscribe(handle: Long, wavPath: String): String {
        val freeMemory = getFreeTranscriptionMemoryMb()
        if (freeMemory < minTranscriptionMemoryMb) {
            throw TranscriptionException.ProviderUnavailable(id)
        }
        val callerJob = coroutineContext[Job]
        val completionHandle = callerJob?.invokeOnCompletion { cause ->
            if (cause != null) {
                cactusStop(handle)
            }
        }
        return try {
            withHighPriorityTranscriptionThread {
                parseTranscriptionText(cactusTranscribe(handle, wavPath, null, null, null, null))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            mutableStatus.value = ProviderStatus.Error
            throw TranscriptionException.TranscriptionFailed("local transcription failed", e)
        } finally {
            completionHandle?.dispose()
        }
    }

    private suspend fun writeRawPcm(path: Path, pcmChunks: Flow<ByteArray>): Int {
        var bytes = 0
        var nonZero = false
        fileSystem.sink(path).buffered().use { sink ->
            pcmChunks.collect { chunk ->
                if (chunk.isNotEmpty()) {
                    sink.write(chunk)
                    bytes += chunk.size
                    if (!nonZero) {
                        nonZero = chunk.any { it != 0.toByte() }
                    }
                }
            }
        }
        if (!nonZero) {
            throw TranscriptionException.NoSpeechDetected("local audio is silent")
        }
        return bytes
    }

    private fun writeWavFromRaw(
        rawPath: Path,
        wavPath: Path,
        pcmBytes: Int,
        sampleRateHz: Int,
    ) {
        fileSystem.sink(wavPath).buffered().use { sink ->
            sink.write(PcmWav.headerMono16(pcmBytes, sampleRateHz))
            fileSystem.source(rawPath).buffered().use { source ->
                val buffer = Buffer()
                while (true) {
                    val read = source.readAtMostTo(buffer, COPY_BUFFER_BYTES.toLong())
                    if (read == -1L) break
                    sink.write(buffer, read)
                }
                buffer.close()
            }
        }
    }

    private fun parseTranscriptionText(jsonResult: String): String =
        try {
            json.parseToJsonElement(jsonResult).jsonObject["response"]?.jsonPrimitive?.content
                ?: jsonResult
        } catch (_: Exception) {
            jsonResult
        }

    private fun isNoSpeech(text: String): Boolean =
        text.length < 2 ||
            text.replace(NON_SPEECH_REGEX, "").isBlank() ||
            text.replace("s*", "").lowercase().count { it.isLetterOrDigit() } < 2

    private fun tempPath(prefix: String, suffix: String): Path =
        Path(tempDirectory, "$prefix-${Random.nextLong().toString(16)}.$suffix")

    private fun deleteQuietly(path: Path) {
        try {
            if (fileSystem.exists(path)) fileSystem.delete(path)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val MIN_AUDIO_BYTES = 3_200
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private val NON_SPEECH_REGEX = "\\[[^\\]]*\\]|\\([^)]*\\)".toRegex()
    }
}
