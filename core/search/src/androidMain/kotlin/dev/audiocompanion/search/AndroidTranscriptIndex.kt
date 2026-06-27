package dev.audiocompanion.search

import android.content.Context
import androidx.appsearch.app.AppSearchSchema
import androidx.appsearch.app.AppSearchSession
import androidx.appsearch.app.GenericDocument
import androidx.appsearch.app.PutDocumentsRequest
import androidx.appsearch.app.RemoveByDocumentIdRequest
import androidx.appsearch.app.SearchResult
import androidx.appsearch.app.SearchResults
import androidx.appsearch.app.SearchSpec
import androidx.appsearch.app.SetSchemaRequest
import androidx.appsearch.localstorage.LocalStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Android AppSearch-backed BM25F index. A small in-memory mirror keeps Ask usable if AppSearch is
 * unavailable or schema setup fails on a device/alpha dependency combination.
 */
class AndroidTranscriptIndex(
    private val context: Context,
    private val fallback: InMemoryTranscriptIndex = InMemoryTranscriptIndex(),
) : TranscriptIndex {
    private val mutex = Mutex()
    private var session: AppSearchSession? = null
    private var unavailable = false

    override fun isAvailable(): Boolean = !unavailable

    override suspend fun index(items: List<IndexItem>) {
        withContext(Dispatchers.IO) {
            fallback.index(items)
            val s = sessionOrNull() ?: return@withContext
            val docs = items.filterNot { it.excluded }.map { it.toDocument() }
            if (docs.isNotEmpty()) {
                s.putAsync(PutDocumentsRequest.Builder().addGenericDocuments(docs).build()).await()
            }
            items.filter { it.excluded }.forEach { removeFromSession(s, it.id) }
        }
    }

    override suspend fun search(query: String, limit: Int): List<IndexHit> =
        withContext(Dispatchers.IO) {
            val s = sessionOrNull() ?: return@withContext fallback.search(query, limit)
            val results = s.search(
                query,
                SearchSpec.Builder()
                    .setResultCountPerPage(limit)
                    .setRankingStrategy(SearchSpec.RANKING_STRATEGY_RELEVANCE_SCORE)
                    .build(),
            )
            runCatching { results.toHits(limit) }
                .getOrElse { fallback.search(query, limit) }
        }

    override suspend fun remove(id: String) {
        withContext(Dispatchers.IO) {
            fallback.remove(id)
            sessionOrNull()?.let { removeFromSession(it, id) }
        }
    }

    override suspend fun removeAll() {
        withContext(Dispatchers.IO) {
            fallback.removeAll()
            sessionOrNull()?.removeAsync("", SearchSpec.Builder().build())?.await()
        }
    }

    private suspend fun sessionOrNull(): AppSearchSession? =
        mutex.withLock {
            if (unavailable) return@withLock null
            session?.let { return@withLock it }
            runCatching {
                LocalStorage.createSearchSessionAsync(
                    LocalStorage.SearchContext.Builder(context, DATABASE_NAME).build(),
                ).await().also { newSession ->
                    newSession.setSchemaAsync(
                        SetSchemaRequest.Builder()
                            .addSchemas(segmentSchema(), digestSchema(), actionSchema())
                            .setForceOverride(true)
                            .build(),
                    ).await()
                    session = newSession
                }
            }.getOrElse {
                unavailable = true
                null
            }
        }

    private suspend fun removeFromSession(session: AppSearchSession, id: String) {
        session.removeAsync(
            RemoveByDocumentIdRequest.Builder(NAMESPACE)
                .addIds(id)
                .build(),
        ).await()
    }

    private suspend fun SearchResults.toHits(limit: Int): List<IndexHit> {
        val hits = mutableListOf<IndexHit>()
        try {
            while (hits.size < limit) {
                val page: List<SearchResult> = getNextPageAsync().await()
                if (page.isEmpty()) break
                page.forEach { result ->
                    val doc = result.getGenericDocument()
                    hits += IndexHit(
                        id = doc.getId(),
                        kind = doc.getSchemaType().toIndexKind(),
                        title = doc.getPropertyString(PROP_TITLE).orEmpty().ifBlank { doc.getId() },
                        summary = doc.getPropertyString(PROP_SUMMARY),
                        score = result.getRankingSignal().toFloat(),
                    )
                }
            }
        } finally {
            close()
        }
        return hits.take(limit)
    }

    private fun IndexItem.toDocument(): GenericDocument {
        val schema = when (kind) {
            IndexKind.Segment -> SCHEMA_SEGMENT
            IndexKind.DayDigest -> SCHEMA_DAY_DIGEST
            IndexKind.ActionItem -> SCHEMA_ACTION_ITEM
        }
        return GenericDocument.Builder<GenericDocument.Builder<*>>(NAMESPACE, id, schema)
            .setCreationTimestampMillis(contentCreationDateMs)
            .setPropertyString(PROP_TITLE, title)
            .setPropertyString(PROP_SUMMARY, summary.orEmpty())
            .setPropertyString(PROP_TAGS, *tags.toTypedArray())
            .setPropertyString(PROP_FULL_TEXT, fullText.orEmpty())
            .setPropertyLong(PROP_START_DATE_MS, startDateMs ?: 0L)
            .build()
    }

    private fun String.toIndexKind(): IndexKind =
        when (this) {
            SCHEMA_DAY_DIGEST -> IndexKind.DayDigest
            SCHEMA_ACTION_ITEM -> IndexKind.ActionItem
            else -> IndexKind.Segment
        }

    companion object {
        private const val DATABASE_NAME = "audio-companion-transcript-index"
        private const val NAMESPACE = "default"
        private const val SCHEMA_SEGMENT = "SegmentDoc"
        private const val SCHEMA_DAY_DIGEST = "DayDigestDoc"
        private const val SCHEMA_ACTION_ITEM = "ActionItemDoc"
        private const val PROP_TITLE = "title"
        private const val PROP_SUMMARY = "summary"
        private const val PROP_TAGS = "tags"
        private const val PROP_FULL_TEXT = "fullText"
        private const val PROP_START_DATE_MS = "startDateMs"

        private fun segmentSchema(): AppSearchSchema = schema(SCHEMA_SEGMENT)
        private fun digestSchema(): AppSearchSchema = schema(SCHEMA_DAY_DIGEST)
        private fun actionSchema(): AppSearchSchema = schema(SCHEMA_ACTION_ITEM)

        private fun schema(type: String): AppSearchSchema =
            AppSearchSchema.Builder(type)
                .addProperty(indexedString(PROP_TITLE))
                .addProperty(indexedString(PROP_SUMMARY))
                .addProperty(indexedString(PROP_TAGS))
                .addProperty(indexedString(PROP_FULL_TEXT))
                .addProperty(
                    AppSearchSchema.LongPropertyConfig.Builder(PROP_START_DATE_MS)
                        .setCardinality(AppSearchSchema.PropertyConfig.CARDINALITY_OPTIONAL)
                        .build(),
                )
                .build()

        private fun indexedString(name: String): AppSearchSchema.StringPropertyConfig =
            AppSearchSchema.StringPropertyConfig.Builder(name)
                .setCardinality(AppSearchSchema.PropertyConfig.CARDINALITY_OPTIONAL)
                .setTokenizerType(AppSearchSchema.StringPropertyConfig.TOKENIZER_TYPE_PLAIN)
                .setIndexingType(AppSearchSchema.StringPropertyConfig.INDEXING_TYPE_PREFIXES)
                .build()
    }
}

fun createAndroidTranscriptIndex(context: Context): TranscriptIndex =
    AndroidTranscriptIndex(context)
