package dev.audiocompanion.app.ui

import dev.audiocompanion.storage.GapMeta
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
    fun transcriptTimelineItemsUseUnlabeledBreaksBeforeQuietMarkers() {
        val items = transcriptTimelineItems(
            meta = testMeta(),
            segments = listOf(
                TranscriptSegment("first thought", startMs = 0, endMs = 1_000),
                TranscriptSegment("same paragraph", startMs = 4_000, endMs = 5_000),
                TranscriptSegment("new paragraph", startMs = 11_000, endMs = 12_000),
                TranscriptSegment("long pause", startMs = 43_000, endMs = 44_000),
            ),
        )

        assertEquals(5, items.size)
        val first = items[0] as TranscriptTimelineItem.Speech
        assertEquals("first thought same paragraph", first.text)
        val breakItem = items[1] as TranscriptTimelineItem.Break
        assertEquals(5_000, breakItem.startMs)
        assertEquals(6_000, breakItem.durationMs)
        assertTrue(items[2] is TranscriptTimelineItem.Speech)
        val pause = items[3] as TranscriptTimelineItem.Pause
        assertEquals(12_000, pause.startMs)
        assertEquals(31_000, pause.durationMs)
        assertEquals(false, pause.missing)
        assertTrue(items[4] is TranscriptTimelineItem.Speech)
    }

    @Test
    fun transcriptTimelineItemsDoNotRenderStoredGapsAsRows() {
        val items = transcriptTimelineItems(
            meta = testMeta(
                gaps = List(4) { index ->
                    GapMeta(
                        firstMissingSequence = index.toUInt(),
                        missingFrameCount = 81_000u,
                        firstMissingSampleIndex = (index * 16_000).toULong(),
                        origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
                    )
                },
            ),
            segments = listOf(
                TranscriptSegment("oh what's going on here", startMs = 2_000, endMs = 4_000),
            ),
        )

        assertEquals(1, items.size)
        assertTrue(items.single() is TranscriptTimelineItem.Speech)
    }

    private fun testMeta(gaps: List<GapMeta> = emptyList()) = SegmentMeta(
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
        lastSampleIndexExclusive = 160_000UL,
        frameCount = 500,
        gaps = gaps,
    )
}
