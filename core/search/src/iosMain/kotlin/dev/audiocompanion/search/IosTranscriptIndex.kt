package dev.audiocompanion.search

/**
 * iOS transcript index: in-memory search for Ask retrieval. Core Spotlight donation is handled by
 * the Swift shell (`SpotlightDonationBridge`) when native indexing is available.
 */
class IosTranscriptIndex : TranscriptIndex {
    private val fallback = InMemoryTranscriptIndex()

    override suspend fun index(items: List<IndexItem>) = fallback.index(items)
    override suspend fun search(query: String, limit: Int): List<IndexHit> =
        fallback.search(query, limit)

    override suspend fun remove(id: String) = fallback.remove(id)
    override suspend fun removeAll() = fallback.removeAll()
    override fun isAvailable(): Boolean = true
}

fun createIosTranscriptIndex(): TranscriptIndex = IosTranscriptIndex()
