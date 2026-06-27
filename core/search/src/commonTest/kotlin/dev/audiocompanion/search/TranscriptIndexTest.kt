package dev.audiocompanion.search

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TranscriptIndexTest {
    @Test
    fun inMemorySearchMatchesTitleAndTags() = runTest {
        val index = InMemoryTranscriptIndex()
        index.index(
            listOf(
                IndexItem(
                    id = "seg-1",
                    kind = IndexKind.Segment,
                    title = "Budget review",
                    summary = "Discussed Q3 numbers",
                    tags = listOf("work", "budget"),
                    contentCreationDateMs = 1L,
                ),
            ),
        )
        val hits = index.search("budget", limit = 5)
        assertEquals(1, hits.size)
        assertEquals("seg-1", hits.first().id)
    }

    @Test
    fun excludedItemsAreNotReturned() = runTest {
        val index = InMemoryTranscriptIndex()
        index.index(
            listOf(
                IndexItem(
                    id = "hidden",
                    kind = IndexKind.Segment,
                    title = "Secret meeting",
                    contentCreationDateMs = 1L,
                    excluded = true,
                ),
            ),
        )
        assertTrue(index.search("secret", limit = 5).isEmpty())
    }
}
