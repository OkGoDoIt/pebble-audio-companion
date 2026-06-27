package dev.audiocompanion.search

import kotlinx.serialization.Serializable

/** One searchable document donated to the OS index (segment, digest, or action item). */
@Serializable
data class IndexItem(
    val id: String,
    val kind: IndexKind,
    val title: String,
    val summary: String? = null,
    val tags: List<String> = emptyList(),
    val fullText: String? = null,
    val startDateMs: Long? = null,
    val contentCreationDateMs: Long,
    val excluded: Boolean = false,
)

@Serializable
enum class IndexKind {
    Segment,
    DayDigest,
    ActionItem,
}

@Serializable
data class IndexHit(
    val id: String,
    val kind: IndexKind,
    val title: String,
    val summary: String? = null,
    val score: Float = 0f,
)

/**
 * Platform-backed transcript index (Core Spotlight / AppSearch). No-ops cleanly when unavailable.
 */
interface TranscriptIndex {
  suspend fun index(items: List<IndexItem>)
  suspend fun search(query: String, limit: Int = 20): List<IndexHit>
  suspend fun remove(id: String)
  suspend fun removeAll()
  fun isAvailable(): Boolean
}

/** In-memory fallback for tests and unsupported platforms. */
class InMemoryTranscriptIndex : TranscriptIndex {
    private val docs = mutableMapOf<String, IndexItem>()

    override suspend fun index(items: List<IndexItem>) {
        items.forEach { docs[it.id] = it }
    }

    override suspend fun search(query: String, limit: Int): List<IndexHit> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return emptyList()
        return docs.values
            .filter { !it.excluded }
            .mapNotNull { doc ->
                val haystack = buildString {
                    append(doc.title.lowercase())
                    doc.summary?.let { append(' ').append(it.lowercase()) }
                    doc.tags.forEach { append(' ').append(it.lowercase()) }
                    doc.fullText?.let { append(' ').append(it.lowercase()) }
                }
                if (!haystack.contains(q)) return@mapNotNull null
                IndexHit(
                    id = doc.id,
                    kind = doc.kind,
                    title = doc.title,
                    summary = doc.summary,
                    score = 1f,
                )
            }
            .take(limit)
    }

    override suspend fun remove(id: String) {
        docs.remove(id)
    }

    override suspend fun removeAll() {
        docs.clear()
    }

    override fun isAvailable(): Boolean = true
}

/** No-op index when OS search is unavailable. */
class NoOpTranscriptIndex : TranscriptIndex {
    override suspend fun index(items: List<IndexItem>) = Unit
    override suspend fun search(query: String, limit: Int): List<IndexHit> = emptyList()
    override suspend fun remove(id: String) = Unit
    override suspend fun removeAll() = Unit
    override fun isAvailable(): Boolean = false
}
