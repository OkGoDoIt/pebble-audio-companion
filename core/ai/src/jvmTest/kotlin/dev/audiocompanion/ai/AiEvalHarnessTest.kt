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

    @Test
    fun actionItemParserCleansMarkdownAndSkipsPreamble() {
        val items = ActionItemParser.parse(
            raw = """
                Here are the action items I found:

                - [ ] **Improve transcription UI formatting** — **Owner:** Roger/team
                  - Show transcribed segments in **blue**.
                2. **Research timestamp support** - **Owner:** Roger
            """.trimIndent(),
            sourceSegmentId = "seg-178",
            nowMs = 1000L,
        )

        assertEquals(3, items.size)
        assertEquals("Improve transcription UI formatting. Owner: Roger/team", items[0].text)
        assertEquals("Show transcribed segments in blue.", items[1].text)
        assertEquals("Research timestamp support. Owner: Roger", items[2].text)
    }

    @Test
    fun actionItemParserPrefersStructuredJson() {
        val items = ActionItemParser.parse(
            raw = """
                {
                  "items": [
                    {
                      "task": "Ship the display fix",
                      "owner": "Roger/team",
                      "due": "Friday",
                      "sourceSegmentId": "seg-2"
                    }
                  ]
                }
            """.trimIndent(),
            sourceSegmentId = "seg-1",
            nowMs = 1000L,
        )

        assertEquals(1, items.size)
        assertEquals("Ship the display fix. Owner: Roger/team. Due: Friday", items.single().text)
        assertEquals("seg-2", items.single().sourceSegmentId)
        assertEquals("- [ ] Ship the display fix. Owner: Roger/team. Due: Friday", ActionItemParser.displayText(items))
    }

    @Test
    fun actionItemParserAcceptsEmptyStructuredJson() {
        val items = ActionItemParser.parse(
            raw = """{"items": []}""",
            sourceSegmentId = "seg-1",
            nowMs = 1000L,
        )

        assertEquals(emptyList(), items)
        assertEquals("No action items found.", ActionItemParser.displayText(items))
    }

    @Test
    fun actionItemParserReturnsEmptyForNoActionItems() {
        assertEquals(
            emptyList(),
            ActionItemParser.parse("No action items found.", "seg-1", 1000L),
        )
    }
}
