package dev.audiocompanion.app

import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.search.InMemoryTranscriptIndex
import dev.audiocompanion.search.IndexKind
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TranscriptIndexDonatorTest {
    @Test
    fun donatesAllAiDocumentKindsToSearchAndPlatformHook() = runTest {
        val index = InMemoryTranscriptIndex()
        val platformDonations = mutableListOf<Pair<String, IndexKind>>()
        val donator = TranscriptIndexDonator(
            index = index,
            spotlightDonate = { platformDonations += it.id to it.kind },
        )

        donator.donateSegment(
            segmentId = "seg-1",
            annotation = SegmentAnnotation(
                segmentId = "seg-1",
                title = "Budget review",
                summary = "Discussed Q3 budget.",
                tags = listOf("budget"),
                createdAtMs = 10L,
            ),
        )
        donator.donateDigest(
            DailyDigest(
                dateKey = "2026-06-26",
                text = "Daily recap",
                createdAtMs = 20L,
            ),
        )
        donator.donateActionItem(
            ActionItem(
                id = "action-1",
                text = "Send the budget note",
                sourceSegmentId = "seg-1",
                createdAtMs = 30L,
            ),
        )

        assertEquals(
            listOf(
                "seg-1" to IndexKind.Segment,
                "day-2026-06-26" to IndexKind.DayDigest,
                "action-1" to IndexKind.ActionItem,
            ),
            platformDonations,
        )
        assertEquals("seg-1", index.search("q3").single().id)
        assertEquals("day-2026-06-26", index.search("recap").single().id)
        assertEquals("action-1", index.search("send").single().id)
    }

    @Test
    fun removeAllClearsIndexAndPlatformHook() = runTest {
        val index = InMemoryTranscriptIndex()
        var platformCleared = false
        val donator = TranscriptIndexDonator(
            index = index,
            spotlightRemoveAll = { platformCleared = true },
        )

        donator.donateSegment(
            segmentId = "seg-1",
            annotation = SegmentAnnotation(
                segmentId = "seg-1",
                title = "Private meeting",
                createdAtMs = 10L,
            ),
        )
        donator.removeAll()

        assertTrue(platformCleared)
        assertTrue(index.search("private").isEmpty())
    }
}
