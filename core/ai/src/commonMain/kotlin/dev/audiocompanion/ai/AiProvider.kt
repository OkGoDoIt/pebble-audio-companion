package dev.audiocompanion.ai

import kotlinx.serialization.Serializable

@Serializable
enum class AiProcessingMode {
    LocalOnly,
    RemoteOnly,
    LocalFirst,
    RemoteFirst,
}

@Serializable
data class TranscriptExcerpt(
    val segmentId: String,
    val text: String,
    val startTimeMs: Long? = null,
    val endTimeMs: Long? = null,
)

@Serializable
data class AiPromptTemplate(
    val id: String,
    val title: String,
    val systemPrompt: String,
    val userPrompt: String,
)

data class AiRunRequest(
    val requestId: String,
    val prompt: AiPromptTemplate,
    val transcripts: List<TranscriptExcerpt>,
    val metadata: Map<String, String> = emptyMap(),
) {
    init {
        require(transcripts.isNotEmpty()) { "AI runs require durable transcript input" }
    }
}

data class AiProviderResult(
    val text: String,
    val modelUsed: String? = null,
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
)

data class RoutedAiResult(
    val text: String,
    val modeUsed: AiProcessingMode,
    val providerId: String,
    val modelUsed: String?,
    val inputTokens: Int?,
    val outputTokens: Int?,
)

sealed class AiException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class ProviderUnavailable(providerId: String) : AiException("AI provider unavailable: $providerId")
    class ConsentRequired(providerId: String) : AiException("AI provider requires consent: $providerId")
}

interface AiProvider {
    val id: String

    suspend fun isAvailable(): Boolean

    suspend fun run(request: AiRunRequest): AiProviderResult
}
