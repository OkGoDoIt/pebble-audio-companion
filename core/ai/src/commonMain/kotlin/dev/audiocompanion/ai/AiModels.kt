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
    const val DEFAULT_MODEL_ID = "gpt-5.6-luna"

    val all: List<AiModelSpec> = listOf(
        AiModelSpec(
            id = "gpt-5.6-luna",
            displayName = "GPT-5.6 Luna",
            description = "Fast and inexpensive, with a million-token context for long days of " +
                "transcript. Recommended for automatic titles and summaries.",
            recommended = true,
        ),
        AiModelSpec(
            id = "gpt-5.6-terra",
            displayName = "GPT-5.6 Terra",
            description = "Balances intelligence and cost. Stronger on long, noisy, or " +
                "many-speaker transcripts; roughly ten times Luna's price.",
        ),
        AiModelSpec(
            id = "gpt-5.6-sol",
            displayName = "GPT-5.6 Sol",
            description = "Frontier model for demanding questions across a whole archive. Best " +
                "answers, highest cost.",
        ),
    )

    /**
     * Ids from earlier versions of this catalog, mapped to the closest current model so a stored
     * preference keeps its intent — a budget pick stays budget, a frontier pick stays frontier —
     * instead of collapsing to the default. Resolve through [byId] before sending a stored id as
     * the API `model`, so what we call always matches what Settings shows.
     */
    private val legacyReplacements: Map<String, String> = mapOf(
        "gpt-5.4-nano" to "gpt-5.6-luna",
        "gpt-5.4-mini" to "gpt-5.6-luna",
        "gpt-5.4" to "gpt-5.6-terra",
        "gpt-5.5" to "gpt-5.6-sol",
    )

    val default: AiModelSpec = all.first { it.id == DEFAULT_MODEL_ID }

    fun byId(id: String?): AiModelSpec =
        all.firstOrNull { it.id == id }
            ?: legacyReplacements[id]?.let { replacement -> all.firstOrNull { it.id == replacement } }
            ?: default
}
