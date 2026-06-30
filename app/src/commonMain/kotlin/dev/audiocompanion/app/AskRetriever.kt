package dev.audiocompanion.app

import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.search.TranscriptIndex

/**
 * Retrieves transcript excerpts for Ask Q&A: hybrid keyword (OS index) + direct segment stuffing.
 */
class AskRetriever(
    private val index: TranscriptIndex? = null,
) {
    data class RetrievedChunk(
        val segmentId: String,
        val text: String,
        val startTimeMs: Long? = null,
        val endTimeMs: Long? = null,
        val gapSummary: String? = null,
        val score: Float = 0f,
    )

    suspend fun retrieve(
        query: String,
        excerpts: List<TranscriptExcerpt>,
        gapSummaries: Map<String, String?> = emptyMap(),
        maxChunks: Int = 12,
    ): List<RetrievedChunk> {
        val hits = index?.takeIf { it.isAvailable() }?.search(query, limit = maxChunks).orEmpty()
        val hitIds = hits.map { it.id }.toSet()
        val fromIndex = hits.mapNotNull { hit ->
            excerpts.find { it.segmentId == hit.id }?.let { excerpt ->
                RetrievedChunk(
                    segmentId = excerpt.segmentId,
                    text = excerpt.text,
                    startTimeMs = excerpt.startTimeMs,
                    endTimeMs = excerpt.endTimeMs,
                    gapSummary = gapSummaries[excerpt.segmentId],
                    score = hit.score,
                )
            }
        }
        val remainder = excerpts
            .filter { it.segmentId !in hitIds }
            .take(maxChunks - fromIndex.size)
            .map { excerpt ->
                RetrievedChunk(
                    segmentId = excerpt.segmentId,
                    text = excerpt.text,
                    startTimeMs = excerpt.startTimeMs,
                    endTimeMs = excerpt.endTimeMs,
                    gapSummary = gapSummaries[excerpt.segmentId],
                )
            }
        return (fromIndex + remainder).take(maxChunks)
    }

    /**
     * Render chunks for the prompt. When [citationNumberOf] is supplied, each chunk is prefixed
     * with a stable `[n]` citation number (keyed off the source-segment order, not the relevance
     * order) so the model can cite `[n]` and the app can map those numbers straight back to a real
     * segment id. Without it, the legacy unnumbered format is preserved.
     */
    fun formatForPrompt(
        chunks: List<RetrievedChunk>,
        citationNumberOf: ((String) -> Int?)? = null,
    ): String =
        chunks.joinToString("\n\n") { chunk ->
            val time = when {
                chunk.startTimeMs != null && chunk.endTimeMs != null ->
                    " @${chunk.startTimeMs}-${chunk.endTimeMs}ms"
                chunk.startTimeMs != null -> " @${chunk.startTimeMs}ms"
                else -> ""
            }
            val number = citationNumberOf?.invoke(chunk.segmentId)
            val cite = number?.let { "[$it] " }.orEmpty()
            val gaps = chunk.gapSummary?.let { "\nGAPS: $it" }.orEmpty()
            "$cite[segment ${chunk.segmentId}$time]$gaps\n${chunk.text}"
        }
}
