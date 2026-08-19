@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)

package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.header
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
import kotlin.io.encoding.Base64

/**
 * Real-time (streaming) transcription over the OpenAI Realtime API WebSocket
 * (`wss://api.openai.com/v1/realtime?intent=transcription`). Configures a transcription session,
 * resamples the watch's 16 kHz audio to the 24 kHz the API expects, streams it as base64
 * `input_audio_buffer.append` events, and folds the `...input_audio_transcription.delta`/`.completed`
 * events into [StreamingTranscriptUpdate]s. Foreground-only; OpenAI realtime has no diarization.
 *
 * The [client] must have the ktor WebSockets plugin installed.
 */
class OpenAiRealtimeProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val cloudConsent: () -> Boolean,
    private val model: () -> String = { DEFAULT_MODEL },
    private val url: String = DEFAULT_URL,
    private val targetSampleRate: Int = TARGET_SAMPLE_RATE,
) : StreamingTranscriptionProvider {
    override val id: String = "openai-realtime"
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun isAvailable(): Boolean = cloudConsent() && !apiKey().isNullOrBlank()

    override fun transcribeStream(
        pcm: Flow<ByteArray>,
        sampleRateHz: Int,
    ): Flow<StreamingTranscriptUpdate> = channelFlow {
        if (!cloudConsent()) throw TranscriptionException.ProviderUnavailable(id)
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw TranscriptionException.ProviderUnavailable(id)

        client.webSocket(
            urlString = url,
            request = {
                header("Authorization", "Bearer $key")
            },
        ) {
            send(Frame.Text(sessionConfig()))
            val sender = launch {
                pcm.collect { chunk ->
                    if (chunk.isEmpty()) return@collect
                    val resampled = PcmResampler.resampleLinearMono16(chunk, sampleRateHz, targetSampleRate)
                    send(Frame.Text(appendEvent(Base64.encode(resampled))))
                }
                send(Frame.Text("""{"type":"input_audio_buffer.commit"}"""))
            }
            val accumulator = OpenAiRealtimeAccumulator()
            try {
                for (frame in incoming) {
                    if (frame !is Frame.Text) continue
                    val event = json.decodeFromString(OpenAiRtEvent.serializer(), frame.readText())
                    when (event.type) {
                        DELTA_EVENT -> this@channelFlow.send(accumulator.delta(event.delta.orEmpty()))
                        COMPLETED_EVENT -> this@channelFlow.send(
                            accumulator.completed(event.transcript.orEmpty()),
                        )
                        ERROR_EVENT -> throw TranscriptionException.TranscriptionFailed(
                            "OpenAI realtime error: ${event.error?.message ?: "unknown"}",
                        )
                    }
                }
            } finally {
                sender.cancel()
                close()
            }
        }
    }

    private fun sessionConfig(): String =
        """
        {"type":"session.update","session":{"type":"transcription",
        "audio":{"input":{"format":{"type":"audio/pcm","rate":$targetSampleRate},
        "transcription":{"model":"${model()}"}}}}}
        """.trimIndent().replace("\n", "")

    private fun appendEvent(base64Audio: String): String =
        """{"type":"input_audio_buffer.append","audio":"$base64Audio"}"""

    @Serializable
    private data class OpenAiRtEvent(
        val type: String = "",
        val delta: String? = null,
        val transcript: String? = null,
        val error: OpenAiRtError? = null,
    )

    @Serializable
    private data class OpenAiRtError(
        val message: String? = null,
        @SerialName("type") val type: String? = null,
    )

    companion object {
        const val DEFAULT_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
        const val DEFAULT_MODEL = "gpt-live-transcribe"
        const val TARGET_SAMPLE_RATE = 24_000
        private const val DELTA_EVENT = "conversation.item.input_audio_transcription.delta"
        private const val COMPLETED_EVENT = "conversation.item.input_audio_transcription.completed"
        private const val ERROR_EVENT = "error"
    }
}

/**
 * Pure folding of OpenAI realtime transcription events: `delta`s accumulate into the volatile tail;
 * a `completed` finalizes the current item into the stable transcript. Extracted for unit testing.
 */
class OpenAiRealtimeAccumulator {
    private val completed = StringBuilder()
    private val partial = StringBuilder()

    fun delta(text: String): StreamingTranscriptUpdate {
        partial.append(text)
        return update()
    }

    fun completed(transcript: String): StreamingTranscriptUpdate {
        val cleaned = transcript.trim()
        if (cleaned.isNotEmpty()) {
            if (completed.isNotEmpty()) completed.append(' ')
            completed.append(cleaned)
        }
        partial.clear()
        return update()
    }

    private fun update(): StreamingTranscriptUpdate = StreamingTranscriptUpdate(
        finalText = completed.toString().trim(),
        partialText = partial.toString().trim(),
        isFinal = false,
    )
}
