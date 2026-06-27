package dev.audiocompanion.ai

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Remote AI provider over OpenAI's chat completions endpoint.
 *
 * Fail-closed: transcripts leave the phone only when the user has enabled remote AI consent and
 * provided an API key; otherwise the provider reports unavailable and refuses to run. Input is
 * durable transcript text only — never audio, never live BLE data.
 */
class OpenAiChatAiProvider(
    private val client: HttpClient,
    private val apiKey: () -> String?,
    private val remoteConsent: () -> Boolean,
    private val model: () -> String = { DEFAULT_MODEL },
    private val endpointUrl: String = DEFAULT_ENDPOINT_URL,
    private val maxInputChars: Int = DEFAULT_MAX_INPUT_CHARS,
) : AiProvider {
    override val id: String = "openai-chat"

    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun isAvailable(): Boolean =
        remoteConsent() && !apiKey().isNullOrBlank()

    override suspend fun run(request: AiRunRequest): AiProviderResult {
        if (!remoteConsent()) {
            throw AiException.ConsentRequired(id)
        }
        val key = apiKey()?.takeIf { it.isNotBlank() }
            ?: throw AiException.ProviderUnavailable(id)

        val userContent = AiTranscriptFormatting.buildUserContent(request, maxInputChars)

        val payload = ChatRequest(
            model = model(),
            messages = listOf(
                ChatMessage(role = "system", content = request.prompt.systemPrompt),
                ChatMessage(role = "user", content = userContent),
            ),
        )
        val response: HttpResponse = client.post(endpointUrl) {
            header(HttpHeaders.Authorization, "Bearer $key")
            contentType(ContentType.Application.Json)
            setBody(json.encodeToString(ChatRequest.serializer(), payload))
        }
        val body = response.body<String>()
        if (response.status != HttpStatusCode.OK) {
            throw AiException.ProviderFailed(
                "OpenAI chat request failed (${response.status.value}): ${body.take(240)}",
            )
        }
        val parsed = json.decodeFromString(ChatResponse.serializer(), body)
        val text = parsed.choices.firstOrNull()?.message?.content?.trim().orEmpty()
        if (text.isEmpty()) {
            throw AiException.ProviderFailed("OpenAI chat returned an empty completion")
        }
        return AiProviderResult(
            text = text,
            modelUsed = parsed.model ?: model(),
            inputTokens = parsed.usage?.promptTokens,
            outputTokens = parsed.usage?.completionTokens,
        )
    }

    @Serializable
    private data class ChatMessage(val role: String, val content: String)

    @Serializable
    private data class ChatRequest(
        val model: String,
        val messages: List<ChatMessage>,
    )

    @Serializable
    private data class ChatChoice(val message: ChatMessage? = null)

    @Serializable
    private data class ChatUsage(
        @kotlinx.serialization.SerialName("prompt_tokens") val promptTokens: Int? = null,
        @kotlinx.serialization.SerialName("completion_tokens") val completionTokens: Int? = null,
    )

    @Serializable
    private data class ChatResponse(
        val model: String? = null,
        val choices: List<ChatChoice> = emptyList(),
        val usage: ChatUsage? = null,
    )

    companion object {
        const val DEFAULT_ENDPOINT_URL = "https://api.openai.com/v1/chat/completions"
        val DEFAULT_MODEL = AiModels.DEFAULT_MODEL_ID
        private const val DEFAULT_MAX_INPUT_CHARS = 240_000
    }
}
