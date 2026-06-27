package dev.audiocompanion.app

import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.search.IndexItem
import dev.audiocompanion.search.IndexKind
import dev.audiocompanion.search.TranscriptIndex

/**
 * Maps enriched app content into index documents and donates them to the OS search backend.
 * Called after segment enrichment and daily digest writes — never from BLE callbacks.
 */
class TranscriptIndexDonator(
    private val index: TranscriptIndex,
    private val includeFullTranscript: () -> Boolean = { false },
    /** Platform Spotlight donation (iOS Swift bridge); no-op on Android. */
    private val spotlightDonate: (IndexItem) -> Unit = {},
) {
    suspend fun donateSegment(
        segmentId: String,
        annotation: SegmentAnnotation,
        fullTranscript: String? = null,
        startDateMs: Long? = null,
        excluded: Boolean = false,
    ) {
        if (!index.isAvailable()) return
        val full = if (includeFullTranscript()) fullTranscript else null
        val item = IndexItem(
            id = segmentId,
            kind = IndexKind.Segment,
            title = annotation.title ?: segmentId,
            summary = annotation.summary,
            tags = annotation.tags,
            fullText = full,
            startDateMs = startDateMs,
            contentCreationDateMs = annotation.createdAtMs,
            excluded = excluded,
        )
        index.index(listOf(item))
        spotlightDonate(item)
    }

    suspend fun donateDigest(digest: DailyDigest, excluded: Boolean = false) {
        if (!index.isAvailable()) return
        index.index(
            listOf(
                IndexItem(
                    id = "day-${digest.dateKey}",
                    kind = IndexKind.DayDigest,
                    title = digest.dateKey,
                    summary = digest.text.take(500),
                    fullText = digest.text,
                    contentCreationDateMs = digest.createdAtMs,
                    excluded = excluded,
                ),
            ),
        )
    }

    suspend fun donateActionItem(item: ActionItem, excluded: Boolean = false) {
        if (!index.isAvailable()) return
        index.index(
            listOf(
                IndexItem(
                    id = item.id,
                    kind = IndexKind.ActionItem,
                    title = item.text,
                    summary = null,
                    contentCreationDateMs = item.createdAtMs,
                    excluded = excluded,
                ),
            ),
        )
    }

    suspend fun remove(id: String) {
        if (!index.isAvailable()) return
        index.remove(id)
    }
}
