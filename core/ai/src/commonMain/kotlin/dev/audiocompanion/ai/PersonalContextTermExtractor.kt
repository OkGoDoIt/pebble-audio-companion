package dev.audiocompanion.ai

import kotlin.coroutines.cancellation.CancellationException

/**
 * Extracts a bounded keyword list from pasted profile text via [AiModeRouter] for OpenAI STT
 * steering. Prefers on-device (no consent); no-ops cleanly when unavailable.
 */
class PersonalContextTermExtractor(
    private val router: AiModeRouter?,
    private val maxTerms: Int = PersonalContextFormatting.MAX_DERIVED_TERMS,
) {
    private val extractionTemplate = AiPromptTemplate(
        id = "personal-context-terms",
        title = "Extract vocabulary terms",
        systemPrompt = """
            Extract proper nouns, names, product names, jargon, and acronyms from the user's profile text.
            Output ONLY a comma-separated list of terms (no prose, no numbering).
            Include up to $maxTerms terms. Omit generic words.
        """.trimIndent(),
        userPrompt = "Extract terms from this profile text:",
    )

    /**
     * Returns extracted terms, or empty on unavailable provider/consent/cancellation.
     * Never throws into the caller except [CancellationException].
     */
    suspend fun extract(profileText: String): List<String> {
        val trimmed = profileText.trim()
        if (trimmed.isEmpty()) return emptyList()
        val activeRouter = router ?: return emptyList()
        if (!activeRouter.isAvailable()) return emptyList()

        val request = AiRunRequest(
            requestId = "ctx-terms-${trimmed.hashCode()}",
            prompt = extractionTemplate,
            transcripts = listOf(
                TranscriptExcerpt(
                    segmentId = "profile",
                    text = trimmed,
                ),
            ),
        )
        return try {
            val result = activeRouter.run(request)
            parseTerms(result.text)
        } catch (e: CancellationException) {
            throw e
        } catch (_: AiException) {
            emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun parseTerms(raw: String): List<String> =
        raw.split(',', '\n', ';')
            .map { it.trim().trim('"', '\'') }
            .filter { it.isNotBlank() && it.length <= 80 }
            .distinct()
            .take(maxTerms)

    /**
     * Updates [context] with cached [derivedTerms] when [profileText] changes; runs extraction when
     * needed.
     */
    suspend fun refreshDerivedTerms(context: PersonalContext): PersonalContext {
        val hash = context.profileTextHash()
        if (hash == null) {
            return context.copy(derivedTerms = emptyList(), derivedTermsSourceHash = null)
        }
        if (hash == context.derivedTermsSourceHash && context.derivedTerms.isNotEmpty()) {
            return context
        }
        val terms = extract(context.profileText.orEmpty())
        return context.copy(derivedTerms = terms, derivedTermsSourceHash = hash)
    }
}
