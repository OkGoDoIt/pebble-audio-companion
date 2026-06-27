package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Real-time (streaming) transcription over the Soniox WebSocket API
 * (`wss://stt-rt.soniox.com/transcribe-websocket`). Sends a config frame, streams `pcm_s16le` mono
 * audio, and folds the incoming token stream (finalized vs. partial, with per-token speakers) into
 * [StreamingTranscriptUpdate]s. Foreground-only: a live socket cannot survive iOS suspension.
 *
 * The [client] must have the ktor WebSockets plugin installed.
 */
class SonioxRealtimeProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val cloudConsent: () -> Boolean,
    private val diarizationEnabled: () -> Boolean = { false },
    private val languageHints: () -> List<String> = { emptyList() },
    private val contextText: () -> String? = { null },
    private val contextTerms: () -> List<String> = { emptyList() },
    private val model: () -> String = { DEFAULT_MODEL },
    private val url: String = DEFAULT_URL,
) : StreamingTranscriptionProvider {
    override val id: String = "soniox-realtime"
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun isAvailable(): Boolean = cloudConsent() && !apiKey().isNullOrBlank()

    override fun transcribeStream(
        pcm: Flow<ByteArray>,
        sampleRateHz: Int,
    ): Flow<StreamingTranscriptUpdate> = channelFlow {
        if (!cloudConsent()) throw TranscriptionException.ProviderUnavailable(id)
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw TranscriptionException.ProviderUnavailable(id)

        client.webSocket(url) {
            send(Frame.Text(configJson(key, sampleRateHz)))
            // Stream audio in the background; signal end-of-audio with an empty text frame.
            val sender = launch {
                pcm.collect { chunk -> if (chunk.isNotEmpty()) send(Frame.Binary(true, chunk)) }
                send(Frame.Text(""))
            }
            val accumulator = SonioxRealtimeAccumulator(diarizationEnabled())
            try {
                for (frame in incoming) {
                    if (frame !is Frame.Text) continue
                    val message = json.decodeFromString(SonioxRtMessage.serializer(), frame.readText())
                    message.errorMessage?.let {
                        throw TranscriptionException.TranscriptionFailed("Soniox realtime error: $it")
                    }
                    this@channelFlow.send(accumulator.accept(message.tokens, finished = message.finished))
                    if (message.finished) break
                }
            } finally {
                sender.cancel()
                close()
            }
        }
    }

    internal fun configJson(key: String, sampleRateHz: Int): String = buildJsonObject {
        put("api_key", key)
        put("model", model())
        // Soniox expects "s16le" for raw 16-bit little-endian PCM (NOT "pcm_s16le"); the wrong
        // value makes the server reject the stream and the live socket fail.
        put("audio_format", RAW_PCM_FORMAT)
        put("sample_rate", sampleRateHz)
        put("num_channels", 1)
        put("enable_speaker_diarization", diarizationEnabled())
        val hints = languageHints()
        if (hints.isNotEmpty()) {
            putJsonArray("language_hints") { hints.forEach { add(JsonPrimitive(it)) } }
        }
        val contextObj = buildSonioxContextJsonObject(contextText(), contextTerms())
        if (contextObj != null) {
            putJsonObject("context") { contextObj.forEach { (k, v) -> put(k, v) } }
        }
    }.let { json.encodeToString(JsonObject.serializer(), it) }

    @Serializable
    private data class SonioxRtMessage(
        val tokens: List<SonioxRtToken> = emptyList(),
        val finished: Boolean = false,
        @SerialName("error_message") val errorMessage: String? = null,
    )

    companion object {
        const val DEFAULT_URL = "wss://stt-rt.soniox.com/transcribe-websocket"
        const val DEFAULT_MODEL = "stt-rt-v5"

        /** Soniox raw-audio format token for 16-bit signed little-endian PCM. */
        const val RAW_PCM_FORMAT = "s16le"
    }
}

@Serializable
data class SonioxRtToken(
    val text: String = "",
    @SerialName("is_final") val isFinal: Boolean = false,
    val speaker: String? = null,
    @SerialName("start_ms") val startMs: Long? = null,
    @SerialName("end_ms") val endMs: Long? = null,
)

/**
 * Pure token-stream folding for Soniox realtime: finalized tokens accumulate into the stable
 * transcript and speaker segments; non-final tokens form the volatile partial tail (replaced each
 * message). Extracted from the socket plumbing so it is unit-testable.
 */
class SonioxRealtimeAccumulator(private val diarization: Boolean) {
    private val finalTokens = mutableListOf<SonioxRtToken>()

    fun accept(tokens: List<SonioxRtToken>, finished: Boolean): StreamingTranscriptUpdate {
        val partial = StringBuilder()
        tokens.forEach { token ->
            if (token.text.isEmpty()) return@forEach
            if (token.isFinal) finalTokens += token else partial.append(token.text)
        }
        return StreamingTranscriptUpdate(
            finalText = finalTokens.joinToString("") { it.text }.trim(),
            partialText = partial.toString().trim(),
            segments = if (diarization) groupBySpeaker(finalTokens) else emptyList(),
            isFinal = finished,
        )
    }

    private fun groupBySpeaker(tokens: List<SonioxRtToken>): List<TranscriptSegment> {
        if (tokens.isEmpty()) return emptyList()
        val segments = mutableListOf<TranscriptSegment>()
        val current = StringBuilder()
        var speaker = tokens.first().speaker
        var start = tokens.first().startMs ?: 0
        var end = tokens.first().endMs ?: start

        fun flush() {
            val text = current.toString().trim()
            if (text.isNotBlank()) {
                segments += TranscriptSegment(text, start, end.coerceAtLeast(start), speaker)
            }
            current.clear()
        }

        tokens.forEach { token ->
            if (current.isNotEmpty() && token.speaker != speaker) {
                flush()
                speaker = token.speaker
                start = token.startMs ?: start
            }
            current.append(token.text)
            token.endMs?.let { end = it }
        }
        flush()
        return segments
    }
}
