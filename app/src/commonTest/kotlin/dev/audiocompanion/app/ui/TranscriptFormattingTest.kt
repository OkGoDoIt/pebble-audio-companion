package dev.audiocompanion.app.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TranscriptFormattingTest {
    @Test
    fun transcriptParagraphsSplitsOnReadableSentenceBoundaries() {
        val text = "First sentence. Second sentence! third fragment continues. 42 starts here?"

        val paragraphs = transcriptParagraphs(text, maxChars = 26)

        assertEquals(
            listOf(
                "First sentence.",
                "Second sentence! third fragment continues.",
                "42 starts here?",
            ),
            paragraphs,
        )
    }

    @Test
    fun transcriptParagraphsKeepsExplicitBlankLineBreaks() {
        val text = "Before a quiet stretch.\n\nAfter the quiet stretch."

        val paragraphs = transcriptParagraphs(text)

        assertEquals(listOf("Before a quiet stretch.", "After the quiet stretch."), paragraphs)
    }

    @Test
    fun transcriptParagraphsReturnsEmptyForBlankText() {
        assertTrue(transcriptParagraphs(" \n\t ").isEmpty())
    }
}
