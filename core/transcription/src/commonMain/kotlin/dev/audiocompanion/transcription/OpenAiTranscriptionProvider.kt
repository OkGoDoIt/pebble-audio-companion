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

/**
 * Cloud transcription provider for bounded, durable segment chunks.
 *
 * Uses OpenAI's Audio API `transcriptions` endpoint. PCM is uploaded only when the user has
 * explicitly enabled cloud transcription consent and provided an API key.
 */
class OpenAiTranscriptionProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val cloudConsent: () -> Boolean,
    private val model: () -> String = { DEFAULT_MODEL },
    private val endpointUrl: String = DEFAULT_ENDPOINT_URL,
    private val maxUploadBytes: Int = DEFAULT_MAX_UPLOAD_BYTES,
) : TranscriptionProvider {
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

        val transcripts = mutableListOf<String>()
        var chunkIndex = 0
        val pcmUploadLimit = maxUploadBytes - WAV_HEADER_BYTES
        val buffer = Buffer()
        try {
            pcmChunks.collect { chunk ->
                var offset = 0
                while (offset < chunk.size) {
                    val writable = minOf(pcmUploadLimit - buffer.size.toInt(), chunk.size - offset)
                    if (writable <= 0) {
                        transcripts += uploadChunk(
                            key = key,
                            pcm = buffer.readByteArray(buffer.size.toInt()),
                            sampleRateHz = sampleRateHz,
                            chunkIndex = chunkIndex++,
                        )
                        continue
                    }
                    buffer.write(chunk, offset, offset + writable)
                    offset += writable
                }
            }
            if (buffer.size > 0) {
                transcripts += uploadChunk(
                    key = key,
                    pcm = buffer.readByteArray(buffer.size.toInt()),
                    sampleRateHz = sampleRateHz,
                    chunkIndex = chunkIndex,
                )
            }
        } finally {
            buffer.close()
        }

        val text = transcripts.joinToString(separator = "\n").trim()
        if (text.isBlank()) {
            throw TranscriptionException.NoSpeechDetected("OpenAI returned an empty transcript")
        }
        return TranscriptionResult(
            text = text,
            providerId = id,
            modelUsed = model(),
        )
    }

    private suspend fun uploadChunk(
        key: String,
        pcm: ByteArray,
        sampleRateHz: Int,
        chunkIndex: Int,
    ): String {
        if (pcm.isEmpty()) {
            throw TranscriptionException.NoSpeechDetected("empty PCM chunk")
        }
        val wav = PcmWav.encodeMono16(pcm, sampleRateHz)
        if (wav.size > maxUploadBytes) {
            throw TranscriptionException.TranscriptionFailed(
                "WAV upload chunk ${wav.size} exceeds $maxUploadBytes byte limit",
            )
        }
        val response: HttpResponse = client.post(endpointUrl) {
            header(HttpHeaders.Authorization, "Bearer $key")
            setBody(
                MultiPartFormDataContent(
                    formData {
                        append("model", model())
                        append("response_format", "json")
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
        return json.decodeFromString(OpenAiTranscriptionResponse.serializer(), body).text
    }

    @Serializable
    private data class OpenAiTranscriptionResponse(val text: String = "")

    companion object {
        const val DEFAULT_ENDPOINT_URL = "https://api.openai.com/v1/audio/transcriptions"
        const val DEFAULT_MODEL = "gpt-4o-mini-transcribe"
        private const val WAV_HEADER_BYTES = 44
        private const val DEFAULT_MAX_UPLOAD_BYTES = 24_000_000
    }
}
