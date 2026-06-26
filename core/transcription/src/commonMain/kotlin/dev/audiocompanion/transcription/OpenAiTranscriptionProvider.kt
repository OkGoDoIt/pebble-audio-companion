package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.io.Buffer
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.roundToLong

/**
 * Cloud transcription provider for bounded, durable segment chunks.
 *
 * Uses OpenAI's Audio API `transcriptions` endpoint. PCM is uploaded only when the current
 * transcription mode can use cloud transcription and an API key is configured.
 */
class OpenAiTranscriptionProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val cloudConsent: () -> Boolean,
    private val model: () -> String = { DEFAULT_MODEL },
    /**
     * When true, transcription is routed through the diarization model
     * ([DIARIZE_MODEL], `diarized_json`) so segments carry a `speaker`. This overrides [model],
     * since only the diarize model returns speaker labels. The tradeoff is no word-level timings.
     */
    private val diarizationEnabled: () -> Boolean = { false },
    private val endpointUrl: String = DEFAULT_ENDPOINT_URL,
    private val maxUploadBytes: Int = DEFAULT_MAX_UPLOAD_BYTES,
) : TranscriptionProvider, CloudUploadCapable {
    override val id: String = "openai"
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)

    private val json = Json { ignoreUnknownKeys = true }

    init {
        require(maxUploadBytes > WAV_HEADER_BYTES) {
            "maxUploadBytes must leave room for a WAV header"
        }
    }

    override suspend fun isAvailable(): Boolean =
        cloudConsent() && !apiKey().isNullOrBlank()

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult {
        if (!cloudConsent()) {
            throw TranscriptionException.ProviderUnavailable(id)
        }
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw TranscriptionException.ProviderUnavailable(id)

        val transcripts = mutableListOf<OpenAiChunkResult>()
        var chunkIndex = 0
        var chunkStartMs = 0L
        val pcmUploadLimit = maxUploadBytes - WAV_HEADER_BYTES
        val buffer = Buffer()
        try {
            pcmChunks.collect { chunk ->
                var offset = 0
                while (offset < chunk.size) {
                    val writable = minOf(pcmUploadLimit - buffer.size.toInt(), chunk.size - offset)
                    if (writable <= 0) {
                        val pcm = buffer.readByteArray(buffer.size.toInt())
                        transcripts += uploadChunk(
                            key = key,
                            pcm = pcm,
                            sampleRateHz = sampleRateHz,
                            chunkIndex = chunkIndex++,
                            chunkStartMs = chunkStartMs,
                        )
                        chunkStartMs += pcm.durationMs(sampleRateHz)
                        continue
                    }
                    buffer.write(chunk, offset, offset + writable)
                    offset += writable
                }
            }
            if (buffer.size > 0) {
                val pcm = buffer.readByteArray(buffer.size.toInt())
                transcripts += uploadChunk(
                    key = key,
                    pcm = pcm,
                    sampleRateHz = sampleRateHz,
                    chunkIndex = chunkIndex,
                    chunkStartMs = chunkStartMs,
                )
            }
        } finally {
            buffer.close()
        }

        val text = transcripts.joinToString(separator = "\n") { it.text }.trim()
        if (text.isBlank()) {
            throw TranscriptionException.NoSpeechDetected("OpenAI returned an empty transcript")
        }
        return TranscriptionResult(
            text = text,
            providerId = id,
            modelUsed = effectiveModel(),
            segments = transcripts.flatMap { it.segments },
            words = transcripts.flatMap { it.words },
        )
    }

    /** The diarize model takes precedence when diarization is on; only it returns speakers. */
    private fun effectiveModel(): String = if (diarizationEnabled()) DIARIZE_MODEL else model()

    private fun responseFormat(model: String): String = when (model) {
        DIARIZE_MODEL -> "diarized_json"
        "whisper-1" -> "verbose_json"
        else -> "json"
    }

    private suspend fun uploadChunk(
        key: String,
        pcm: ByteArray,
        sampleRateHz: Int,
        chunkIndex: Int,
        chunkStartMs: Long,
    ): OpenAiChunkResult {
        if (pcm.isEmpty()) {
            throw TranscriptionException.NoSpeechDetected("empty PCM chunk")
        }
        val wav = PcmWav.encodeMono16(pcm, sampleRateHz)
        if (wav.size > maxUploadBytes) {
            throw TranscriptionException.TranscriptionFailed(
                "WAV upload chunk ${wav.size} exceeds $maxUploadBytes byte limit",
            )
        }
        val modelValue = effectiveModel()
        val format = responseFormat(modelValue)
        val response: HttpResponse = client.post(endpointUrl) {
            header(HttpHeaders.Authorization, "Bearer $key")
            setBody(
                MultiPartFormDataContent(
                    formData {
                        append("model", modelValue)
                        append("response_format", format)
                        if (format == "verbose_json") {
                            append("timestamp_granularities[]", "segment")
                            append("timestamp_granularities[]", "word")
                        }
                        append(
                            "file",
                            wav,
                            Headers.build {
                                append(HttpHeaders.ContentType, "audio/wav")
                                append(
                                    HttpHeaders.ContentDisposition,
                                    "filename=\"segment-$chunkIndex.wav\"",
                                )
                            },
                        )
                    },
                ),
            )
        }
        val body = response.body<String>()
        if (response.status != HttpStatusCode.OK) {
            throw TranscriptionException.TranscriptionFailed(
                "OpenAI transcription failed (${response.status.value}): ${body.take(240)}",
            )
        }
        return parseChunk(body, chunkStartMs)
    }

    private fun parseChunk(body: String, offsetMs: Long): OpenAiChunkResult =
        when (responseFormat(effectiveModel())) {
            "verbose_json" ->
                json.decodeFromString(OpenAiVerboseTranscriptionResponse.serializer(), body)
                    .toChunkResult(offsetMs)
            "diarized_json" ->
                json.decodeFromString(OpenAiDiarizedTranscriptionResponse.serializer(), body)
                    .toChunkResult(offsetMs)
            else ->
                OpenAiChunkResult(
                    text = json.decodeFromString(OpenAiTranscriptionResponse.serializer(), body).text,
                )
        }

    // --- CloudUploadCapable: single-shot background upload (response is the transcript) ----------

    override suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int): CloudUploadPlan? {
        if (!cloudConsent()) return null
        val key = apiKey()?.takeIf { it.isNotBlank() } ?: return null
        // One background upload is a single request; segments larger than the API limit stay on the
        // synchronous chunked path.
        if (wav.size > maxUploadBytes) return null
        val modelValue = effectiveModel()
        val format = responseFormat(modelValue)
        val fields = buildList {
            add("model" to modelValue)
            add("response_format" to format)
            if (format == "verbose_json") {
                add("timestamp_granularities[]" to "segment")
                add("timestamp_granularities[]" to "word")
            }
        }
        return CloudUploadPlan(
            url = endpointUrl,
            headers = mapOf("Authorization" to "Bearer $key"),
            textFields = fields,
            file = MultipartBody.FilePart("file", "segment.wav", "audio/wav", wav),
        )
    }

    override suspend fun onUploadResponse(httpStatus: Int, body: String): CloudUploadStep {
        if (httpStatus !in 200..299) {
            throw TranscriptionException.TranscriptionFailed(
                "OpenAI transcription failed ($httpStatus): ${body.take(240)}",
            )
        }
        val chunk = parseChunk(body, 0L)
        val text = chunk.text.trim()
        if (text.isBlank()) {
            throw TranscriptionException.NoSpeechDetected("OpenAI returned an empty transcript")
        }
        return CloudUploadStep.Done(
            TranscriptionResult(
                text = text,
                providerId = id,
                modelUsed = effectiveModel(),
                segments = chunk.segments,
                words = chunk.words,
            ),
        )
    }

    override suspend fun completeControlPlane(controlState: String): TranscriptionResult =
        throw TranscriptionException.TranscriptionFailed("OpenAI uploads have no control-plane step")

    @Serializable
    private data class OpenAiTranscriptionResponse(val text: String = "")

    @Serializable
    private data class OpenAiVerboseTranscriptionResponse(
        val text: String = "",
        val segments: List<OpenAiTimedText> = emptyList(),
        val words: List<OpenAiTimedWord> = emptyList(),
    ) {
        fun toChunkResult(offsetMs: Long): OpenAiChunkResult =
            OpenAiChunkResult(
                text = text,
                segments = segments.mapNotNull { segment ->
                    val cleaned = segment.text.trim()
                    if (cleaned.isBlank()) return@mapNotNull null
                    TranscriptSegment(
                        text = cleaned,
                        startMs = offsetMs + (segment.start * 1_000).roundToLong(),
                        endMs = offsetMs + (segment.end * 1_000).roundToLong(),
                    )
                },
                words = words.mapNotNull { word ->
                    val cleaned = word.word.trim()
                    if (cleaned.isBlank()) return@mapNotNull null
                    TranscriptWord(
                        text = cleaned,
                        startMs = offsetMs + (word.start * 1_000).roundToLong(),
                        endMs = offsetMs + (word.end * 1_000).roundToLong(),
                    )
                },
            )
    }

    @Serializable
    private data class OpenAiDiarizedTranscriptionResponse(
        val text: String = "",
        val segments: List<OpenAiDiarizedSegment> = emptyList(),
    ) {
        fun toChunkResult(offsetMs: Long): OpenAiChunkResult =
            OpenAiChunkResult(
                text = text,
                segments = segments.mapNotNull { segment ->
                    val cleaned = segment.text.trim()
                    if (cleaned.isBlank()) return@mapNotNull null
                    TranscriptSegment(
                        text = cleaned,
                        startMs = offsetMs + (segment.start * 1_000).roundToLong(),
                        endMs = offsetMs + (segment.end * 1_000).roundToLong(),
                        speaker = segment.speaker,
                    )
                },
            )
    }

    @Serializable
    private data class OpenAiDiarizedSegment(
        val text: String = "",
        val start: Double = 0.0,
        val end: Double = 0.0,
        val speaker: String? = null,
    )

    @Serializable
    private data class OpenAiTimedText(
        val text: String = "",
        val start: Double = 0.0,
        val end: Double = 0.0,
    )

    @Serializable
    private data class OpenAiTimedWord(
        val word: String = "",
        val start: Double = 0.0,
        val end: Double = 0.0,
    )

    private data class OpenAiChunkResult(
        val text: String,
        val segments: List<TranscriptSegment> = emptyList(),
        val words: List<TranscriptWord> = emptyList(),
    )

    private fun ByteArray.durationMs(sampleRateHz: Int): Long =
        (size / BYTES_PER_SAMPLE.toDouble() / sampleRateHz * 1_000).roundToLong()

    companion object {
        const val DEFAULT_ENDPOINT_URL = "https://api.openai.com/v1/audio/transcriptions"
        const val DEFAULT_MODEL = "gpt-4o-mini-transcribe"

        /** OpenAI's speaker-diarization model; returns `diarized_json` with per-segment speakers. */
        const val DIARIZE_MODEL = "gpt-4o-transcribe-diarize"
        private const val WAV_HEADER_BYTES = 44
        private const val BYTES_PER_SAMPLE = 2
        private const val DEFAULT_MAX_UPLOAD_BYTES = 24_000_000
    }
}
