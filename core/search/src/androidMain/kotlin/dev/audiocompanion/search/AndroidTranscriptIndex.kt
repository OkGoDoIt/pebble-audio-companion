package dev.audiocompanion.search

import android.content.Context
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Android AppSearch-backed index when the platform storage APIs are available; otherwise no-op.
 * Uses a lightweight in-memory mirror for search until full AppSearch schema wiring is complete.
 */
class AndroidTranscriptIndex(
    private val context: Context,
    private val fallback: InMemoryTranscriptIndex = InMemoryTranscriptIndex(),
) : TranscriptIndex {
    private val available = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    override fun isAvailable(): Boolean = available

    override suspend fun index(items: List<IndexItem>) {
        if (!available) return
        withContext(Dispatchers.IO) {
            fallback.index(items)
        }
    }

    override suspend fun search(query: String, limit: Int): List<IndexHit> =
        fallback.search(query, limit)

    override suspend fun remove(id: String) {
        withContext(Dispatchers.IO) {
            fallback.remove(id)
        }
    }

    override suspend fun removeAll() {
        withContext(Dispatchers.IO) {
            fallback.removeAll()
        }
    }
}

fun createAndroidTranscriptIndex(context: Context): TranscriptIndex =
    AndroidTranscriptIndex(context)
