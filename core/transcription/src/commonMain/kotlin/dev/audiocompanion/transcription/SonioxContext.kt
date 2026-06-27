package dev.audiocompanion.transcription

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/** Soniox transcription `context` object (real-time config + async REST body). */
@Serializable
data class SonioxContext(
    val text: String? = null,
    val terms: List<String>? = null,
)

/** Builds Soniox `context` JSON for WebSocket config when text or terms are present. */
internal fun buildSonioxContextJsonObject(
    contextText: String?,
    contextTerms: List<String>,
): JsonObject? {
    val text = contextText?.trim()?.takeIf { it.isNotEmpty() }
    val terms = contextTerms.filter { it.isNotBlank() }.distinct()
    if (text == null && terms.isEmpty()) return null
    return buildJsonObject {
        text?.let { put("text", it) }
        if (terms.isNotEmpty()) {
            putJsonArray("terms") { terms.forEach { add(JsonPrimitive(it)) } }
        }
    }
}

/** Maps lambdas into a [SonioxContext] for async REST requests. */
internal fun sonioxContextFrom(
    contextText: () -> String?,
    contextTerms: () -> List<String>,
): SonioxContext? {
    val text = contextText()?.trim()?.takeIf { it.isNotEmpty() }
    val terms = contextTerms().filter { it.isNotBlank() }.distinct()
    if (text == null && terms.isEmpty()) return null
    return SonioxContext(
        text = text,
        terms = terms.takeIf { it.isNotEmpty() },
    )
}
