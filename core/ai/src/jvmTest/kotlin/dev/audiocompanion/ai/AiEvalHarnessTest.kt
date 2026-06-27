package dev.audiocompanion.ai

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Eval harness (2C): fixture parsing regressions for AI annotation and action-item outputs. */
class AiEvalHarnessTest {
    @Test
    fun segmentAnnotationParsesTagsLine() {
        val parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Budget review\nSUMMARY: Discussed Q3.\nTAGS: work, budget",
        )
        assertEquals("Budget review", parsed.title)
        assertEquals(listOf("work", "budget"), parsed.tags)
    }

    @Test
    fun actionItemParserExtractsChecklistLines() {
        val items = ActionItemParser.parse(
            raw = "- Follow up with Sarah\n* Send deck\n[ ] Book room",
            sourceSegmentId = "seg-1",
            nowMs = 1000L,
        )
        assertEquals(3, items.size)
        assertTrue(items.all { it.sourceSegmentId == "seg-1" })
        assertEquals("Follow up with Sarah", items[0].text)
    }
}
