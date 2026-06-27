package dev.audiocompanion.ai

/**
 * One selectable remote AI model (OpenAI chat). The id is sent verbatim as the API `model`; the
 * display strings drive the Settings picker. Kept here (not in the app module) so the provider's
 * default and the picker share a single source of truth.
 */
data class AiModelSpec(
    val id: String,
    val displayName: String,
    val description: String,
    val recommended: Boolean = false,
)

/**
 * Catalog of remote AI models the user can pick for automatic titles/summaries and the manual AI
 * flow. gpt-5.5 mini is the default: good enough for short row labels at a fraction of the cost and
 * latency of full gpt-5.5.
 */
object AiModels {
    const val DEFAULT_MODEL_ID = "gpt-5.5-mini"

    val all: List<AiModelSpec> = listOf(
        AiModelSpec(
            id = "gpt-5.5-mini",
            displayName = "GPT-5.5 mini",
            description = "Balanced quality, cost, and speed. Recommended for automatic titles " +
                "and summaries.",
            recommended = true,
        ),
        AiModelSpec(
            id = "gpt-5.5",
            displayName = "GPT-5.5",
            description = "Most capable. Best titles and summaries; higher cost and latency.",
        ),
        AiModelSpec(
            id = "gpt-5-mini",
            displayName = "GPT-5 mini",
            description = "Previous-generation mini. Lower cost.",
        ),
        AiModelSpec(
            id = "gpt-4o-mini",
            displayName = "GPT-4o mini",
            description = "Legacy fallback. Lowest cost.",
        ),
    )

    val default: AiModelSpec = all.first { it.id == DEFAULT_MODEL_ID }

    /** Resolves a stored id to a known spec, falling back to the default for unknown values. */
    fun byId(id: String?): AiModelSpec =
        all.firstOrNull { it.id == id } ?: default
}
