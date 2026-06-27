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

    fun formatForPrompt(chunks: List<RetrievedChunk>): String =
        chunks.joinToString("\n\n") { chunk ->
            val time = when {
                chunk.startTimeMs != null && chunk.endTimeMs != null ->
                    " @${chunk.startTimeMs}-${chunk.endTimeMs}ms"
                chunk.startTimeMs != null -> " @${chunk.startTimeMs}ms"
                else -> ""
            }
            val gaps = chunk.gapSummary?.let { "\nGAPS: $it" }.orEmpty()
            "[segment ${chunk.segmentId}$time]$gaps\n${chunk.text}"
        }
}
