package dev.audiocompanion.ai

import kotlinx.serialization.Serializable

/** Provenance for a fact imported into personal context (M5). */
@Serializable
enum class ContextSourceKind {
    Manual,
    Contacts,
    Calendar,
    Derived,
}

/** One imported or derived fact with provenance (M5). */
@Serializable
data class ContextSource(
    val id: String,
    val kind: ContextSourceKind,
    val label: String,
    val importedAtMs: Long,
)

/** A person the user knows (M5 speaker naming / people memory). */
@Serializable
data class KnownPerson(
    val id: String,
    val name: String,
    val aliases: List<String> = emptyList(),
    val relationship: String? = null,
    val role: String? = null,
    val organization: String? = null,
)

/** Custom vocabulary term for transcription biasing. */
@Serializable
data class VocabTerm(
    val text: String,
    val pronunciationHint: String? = null,
)

/**
 * User-owned background facts that improve transcription accuracy and AI quality.
 * M1 ships paste-only [profileText]; M5 populates people/orgs and import [sources].
 */
@Serializable
data class PersonalContext(
    /** Free-form "About you" text pasted by the user. */
    val profileText: String? = null,
    /** Cached keyword list extracted from [profileText] for OpenAI STT steering. */
    val derivedTerms: List<String> = emptyList(),
    /** Hash of [profileText] when [derivedTerms] was last computed; avoids re-extraction. */
    val derivedTermsSourceHash: String? = null,
    val people: List<KnownPerson> = emptyList(),
    val orgs: List<String> = emptyList(),
    val places: List<String> = emptyList(),
    val topics: List<String> = emptyList(),
    val terms: List<VocabTerm> = emptyList(),
    val sources: List<ContextSource> = emptyList(),
    val biasTranscription: Boolean = true,
    val groundAi: Boolean = true,
) {
    val hasProfileText: Boolean get() = !profileText.isNullOrBlank()

    /** Stable hash for change detection (simple djb2 over trimmed profile text). */
    fun profileTextHash(): String? =
        profileText?.trim()?.takeIf { it.isNotEmpty() }?.let { PersonalContextHash.of(it) }
}

/** Lightweight string hash for cache keys (no crypto dependency). */
internal object PersonalContextHash {
    fun of(text: String): String {
        var hash = 5381L
        for (c in text) {
            hash = ((hash shl 5) + hash) + c.code
        }
        return hash.toULong().toString(16)
    }
}
