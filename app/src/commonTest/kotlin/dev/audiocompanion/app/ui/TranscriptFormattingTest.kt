package dev.audiocompanion.app.ui

import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptSegment
import dev.audiocompanion.transcription.TranscriptionMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TranscriptFormattingTest {
    @Test
    fun speakerLabelFormatsNumericAndNamedSpeakers() {
        assertEquals("Speaker 1", speakerLabel("1"))
        assertEquals("Speaker 12", speakerLabel("12"))
        assertEquals("Agent", speakerLabel("agent"))
        assertEquals("Customer", speakerLabel("Customer"))
    }

    @Test
    fun speakerColorIndexKeepsNumericSpeakersStableAndDistinct() {
        assertEquals(0, speakerColorIndex("Speaker 1"))
        assertEquals(1, speakerColorIndex("Speaker 2"))
        assertEquals(speakerColorIndex("Speaker 1"), speakerColorIndex("Speaker 7"))
    }

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
    fun transcriptTimelineItemsCollapseStoredGapsIntoInlineRows() {
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

        assertEquals(2, items.size)
        val gap = items[0] as TranscriptTimelineItem.Pause
        assertEquals(true, gap.missing)
        assertEquals("audio interrupted for 10 sec (phone briefly missed audio)", gap.label)
        assertTrue(items[1] is TranscriptTimelineItem.Speech)
    }

    @Test
    fun transcriptTimelineItemsShowSeveralReasonsWhenLossReasonsCollapseTogether() {
        val items = transcriptTimelineItems(
            meta = testMeta(
                gaps = listOf(
                    GapMeta(
                        firstMissingSequence = 0u,
                        missingFrameCount = 100u,
                        firstMissingSampleIndex = 0uL,
                        origin = GapMeta.ORIGIN_WATCH,
                        reasonRaw = GapReason.MicConflict.raw,
                    ),
                    GapMeta(
                        firstMissingSequence = 100u,
                        missingFrameCount = 100u,
                        firstMissingSampleIndex = 32_000uL,
                        origin = GapMeta.ORIGIN_WATCH,
                        reasonRaw = GapReason.TransportReset.raw,
                    ),
                ),
            ),
            segments = listOf(
                TranscriptSegment("back after interruptions", startMs = 6_000, endMs = 8_000),
            ),
        )

        val pause = items.first() as TranscriptTimelineItem.Pause
        assertEquals(true, pause.missing)
        assertEquals("audio interrupted for 4 sec (several reasons)", pause.label)
    }

    @Test
    fun transcriptTimelineItemsHideShortSuppressedSilence() {
        // A skipped-silence span under 30 s earns no label (same rule as natural quiet pauses).
        val items = transcriptTimelineItems(
            meta = testMeta(
                gaps = listOf(
                    GapMeta(
                        firstMissingSequence = 0u,
                        missingFrameCount = 500u, // 10 s at 20 ms/frame
                        firstMissingSampleIndex = 0uL,
                        origin = GapMeta.ORIGIN_WATCH,
                        reasonRaw = GapReason.SilenceSuppressed.raw,
                    ),
                ),
            ),
            segments = listOf(
                TranscriptSegment("back after a short quiet stretch", startMs = 2_000, endMs = 4_000),
            ),
        )

        assertTrue(items.filterIsInstance<TranscriptTimelineItem.Pause>().isEmpty())
        assertTrue(items.any { it is TranscriptTimelineItem.Speech })
    }

    @Test
    fun transcriptTimelineItemsCollapseConsecutiveQuietSpans() {
        // Three separate skipped-silence spans with no transcribed speech between them collapse
        // into one quiet period of their combined length, not three "quiet for…" rows.
        fun silence(sampleIndex: ULong, seq: UInt) = GapMeta(
            firstMissingSequence = seq,
            missingFrameCount = 1_500u, // 30 s at 20 ms/frame
            firstMissingSampleIndex = sampleIndex,
            origin = GapMeta.ORIGIN_WATCH,
            reasonRaw = GapReason.SilenceSuppressed.raw,
        )
        val items = transcriptTimelineItems(
            // 200 s segment with quiet spans at ~0 s, ~50 s, ~100 s (too far apart to merge as gaps).
            meta = testMeta(
                gaps = listOf(
                    silence(0uL, 0u),
                    silence(800_000uL, 100u),
                    silence(1_600_000uL, 200u),
                ),
            ).copy(lastSampleIndexExclusive = 3_200_000uL),
            segments = listOf(
                TranscriptSegment("after a long quiet block", startMs = 150_000, endMs = 152_000),
            ),
        )

        val pauses = items.filterIsInstance<TranscriptTimelineItem.Pause>()
        assertEquals(1, pauses.size)
        assertEquals(false, pauses.single().missing)
        assertTrue(pauses.single().durationMs >= 85_000, "combined ~90 s: ${pauses.single().durationMs}")
    }

    @Test
    fun transcriptTimelineItemsLabelLongSuppressedSilenceAsQuiet() {
        // 30 s or longer reads as a calm "quiet for…" pause, never "audio interrupted…".
        val items = transcriptTimelineItems(
            // 60 s segment so the 40 s skipped-silence span is not clamped below the 30 s cutoff.
            meta = testMeta(
                gaps = listOf(
                    GapMeta(
                        firstMissingSequence = 0u,
                        missingFrameCount = 2_000u, // 40 s at 20 ms/frame
                        firstMissingSampleIndex = 0uL,
                        origin = GapMeta.ORIGIN_WATCH,
                        reasonRaw = GapReason.SilenceSuppressed.raw,
                    ),
                ),
            ).copy(lastSampleIndexExclusive = 960_000uL),
            segments = listOf(
                TranscriptSegment("back after a long quiet stretch", startMs = 45_000, endMs = 47_000),
            ),
        )

        val pause = items.filterIsInstance<TranscriptTimelineItem.Pause>().single()
        assertEquals(false, pause.missing)
        assertTrue(pause.label.startsWith("quiet for"), pause.label)
    }

    @Test
    fun transcriptTimelineItemsSplitLongFinalSegmentsIntoReadableBlocks() {
        val longText = (1..90).joinToString(" ") { "word$it" }
        val items = transcriptTimelineItems(
            meta = testMeta(),
            segments = listOf(
                TranscriptSegment(longText, startMs = 0, endMs = 90_000),
            ),
        )

        val speech = items.filterIsInstance<TranscriptTimelineItem.Speech>()
        assertTrue(speech.size >= 3)
        assertTrue(speech.all { it.text.split(Regex("\\s+")).size <= 34 })
        assertEquals(0, speech.first().startMs)
        assertEquals(90_000, speech.last().endMs)
    }

    @Test
    fun librarySearchMatchReturnsTimedTranscriptSnippet() {
        val transcript = testTranscript(
            text = "They discussed lunch, then Austin apartment hunting near transit.",
            segments = listOf(
                TranscriptSegment("They discussed lunch", startMs = 0, endMs = 2_000),
                TranscriptSegment("Austin apartment hunting near transit", startMs = 42_000, endMs = 47_000),
            ),
        )

        val match = librarySearchMatch(
            query = "Austin",
            meta = testMeta(),
            transcript = transcript,
            annotation = null,
            actionItems = emptyList(),
            aiOutputs = emptyList(),
        ) ?: throw AssertionError("expected transcript search match")

        assertEquals(LibrarySearchMatchKind.Transcript, match.kind)
        assertEquals(42_000, match.startMs)
        assertTrue(match.label.startsWith("Transcript match"))
        assertTrue(match.snippet.contains("Austin"))
    }

    @Test
    fun librarySearchMatchFallsBackToPlainTranscriptSnippetWithoutTimings() {
        val transcript = testTranscript(
            text = "Before the errand they talked about groceries. Later Austin called back.",
        )

        val match = librarySearchMatch(
            query = "Austin",
            meta = testMeta(),
            transcript = transcript,
            annotation = null,
            actionItems = emptyList(),
            aiOutputs = emptyList(),
        ) ?: throw AssertionError("expected plain transcript search match")

        assertEquals(LibrarySearchMatchKind.Transcript, match.kind)
        assertEquals(null, match.startMs)
        assertTrue(match.snippet.contains("Austin"))
    }

    @Test
    fun librarySearchMatchSupportsOutOfOrderMultiTermTranscriptQueries() {
        val transcript = testTranscript(
            text = "They discussed lunch, then Austin apartment hunting near transit.",
            segments = listOf(
                TranscriptSegment("They discussed lunch", startMs = 0, endMs = 2_000),
                TranscriptSegment("Austin apartment hunting near transit", startMs = 42_000, endMs = 47_000),
            ),
        )

        val match = librarySearchMatch(
            query = "transit Austin",
            meta = testMeta(),
            transcript = transcript,
            annotation = null,
            actionItems = emptyList(),
            aiOutputs = emptyList(),
        ) ?: throw AssertionError("expected multi-term transcript search match")

        assertEquals(LibrarySearchMatchKind.Transcript, match.kind)
        assertEquals(42_000, match.startMs)
        assertTrue(match.snippet.contains("Austin"))
        assertTrue(match.snippet.contains("transit"))
    }

    @Test
    fun librarySearchMatchSupportsFuzzyTranscriptTerms() {
        val transcript = testTranscript(
            text = "They discussed lunch, then Austin apartment hunting near transit.",
            segments = listOf(
                TranscriptSegment("They discussed lunch", startMs = 0, endMs = 2_000),
                TranscriptSegment("Austin apartment hunting near transit", startMs = 42_000, endMs = 47_000),
            ),
        )

        val match = librarySearchMatch(
            query = "Austn",
            meta = testMeta(),
            transcript = transcript,
            annotation = null,
            actionItems = emptyList(),
            aiOutputs = emptyList(),
        ) ?: throw AssertionError("expected fuzzy transcript search match")

        assertEquals(LibrarySearchMatchKind.Transcript, match.kind)
        assertEquals(42_000, match.startMs)
        assertEquals("Austin", match.highlightTerm)
        assertTrue(match.snippet.contains("Austin"))
    }

    @Test
    fun librarySearchMatchPrefersTranscriptContextWhenTitleAlsoMatches() {
        val transcript = testTranscript(
            text = "They discussed lunch, then Austin apartment hunting near transit.",
            segments = listOf(
                TranscriptSegment("They discussed lunch", startMs = 0, endMs = 2_000),
                TranscriptSegment("Austin apartment hunting near transit", startMs = 42_000, endMs = 47_000),
            ),
        )

        val match = librarySearchMatch(
            query = "Austin",
            meta = testMeta(),
            transcript = transcript,
            annotation = SegmentAnnotation(
                segmentId = "seg",
                title = "Austin plans",
                createdAtMs = 0,
            ),
            actionItems = emptyList(),
            aiOutputs = emptyList(),
        ) ?: throw AssertionError("expected transcript search match")

        assertEquals(LibrarySearchMatchKind.Transcript, match.kind)
        assertEquals(42_000, match.startMs)
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

    private fun testTranscript(
        text: String,
        segments: List<TranscriptSegment> = emptyList(),
    ) = SegmentTranscript(
        segmentId = "seg",
        text = text,
        modeUsed = TranscriptionMode.LocalOnly,
        providerId = "test",
        modelUsed = null,
        createdAtMs = 0,
        segments = segments,
    )
}
