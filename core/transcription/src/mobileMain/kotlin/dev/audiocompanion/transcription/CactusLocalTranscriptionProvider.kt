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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlin.math.sqrt
import kotlin.random.Random

interface CactusModelPathProvider {
    val modelName: String
    val modelVersion: String
    fun isModelDownloaded(): Boolean

    /**
     * Path of the installed model. Must only be called when [isModelDownloaded] is true; this
     * resolves without network and must never download implicitly.
     */
    suspend fun getModelPath(): String

    /**
     * Downloads and installs the model if missing, reporting (receivedBytes, totalBytes) as
     * the archive downloads. totalBytes is 0 while unknown. Implementations must be
     * cancellable and must leave no partial install behind on failure.
     */
    suspend fun downloadModel(onProgress: (receivedBytes: Long, totalBytes: Long) -> Unit)
}

expect suspend fun withHighPriorityTranscriptionThread(block: suspend () -> String): String
expect suspend fun getFreeTranscriptionMemoryMb(): Long
expect val minTranscriptionMemoryMb: Long

/** Minimum process-available memory (MB) required to *load* a model, gated before init. */
expect val minModelInitMemoryMb: Long

class CactusLocalTranscriptionProvider(
    private val modelProvider: CactusModelPathProvider,
    private val fileSystem: kotlinx.io.files.FileSystem = SystemFileSystem,
    private val tempDirectory: Path = SystemTemporaryDirectory,
    private val nowMs: () -> Long = { 0L },
) : TranscriptionProvider, LocalTranscriptionLifecycle {
    override val id: String = "cactus-local"
    private val mutableStatus = MutableStateFlow(ProviderStatus.NotReady)
    override val status: StateFlow<ProviderStatus> = mutableStatus

    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private var modelHandle: Long = 0L
    private var initializedModel: String? = null

    /** Wall-clock of the most recent transcription, for [releaseModelIfIdle]; 0 when never used. */
    private var lastUsedMs: Long = 0L

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
            val speechRanges = detectSpeechRanges(rawPath, pcmBytes, sampleRateHz)
                .ifEmpty {
                    splitLongSpeechRanges(
                        listOf(PcmSpeechRange(startByte = 0, endByte = alignToSampleBoundary(pcmBytes))),
                        sampleRateHz,
                    )
                }
            val handle = initModel()
            val nativeResults = speechRanges.mapNotNull { range ->
                writeWavRangeFromRaw(rawPath, wavPath, range, sampleRateHz)
                val native = runNativeTranscribe(handle, wavPath.toString())
                val cleaned = native.text.trim()
                if (isNoSpeech(cleaned)) {
                    null
                } else {
                    native.offsetBy(range.startMs(sampleRateHz), range.endMs(sampleRateHz), cleaned)
                }
            }
            val cleaned = nativeResults.joinToString(" ") { it.text.trim() }.trim()
            if (isNoSpeech(cleaned)) {
                throw TranscriptionException.NoSpeechDetected("local model returned no speech")
            }
            TranscriptionResult(
                text = cleaned,
                providerId = id,
                modelUsed = "${modelProvider.modelName}:${modelProvider.modelVersion}",
                segments = nativeResults.flatMap { it.segments },
                words = nativeResults.flatMap { it.words },
            )
        } finally {
            lastUsedMs = nowMs()
            deleteQuietly(rawPath)
            deleteQuietly(wavPath)
        }
    }

    override suspend fun releaseModel(reason: String) {
        // Interrupt any in-flight native transcription first so the mutex frees promptly; the
        // running transcribe() throws/returns and the next reload restarts cleanly.
        val running = modelHandle
        if (running != 0L) {
            try {
                cactusStop(running)
            } catch (_: Exception) {
            }
        }
        mutex.withLock {
            if (modelHandle != 0L) {
                try {
                    cactusDestroy(modelHandle)
                } catch (_: Exception) {
                }
                modelHandle = 0L
                initializedModel = null
                mutableStatus.value = ProviderStatus.NotReady
                println("Pebble Audio Companion local transcription model released ($reason)")
            }
        }
    }

    override suspend fun releaseModelIfIdle(nowMs: Long, idleTimeoutMs: Long) {
        if (modelHandle == 0L) return
        val last = lastUsedMs
        if (last != 0L && nowMs - last >= idleTimeoutMs) {
            releaseModel("idle ${idleTimeoutMs}ms")
        }
    }

    private suspend fun initModel(): Long {
        val selectedModel = "${modelProvider.modelName}:${modelProvider.modelVersion}"
        if (modelHandle != 0L && initializedModel == selectedModel) {
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
        // Gate model load on this process's remaining memory budget (jetsam headroom). Loading a
        // model into a tight budget is a fast path to being killed; defer instead and retry later.
        val availableMb = getFreeTranscriptionMemoryMb()
        if (availableMb < minModelInitMemoryMb) {
            mutableStatus.value = ProviderStatus.NotReady
            println(
                "Pebble Audio Companion local model load deferred: " +
                    "${availableMb}MB < ${minModelInitMemoryMb}MB process budget",
            )
            throw TranscriptionException.ProviderUnavailable(id)
        }
        modelHandle = try {
            cactusInit(path, null, false)
        } catch (e: Exception) {
            mutableStatus.value = ProviderStatus.Error
            throw TranscriptionException.TranscriptionFailed("failed to initialize local model", e)
        }
        initializedModel = selectedModel
        mutableStatus.value = ProviderStatus.Ready
        return modelHandle
    }

    private suspend fun runNativeTranscribe(handle: Long, wavPath: String): NativeTranscription {
        val freeMemory = getFreeTranscriptionMemoryMb()
        if (freeMemory < minTranscriptionMemoryMb) {
            println(
                "Pebble Audio Companion local transcription deferred: " +
                    "${freeMemory}MB < ${minTranscriptionMemoryMb}MB process budget",
            )
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
                cactusTranscribe(handle, wavPath, null, null, null, null)
            }.let(::parseNativeTranscription)
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

    private fun writeWavRangeFromRaw(
        rawPath: Path,
        wavPath: Path,
        range: PcmSpeechRange,
        sampleRateHz: Int,
    ) {
        val pcmBytes = range.byteLength
        fileSystem.sink(wavPath).buffered().use { sink ->
            sink.write(PcmWav.headerMono16(pcmBytes, sampleRateHz))
            fileSystem.source(rawPath).buffered().use { source ->
                val buffer = Buffer()
                var skipBytes = range.startByte
                while (skipBytes > 0) {
                    val read = source.readAtMostTo(buffer, minOf(skipBytes, COPY_BUFFER_BYTES).toLong())
                    if (read == -1L) break
                    buffer.skip(read)
                    skipBytes -= read.toInt()
                }
                var remainingBytes = pcmBytes
                while (true) {
                    if (remainingBytes <= 0) break
                    val read = source.readAtMostTo(buffer, minOf(remainingBytes, COPY_BUFFER_BYTES).toLong())
                    if (read == -1L) break
                    sink.write(buffer, read)
                    remainingBytes -= read.toInt()
                }
                buffer.close()
            }
        }
    }

    private fun detectSpeechRanges(
        rawPath: Path,
        pcmBytes: Int,
        sampleRateHz: Int,
    ): List<PcmSpeechRange> {
        val rawEnd = alignToSampleBoundary(pcmBytes)
        if (rawEnd < MIN_AUDIO_BYTES) return emptyList()

        val windowBytes = msToPcmBytes(ANALYSIS_WINDOW_MS, sampleRateHz)
            .coerceAtLeast(BYTES_PER_SAMPLE)
        val prerollBytes = msToPcmBytes(SPEECH_PREROLL_MS, sampleRateHz)
        val postrollBytes = msToPcmBytes(SPEECH_POSTROLL_MS, sampleRateHz)
        val minSpeechBytes = msToPcmBytes(MIN_SPEECH_RANGE_MS, sampleRateHz)
        val ranges = mutableListOf<PcmSpeechRange>()
        var speechStart: Int? = null
        var speechEnd = 0
        var offset = 0

        fileSystem.source(rawPath).buffered().use { source ->
            val buffer = Buffer()
            while (offset < rawEnd) {
                val bytesToRead = minOf(windowBytes, rawEnd - offset)
                val read = source.readAtMostTo(buffer, bytesToRead.toLong())
                if (read == -1L) break
                val window = buffer.readByteArray(read.toInt())
                val windowEnd = offset + alignToSampleBoundary(read.toInt())
                val voiced = isVoicedPcm(window)
                if (voiced) {
                    if (speechStart == null) {
                        speechStart = alignToSampleBoundary((offset - prerollBytes).coerceAtLeast(0))
                    }
                    speechEnd = alignToSampleBoundary((windowEnd + postrollBytes).coerceAtMost(rawEnd))
                } else if (speechStart != null && offset >= speechEnd) {
                    addSpeechRange(ranges, speechStart, speechEnd, minSpeechBytes)
                    speechStart = null
                }
                offset += read.toInt()
            }
            buffer.close()
        }

        speechStart?.let { addSpeechRange(ranges, it, speechEnd, minSpeechBytes) }
        return splitLongSpeechRanges(mergeSpeechRanges(ranges, sampleRateHz), sampleRateHz)
    }

    private fun addSpeechRange(
        ranges: MutableList<PcmSpeechRange>,
        startByte: Int,
        endByte: Int,
        minSpeechBytes: Int,
    ) {
        val start = alignToSampleBoundary(startByte)
        val end = alignToSampleBoundary(endByte).coerceAtLeast(start)
        if (end - start >= minSpeechBytes) {
            ranges += PcmSpeechRange(startByte = start, endByte = end)
        }
    }

    private fun mergeSpeechRanges(
        ranges: List<PcmSpeechRange>,
        sampleRateHz: Int,
    ): List<PcmSpeechRange> {
        if (ranges.isEmpty()) return emptyList()
        val mergeGapBytes = msToPcmBytes(MERGE_SPEECH_GAP_MS, sampleRateHz)
        val merged = mutableListOf<PcmSpeechRange>()
        var current = ranges.first()
        ranges.drop(1).forEach { next ->
            current = if (next.startByte - current.endByte <= mergeGapBytes) {
                current.copy(endByte = maxOf(current.endByte, next.endByte))
            } else {
                merged += current
                next
            }
        }
        merged += current
        return merged
    }

    private fun splitLongSpeechRanges(
        ranges: List<PcmSpeechRange>,
        sampleRateHz: Int,
    ): List<PcmSpeechRange> {
        val maxBytes = msToPcmBytes(MAX_LOCAL_TRANSCRIBE_CHUNK_MS, sampleRateHz)
        return ranges.flatMap { range ->
            if (range.byteLength <= maxBytes) {
                listOf(range)
            } else {
                buildList {
                    var start = range.startByte
                    while (start < range.endByte) {
                        val end = minOf(start + maxBytes, range.endByte)
                        add(PcmSpeechRange(startByte = start, endByte = end))
                        start = end
                    }
                }
            }
        }
    }

    private fun isVoicedPcm(bytes: ByteArray): Boolean {
        val sampleBytes = alignToSampleBoundary(bytes.size)
        if (sampleBytes <= 0) return false
        var sumSquares = 0.0
        var peak = 0
        var index = 0
        while (index < sampleBytes) {
            val lo = bytes[index].toInt() and 0xFF
            val hi = bytes[index + 1].toInt()
            val sample = (hi shl 8) or lo
            val magnitude = kotlin.math.abs(sample)
            if (magnitude > peak) peak = magnitude
            sumSquares += sample.toDouble() * sample.toDouble()
            index += BYTES_PER_SAMPLE
        }
        val rms = sqrt(sumSquares / (sampleBytes / BYTES_PER_SAMPLE))
        return rms >= MIN_VOICE_RMS || peak >= MIN_VOICE_PEAK
    }

    private fun msToPcmBytes(ms: Int, sampleRateHz: Int): Int =
        alignToSampleBoundary((sampleRateHz * BYTES_PER_SAMPLE * ms) / 1_000)

    private fun alignToSampleBoundary(bytes: Int): Int =
        bytes - (bytes % BYTES_PER_SAMPLE)

    private fun parseNativeTranscription(jsonResult: String): NativeTranscription =
        try {
            val result = json.parseToJsonElement(jsonResult).jsonObject
            NativeTranscription(
                text = result.stringValue("response") ?: result.stringValue("text") ?: jsonResult,
                segments = result["segments"].timedSegments(),
                words = result["words"].timedWords(),
            )
        } catch (_: Exception) {
            NativeTranscription(text = jsonResult)
        }

    private fun JsonElement?.timedSegments(): List<TranscriptSegment> =
        (this as? JsonArray)?.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val start = item.secondsToMs("start") ?: return@mapNotNull null
            val end = item.secondsToMs("end") ?: start
            val text = item.stringValue("text")
                ?: item.stringValue("word")
                ?: return@mapNotNull null
            TranscriptSegment(
                text = text.trim(),
                startMs = start,
                endMs = end.coerceAtLeast(start),
                speaker = item.stringValue("speaker"),
            )
        }.orEmpty().filter { it.text.isNotBlank() }

    private fun JsonElement?.timedWords(): List<TranscriptWord> =
        (this as? JsonArray)?.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val start = item.secondsToMs("start") ?: return@mapNotNull null
            val end = item.secondsToMs("end") ?: start
            val text = item.stringValue("word")
                ?: item.stringValue("text")
                ?: return@mapNotNull null
            TranscriptWord(
                text = text.trim(),
                startMs = start,
                endMs = end.coerceAtLeast(start),
            )
        }.orEmpty().filter { it.text.isNotBlank() }

    private fun JsonObject.secondsToMs(key: String): Long? =
        this[key]?.jsonPrimitive?.doubleOrNull?.let { (it * 1_000).toLong() }

    private fun JsonObject.stringValue(key: String): String? =
        this[key]?.jsonPrimitive?.content

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
        private const val BYTES_PER_SAMPLE = 2
        private const val ANALYSIS_WINDOW_MS = 100
        private const val MIN_SPEECH_RANGE_MS = 400
        private const val SPEECH_PREROLL_MS = 450
        private const val SPEECH_POSTROLL_MS = 700
        private const val MERGE_SPEECH_GAP_MS = 1_500
        private const val MAX_LOCAL_TRANSCRIBE_CHUNK_MS = 45_000
        private const val MIN_VOICE_RMS = 45.0
        private const val MIN_VOICE_PEAK = 240
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private val NON_SPEECH_REGEX = "\\[[^\\]]*\\]|\\([^)]*\\)".toRegex()
    }
}

private data class NativeTranscription(
    val text: String,
    val segments: List<TranscriptSegment> = emptyList(),
    val words: List<TranscriptWord> = emptyList(),
) {
    fun offsetBy(startMs: Long, endMs: Long, cleanedText: String): NativeTranscription =
        NativeTranscription(
            text = cleanedText,
            segments = segments.takeIf { it.isNotEmpty() }?.map {
                it.copy(startMs = it.startMs + startMs, endMs = it.endMs + startMs)
            } ?: listOf(
                TranscriptSegment(
                    text = cleanedText,
                    startMs = startMs,
                    endMs = endMs.coerceAtLeast(startMs),
                ),
            ),
            words = words.map {
                it.copy(startMs = it.startMs + startMs, endMs = it.endMs + startMs)
            },
        )
}

private data class PcmSpeechRange(
    val startByte: Int,
    val endByte: Int,
) {
    val byteLength: Int get() = endByte - startByte

    fun startMs(sampleRateHz: Int): Long =
        ((startByte / 2L) * 1_000L) / sampleRateHz

    fun endMs(sampleRateHz: Int): Long =
        ((endByte / 2L) * 1_000L) / sampleRateHz
}
