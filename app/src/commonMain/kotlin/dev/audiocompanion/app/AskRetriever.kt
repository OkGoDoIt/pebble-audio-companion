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
        val score: Float = 0f,
    )

    suspend fun retrieve(
        query: String,
        excerpts: List<TranscriptExcerpt>,
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
                )
            }
        return (fromIndex + remainder).take(maxChunks)
    }

    fun formatForPrompt(chunks: List<RetrievedChunk>): String =
        chunks.joinToString("\n\n") { chunk ->
            val time = chunk.startTimeMs?.let { " @${it}ms" } ?: ""
            "[segment ${chunk.segmentId}$time]\n${chunk.text}"
        }
}
