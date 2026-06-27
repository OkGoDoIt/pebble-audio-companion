package dev.audiocompanion.app

import kotlin.test.Test
import kotlin.test.assertContains

class AskRetrieverTest {
    @Test
    fun formatForPromptIncludesSegmentTimesAndGaps() {
        val prompt = AskRetriever().formatForPrompt(
            listOf(
                AskRetriever.RetrievedChunk(
                    segmentId = "seg-1",
                    text = "We decided to move the launch.",
                    startTimeMs = 1_000L,
                    endTimeMs = 9_000L,
                    gapSummary = "1 gap, about 2000ms missing; answer may be incomplete.",
                ),
            ),
        )

        assertContains(prompt, "[segment seg-1 @1000-9000ms]")
        assertContains(prompt, "GAPS: 1 gap")
        assertContains(prompt, "We decided to move the launch.")
    }
}
