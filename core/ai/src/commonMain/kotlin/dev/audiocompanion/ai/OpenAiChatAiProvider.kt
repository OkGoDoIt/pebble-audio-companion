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
 * Remote AI provider over OpenAI's Responses API (`/v1/responses`).
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
    private val grounding: () -> String? = { null },
    private val reasoningEffort: String = DEFAULT_REASONING_EFFORT,
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
        val instructions = buildInstructions(request.prompt.systemPrompt)

        val payload = ResponsesRequest(
            model = model(),
            instructions = instructions,
            input = userContent,
            reasoning = ReasoningConfig(effort = reasoningEffort),
        )
        val response: HttpResponse = client.post(endpointUrl) {
            header(HttpHeaders.Authorization, "Bearer $key")
            contentType(ContentType.Application.Json)
            setBody(json.encodeToString(ResponsesRequest.serializer(), payload))
        }
        val body = response.body<String>()
        if (response.status != HttpStatusCode.OK) {
            throw AiException.ProviderFailed(
                "OpenAI responses request failed (${response.status.value}): ${body.take(240)}",
            )
        }
        val parsed = json.decodeFromString(ResponsesResponse.serializer(), body)
        val text = parsed.outputText()?.trim().orEmpty()
        if (text.isEmpty()) {
            throw AiException.ProviderFailed("OpenAI responses returned an empty completion")
        }
        return AiProviderResult(
            text = text,
            modelUsed = parsed.model ?: model(),
            inputTokens = parsed.usage?.inputTokens,
            outputTokens = parsed.usage?.outputTokens,
        )
    }

    private fun buildInstructions(systemPrompt: String): String {
        val groundingBlock = grounding()?.trim()
        return if (groundingBlock.isNullOrEmpty()) {
            systemPrompt
        } else {
            "$groundingBlock\n\n$systemPrompt"
        }
    }

    @Serializable
    private data class ReasoningConfig(val effort: String)

    @Serializable
    private data class ResponsesRequest(
        val model: String,
        val instructions: String,
        val input: String,
        val reasoning: ReasoningConfig? = null,
    )

    @Serializable
    private data class ResponseOutputItem(
        val type: String? = null,
        val content: List<ResponseContentPart>? = null,
    )

    @Serializable
    private data class ResponseContentPart(
        val type: String? = null,
        val text: String? = null,
    )

    @Serializable
    private data class ResponsesUsage(
        @kotlinx.serialization.SerialName("input_tokens") val inputTokens: Int? = null,
        @kotlinx.serialization.SerialName("output_tokens") val outputTokens: Int? = null,
    )

    @Serializable
    private data class ResponsesResponse(
        val model: String? = null,
        @kotlinx.serialization.SerialName("output_text") val outputTextField: String? = null,
        val output: List<ResponseOutputItem>? = null,
        val usage: ResponsesUsage? = null,
    ) {
        fun outputText(): String? {
            val direct = outputTextField?.trim()
            if (!direct.isNullOrEmpty()) return direct
            return output.orEmpty()
                .flatMap { it.content.orEmpty() }
                .filter { it.type == "output_text" || it.type == "text" }
                .mapNotNull { it.text }
                .joinToString("")
                .trim()
                .takeIf { it.isNotEmpty() }
        }
    }

    companion object {
        const val DEFAULT_ENDPOINT_URL = "https://api.openai.com/v1/responses"
        val DEFAULT_MODEL = AiModels.DEFAULT_MODEL_ID
        const val DEFAULT_REASONING_EFFORT = "low"
        private const val DEFAULT_MAX_INPUT_CHARS = 240_000
    }
}
