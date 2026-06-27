package dev.audiocompanion.ai

/**
 * Budgeted formatting of [PersonalContext] for injection into transcription and AI pipelines.
 * Keeps slices small for on-device context windows and OpenAI realtime prompt limits.
 */
object PersonalContextFormatting {
    /** Soniox `context.text` budget (~10k chars per Soniox docs). */
    const val SONIOX_TEXT_BUDGET_CHARS = 10_000

    /** OpenAI file STT prompt: short keyword list only. */
    const val OPENAI_STT_PROMPT_MAX_CHARS = 800

    /** On-device / chat grounding block budget. */
    const val AI_GROUNDING_BUDGET_CHARS = 2_000

    /** Max terms in an extracted keyword list. */
    const val MAX_DERIVED_TERMS = 40

    fun transcriptionText(context: PersonalContext, budgetChars: Int = SONIOX_TEXT_BUDGET_CHARS): String? {
        if (!context.biasTranscription) return null
        val raw = context.profileText?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return clamp(raw, budgetChars)
    }

    fun transcriptionTerms(context: PersonalContext, maxTerms: Int = MAX_DERIVED_TERMS): List<String> {
        if (!context.biasTranscription) return emptyList()
        return context.derivedTerms.take(maxTerms).filter { it.isNotBlank() }
    }

    fun openAiSttPrompt(context: PersonalContext): String? {
        val terms = transcriptionTerms(context)
        if (terms.isEmpty()) return null
        val joined = terms.joinToString(", ")
        return clamp(joined, OPENAI_STT_PROMPT_MAX_CHARS)
    }

    fun aiGroundingBlock(context: PersonalContext, budgetChars: Int = AI_GROUNDING_BUDGET_CHARS): String? {
        if (!context.groundAi) return null
        val raw = context.profileText?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val block = buildString {
            appendLine("About the user / known context:")
            append(clamp(raw, budgetChars - 40))
        }.trim()
        return block.takeIf { it.length > 20 }
    }

    private fun clamp(text: String, maxChars: Int): String =
        if (text.length <= maxChars) text else text.take(maxChars - 3) + "..."
}
