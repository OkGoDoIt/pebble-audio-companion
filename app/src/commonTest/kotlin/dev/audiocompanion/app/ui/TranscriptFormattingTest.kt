package dev.audiocompanion.app.ui

import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.TranscriptSegment
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TranscriptFormattingTest {
    @Test
    fun transcriptParagraphsSplitsOnReadableSentenceBoundaries() {
        val text = "First sentence. Second sentence! third fragment continues. 42 starts here?"

        val paragraphs = transcriptParagraphs(text, maxChars = 42)

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
    fun transcriptParagraphsSplitsPunctuationFreeLiveTextByWords() {
        val text = "testing one two three testing one two three testing one two three " +
            "where did you go austin austin where are you little guy hey austin where " +
            "are you what is that in your hand what do you got can i see"

        val paragraphs = transcriptParagraphs(text, maxChars = 90, maxWords = 12)

        assertTrue(paragraphs.size > 3)
        assertTrue(paragraphs.all { it.split(Regex("\\s+")).size <= 12 })
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

    @Test
    fun transcriptTimelineItemsInsertPauseMarkersFromTimingGaps() {
        val items = transcriptTimelineItems(
            meta = testMeta(),
            segments = listOf(
                TranscriptSegment("first thought", startMs = 0, endMs = 1_000),
                TranscriptSegment("after a pause", startMs = 5_000, endMs = 6_000),
            ),
        )

        assertEquals(3, items.size)
        assertTrue(items[0] is TranscriptTimelineItem.Speech)
        val pause = items[1] as TranscriptTimelineItem.Pause
        assertEquals(1_000, pause.startMs)
        assertEquals(4_000, pause.durationMs)
        assertEquals(false, pause.missing)
        assertTrue(items[2] is TranscriptTimelineItem.Speech)
    }

    private fun testMeta() = SegmentMeta(
        segmentId = "seg",
        streamId = 1u,
        protocolVersion = 1,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16_000u,
        bitRateBps = 16_000u,
        frameDurationMs = 20,
        startTimeMs = 0UL,
        startMonotonicMs = 0UL,
        receivedAtMs = 0,
        firstSampleIndex = 0UL,
    )
}
