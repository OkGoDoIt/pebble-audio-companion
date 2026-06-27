package dev.audiocompanion.ai

/**
 * Catalog of remote AI models the user can pick for automatic titles/summaries and the manual AI
 * flow. The id is sent verbatim as the API `model`; display strings drive the Settings picker.
 */
data class AiModelSpec(
    val id: String,
    val displayName: String,
    val description: String,
    val recommended: Boolean = false,
)

object AiModels {
    const val DEFAULT_MODEL_ID = "gpt-5.4-mini"

    val all: List<AiModelSpec> = listOf(
        AiModelSpec(
            id = "gpt-5.4-mini",
            displayName = "GPT-5.4 mini",
            description = "Balanced quality, cost, and speed. Recommended for automatic titles " +
                "and summaries.",
            recommended = true,
        ),
        AiModelSpec(
            id = "gpt-5.5",
            displayName = "GPT-5.5",
            description = "Most capable frontier model. Best titles and summaries; higher cost.",
        ),
        AiModelSpec(
            id = "gpt-5.4",
            displayName = "GPT-5.4",
            description = "Affordable frontier model for professional work.",
        ),
        AiModelSpec(
            id = "gpt-5.4-nano",
            displayName = "GPT-5.4 nano",
            description = "Cheapest GPT-5.4-class model for simple high-volume tasks.",
        ),
    )

    val default: AiModelSpec = all.first { it.id == DEFAULT_MODEL_ID }

    fun byId(id: String?): AiModelSpec =
        all.firstOrNull { it.id == id } ?: default
}
