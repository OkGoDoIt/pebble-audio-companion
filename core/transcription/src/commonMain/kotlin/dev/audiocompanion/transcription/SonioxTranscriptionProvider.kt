package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.isSuccess
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.io.Buffer
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.coroutines.cancellation.CancellationException

/**
 * Cloud transcription provider backed by the Soniox async REST API
 * (`https://api.soniox.com/v1`). A bounded, durable segment is transcribed by:
 *
 *  1. `POST /v1/files` (multipart) -> file id,
 *  2. `POST /v1/transcriptions` (json, references the file) -> transcription id,
 *  3. poll `GET /v1/transcriptions/{id}` until `status` is `completed`/`error`,
 *  4. `GET /v1/transcriptions/{id}/transcript` -> tokens, then best-effort delete of both.
 *
 * The synchronous [transcribe] runs the whole flow (polling included), so it plugs into the
 * existing [TranscriptionProcessor]/[TranscriptionModeRouter] for closed segments with no changes
 * to the local path. Speaker diarization is opt-in ([diarizationEnabled]); per-token speakers are
 * grouped into [TranscriptSegment]s. The detached background-upload variant lives in a later layer;
 * this is the foreground / BGProcessing-window path.
 */
class SonioxTranscriptionProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val cloudConsent: () -> Boolean,
    private val diarizationEnabled: () -> Boolean = { false },
    private val languageHints: () -> List<String> = { emptyList() },
    private val contextText: () -> String? = { null },
    private val contextTerms: () -> List<String> = { emptyList() },
    private val model: () -> String = { DEFAULT_MODEL },
    private val baseUrl: String = DEFAULT_BASE_URL,
    private val pollIntervalMs: Long = DEFAULT_POLL_INTERVAL_MS,
    private val maxPollAttempts: Int = DEFAULT_MAX_POLL_ATTEMPTS,
    private val maxUploadBytes: Int = DEFAULT_MAX_UPLOAD_BYTES,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) : TranscriptionProvider, CloudUploadCapable, CloudConnectivityCheck {
    override val id: String = PROVIDER_ID
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)

    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun isAvailable(): Boolean =
        cloudConsent() && !apiKey().isNullOrBlank()

    override suspend fun checkConnectivity(): CloudConnectivityResult {
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: return CloudConnectivityResult.NotConfigured(
                "Add a Soniox API key to use cloud transcription.",
            )
        return try {
            // Cheapest authenticated call: list transcriptions. 2xx = key accepted.
            val response = client.get("$baseUrl/v1/transcriptions") {
                header(HttpHeaders.Authorization, "Bearer $key")
            }
            when {
                response.status.isSuccess() -> CloudConnectivityResult.Ok("Soniox connected")
                response.status == HttpStatusCode.Unauthorized ||
                    response.status == HttpStatusCode.Forbidden ->
                    CloudConnectivityResult.Failed("Soniox rejected the API key.")
                else -> CloudConnectivityResult.Failed(
                    "Soniox check failed (${response.status.value}): " +
                        response.body<String>().take(160),
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            CloudConnectivityResult.Failed("Could not reach Soniox: ${t.message ?: "network error"}")
        }
    }

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult {
        if (!cloudConsent()) throw TranscriptionException.ProviderUnavailable(id)
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw TranscriptionException.ProviderUnavailable(id)

        val wav = encodeWav(pcmChunks, sampleRateHz)

        val fileId = uploadFile(key, wav)
        try {
            val transcriptionId = createTranscription(key, fileId)
            try {
                awaitCompletion(key, transcriptionId)
                val transcript = fetchTranscript(key, transcriptionId)
                return mapTranscript(transcript)
            } finally {
                deleteQuietly(key, "$baseUrl/v1/transcriptions/$transcriptionId")
            }
        } finally {
            deleteQuietly(key, "$baseUrl/v1/files/$fileId")
        }
    }

    // --- CloudUploadCapable: background-upload the file, finish the control plane in an awake window

    override suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int): CloudUploadPlan? {
        if (!cloudConsent()) return null
        val key = apiKey()?.takeIf { it.isNotBlank() } ?: return null
        if (wav.size > maxUploadBytes) return null
        return CloudUploadPlan(
            url = "$baseUrl/v1/files",
            headers = mapOf("Authorization" to "Bearer $key"),
            file = MultipartBody.FilePart("file", "segment.wav", "audio/wav", wav),
        )
    }

    override suspend fun onUploadResponse(httpStatus: Int, body: String): CloudUploadStep {
        if (httpStatus !in 200..299) {
            throw failure("file upload", HttpStatusCode.fromValue(httpStatus), body)
        }
        val fileId = json.decodeFromString(SonioxFile.serializer(), body).id
            ?: throw TranscriptionException.TranscriptionFailed("Soniox upload returned no file id")
        return CloudUploadStep.NeedsControlPlane(fileId)
    }

    override suspend fun completeControlPlane(controlState: String): TranscriptionResult {
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw TranscriptionException.ProviderUnavailable(id)
        try {
            val transcriptionId = createTranscription(key, controlState)
            try {
                awaitCompletion(key, transcriptionId)
                return mapTranscript(fetchTranscript(key, transcriptionId))
            } finally {
                deleteQuietly(key, "$baseUrl/v1/transcriptions/$transcriptionId")
            }
        } finally {
            deleteQuietly(key, "$baseUrl/v1/files/$controlState")
        }
    }

    private suspend fun encodeWav(pcmChunks: Flow<ByteArray>, sampleRateHz: Int): ByteArray {
        val buffer = Buffer()
        try {
            pcmChunks.collect { chunk ->
                if (chunk.isNotEmpty()) {
                    if (buffer.size + chunk.size > maxUploadBytes.toLong()) {
                        throw TranscriptionException.TranscriptionFailed(
                            "segment audio exceeds $maxUploadBytes byte Soniox upload limit",
                        )
                    }
                    buffer.write(chunk)
                }
            }
            val pcm = buffer.readByteArray(buffer.size.toInt())
            if (pcm.isEmpty()) {
                throw TranscriptionException.NoSpeechDetected("empty audio for Soniox upload")
            }
            return PcmWav.encodeMono16(pcm, sampleRateHz)
        } finally {
            buffer.close()
        }
    }

    private suspend fun uploadFile(key: String, wav: ByteArray): String {
        val response: HttpResponse = client.post("$baseUrl/v1/files") {
            header(HttpHeaders.Authorization, "Bearer $key")
            setBody(
                MultiPartFormDataContent(
                    formData {
                        append(
                            "file",
                            wav,
                            Headers.build {
                                append(HttpHeaders.ContentType, "audio/wav")
                                append(HttpHeaders.ContentDisposition, "filename=\"segment.wav\"")
                            },
                        )
                    },
                ),
            )
        }
        val body = response.body<String>()
        if (!response.status.isSuccess()) {
            throw failure("file upload", response.status, body)
        }
        return json.decodeFromString(SonioxFile.serializer(), body).id
            ?: throw TranscriptionException.TranscriptionFailed("Soniox upload returned no file id")
    }

    private suspend fun createTranscription(key: String, fileId: String): String {
        val request = SonioxCreateTranscription(
            model = model(),
            fileId = fileId,
            enableSpeakerDiarization = diarizationEnabled(),
            languageHints = languageHints().ifEmpty { null },
            context = sonioxContextFrom(contextText, contextTerms),
        )
        val response: HttpResponse = client.post("$baseUrl/v1/transcriptions") {
            header(HttpHeaders.Authorization, "Bearer $key")
            header(HttpHeaders.ContentType, "application/json")
            setBody(json.encodeToString(SonioxCreateTranscription.serializer(), request))
        }
        val body = response.body<String>()
        if (!response.status.isSuccess()) {
            throw failure("create transcription", response.status, body)
        }
        return json.decodeFromString(SonioxTranscription.serializer(), body).id
            ?: throw TranscriptionException.TranscriptionFailed("Soniox create returned no id")
    }

    private suspend fun awaitCompletion(key: String, transcriptionId: String) {
        repeat(maxPollAttempts) { attempt ->
            val response: HttpResponse = client.get("$baseUrl/v1/transcriptions/$transcriptionId") {
                header(HttpHeaders.Authorization, "Bearer $key")
            }
            val body = response.body<String>()
            if (!response.status.isSuccess()) {
                throw failure("poll", response.status, body)
            }
            val transcription = json.decodeFromString(SonioxTranscription.serializer(), body)
            when (transcription.status) {
                STATUS_COMPLETED -> return
                STATUS_ERROR -> throw TranscriptionException.TranscriptionFailed(
                    "Soniox transcription error: ${transcription.errorMessage ?: "unknown"}",
                )
                else -> if (attempt < maxPollAttempts - 1) sleep(pollIntervalMs)
            }
        }
        throw TranscriptionException.TranscriptionFailed("Soniox transcription timed out")
    }

    private suspend fun fetchTranscript(key: String, transcriptionId: String): SonioxTranscript {
        val response: HttpResponse =
            client.get("$baseUrl/v1/transcriptions/$transcriptionId/transcript") {
                header(HttpHeaders.Authorization, "Bearer $key")
            }
        val body = response.body<String>()
        if (!response.status.isSuccess()) {
            throw failure("fetch transcript", response.status, body)
        }
        return json.decodeFromString(SonioxTranscript.serializer(), body)
    }

    private fun mapTranscript(transcript: SonioxTranscript): TranscriptionResult {
        val spokenTokens = transcript.tokens.filter { it.isAudioEvent != true && it.text.isNotBlank() }
        val text = transcript.text?.trim().takeUnless { it.isNullOrBlank() }
            ?: spokenTokens.joinToString(separator = "") { it.text }.trim()
        if (text.isBlank()) {
            throw TranscriptionException.NoSpeechDetected("Soniox returned no speech")
        }
        return TranscriptionResult(
            text = text,
            providerId = id,
            modelUsed = model(),
            segments = groupIntoSegments(spokenTokens),
            words = spokenTokens.map { token ->
                TranscriptWord(
                    text = token.text.trim(),
                    startMs = token.startMs,
                    endMs = token.endMs.coerceAtLeast(token.startMs),
                )
            }.filter { it.text.isNotBlank() },
        )
    }

    /** Groups consecutive tokens into segments, breaking on a speaker change or a silence gap. */
    private fun groupIntoSegments(tokens: List<SonioxToken>): List<TranscriptSegment> {
        if (tokens.isEmpty()) return emptyList()
        val segments = mutableListOf<TranscriptSegment>()
        val current = StringBuilder()
        var start = tokens.first().startMs
        var end = tokens.first().endMs
        var speaker = tokens.first().speaker
        var prevEnd = tokens.first().startMs

        fun flush() {
            val cleaned = current.toString().trim()
            if (cleaned.isNotBlank()) {
                segments += TranscriptSegment(
                    text = cleaned,
                    startMs = start,
                    endMs = end.coerceAtLeast(start),
                    speaker = speaker,
                )
            }
            current.clear()
        }

        tokens.forEach { token ->
            val speakerChanged = token.speaker != speaker
            val longGap = token.startMs - prevEnd > SEGMENT_GAP_MS
            if (current.isNotEmpty() && (speakerChanged || longGap)) {
                flush()
                start = token.startMs
                speaker = token.speaker
            }
            current.append(token.text)
            end = token.endMs
            prevEnd = token.endMs
        }
        flush()
        return segments
    }

    private suspend fun deleteQuietly(key: String, url: String) {
        try {
            client.delete(url) { header(HttpHeaders.Authorization, "Bearer $key") }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            // Best-effort cleanup; leaving a file/transcription behind is not worth failing over.
        }
    }

    private fun failure(stage: String, status: HttpStatusCode, body: String): TranscriptionException =
        TranscriptionException.TranscriptionFailed(
            "Soniox $stage failed (${status.value}): ${body.take(240)}",
        )

    @Serializable
    private data class SonioxFile(val id: String? = null)

    @Serializable
    private data class SonioxCreateTranscription(
        val model: String,
        @kotlinx.serialization.SerialName("file_id") val fileId: String,
        @kotlinx.serialization.SerialName("enable_speaker_diarization")
        val enableSpeakerDiarization: Boolean = false,
        @kotlinx.serialization.SerialName("language_hints")
        val languageHints: List<String>? = null,
        val context: SonioxContext? = null,
    )

    @Serializable
    private data class SonioxTranscription(
        val id: String? = null,
        val status: String? = null,
        @kotlinx.serialization.SerialName("error_message") val errorMessage: String? = null,
    )

    @Serializable
    private data class SonioxTranscript(
        val text: String? = null,
        val tokens: List<SonioxToken> = emptyList(),
    )

    @Serializable
    private data class SonioxToken(
        val text: String = "",
        @kotlinx.serialization.SerialName("start_ms") val startMs: Long = 0,
        @kotlinx.serialization.SerialName("end_ms") val endMs: Long = 0,
        val speaker: String? = null,
        @kotlinx.serialization.SerialName("is_audio_event") val isAudioEvent: Boolean? = null,
    )

    companion object {
        const val PROVIDER_ID = "soniox"
        const val DEFAULT_BASE_URL = "https://api.soniox.com"
        const val DEFAULT_MODEL = "stt-async-v5"
        private const val DEFAULT_POLL_INTERVAL_MS = 2_000L
        private const val DEFAULT_MAX_POLL_ATTEMPTS = 150
        private const val DEFAULT_MAX_UPLOAD_BYTES = 100 * 1024 * 1024
        private const val SEGMENT_GAP_MS = 800L
        private const val STATUS_COMPLETED = "completed"
        private const val STATUS_ERROR = "error"
    }
}
