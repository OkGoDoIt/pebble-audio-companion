package dev.audiocompanion.app.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AnswerCitationsTest {

    private val sources = listOf(
        "seg-1782360302159-000000fc-1",
        "seg-1782365702732-0000004a-2",
        "seg-1781897412175-00000085-1",
    )

    private fun spans(line: AnswerLine) = line.tokens.filterIsInstance<AnswerToken.Span>().joinToString("") { it.text }
    private fun cites(line: AnswerLine) = line.tokens.filterIsInstance<AnswerToken.Citation>()

    @Test
    fun resolvesTruncatedMarkdownLinkByPrefixAndStripsWrappingPunctuation() {
        val parsed = parseGroundedAnswer(
            "You're considering Brazil ([seg-1782360302159...](#)).",
            sources,
        )
        val line = parsed.lines.single()
        // The wrapping "( ... )." collapses to just the trailing period; the chip hugs the word.
        assertEquals("You're considering Brazil .", spans(line))
        val cite = cites(line).single()
        assertEquals("seg-1782360302159-000000fc-1", cite.segmentId)
        assertEquals(1, cite.number)
    }

    @Test
    fun groupsAdjacentCitationsAndDropsSeparators() {
        val parsed = parseGroundedAnswer(
            "Stepping back ([seg-1782360302159...](#), [seg-1782365702732...](#))",
            sources,
        )
        val line = parsed.lines.single()
        val numbers = cites(line).map { it.number }
        assertEquals(listOf(1, 2), numbers)
        assertEquals(listOf("seg-1782360302159-000000fc-1", "seg-1782365702732-0000004a-2"), cites(line).map { it.segmentId })
        // No stray "(", ")" or "," survives between/around the two chips.
        assertTrue("Stepping back".contains(spans(line).trim()) || spans(line).trim() == "Stepping back")
    }

    @Test
    fun footnoteNumbersMapToSourceOrder() {
        val parsed = parseGroundedAnswer("Atlanta for July 4 [2]. Back to SF [3].", sources)
        val allCites = parsed.lines.flatMap { cites(it) }
        assertEquals("seg-1782365702732-0000004a-2", allCites[0].segmentId)
        assertEquals("seg-1781897412175-00000085-1", allCites[1].segmentId)
    }

    @Test
    fun displayNumbersFollowFirstAppearanceNotSourceIndex() {
        // First cited source is sources[1] -> should display as 1, not 2.
        val parsed = parseGroundedAnswer("Boston Tuesday [2]. Then Atlanta [1].", sources)
        assertEquals(listOf("seg-1782365702732-0000004a-2", "seg-1782360302159-000000fc-1"), parsed.citedSegmentIds)
        val first = parsed.lines.flatMap { cites(it) }.first()
        assertEquals(1, first.number)
        assertEquals("seg-1782365702732-0000004a-2", first.segmentId)
    }

    @Test
    fun sameSegmentCitedTwiceKeepsOneNumber() {
        val parsed = parseGroundedAnswer("Brazil [1]. Also Brazil again [1].", sources)
        assertEquals(listOf("seg-1782360302159-000000fc-1"), parsed.citedSegmentIds)
        assertTrue(parsed.lines.flatMap { cites(it) }.all { it.number == 1 })
    }

    @Test
    fun unresolvableCitationsAreDroppedFromProseInsteadOfShownRaw() {
        val parsed = parseGroundedAnswer("Mystery [seg-9999999999999...](#) claim.", sources)
        val line = parsed.lines.single()
        assertTrue(cites(line).isEmpty())
        // The opaque dangling id is removed; the surrounding sentence stays readable.
        assertEquals("Mystery  claim.", spans(line))
    }

    @Test
    fun realHyperlinksKeepTheirLabelAndDoNotBecomeChips() {
        val parsed = parseGroundedAnswer("See [the docs](https://example.com) for details.", sources)
        val line = parsed.lines.single()
        assertTrue(cites(line).isEmpty())
        assertEquals("See the docs for details.", spans(line))
    }

    @Test
    fun bulletAndNumberMarkersArePreserved() {
        val parsed = parseGroundedAnswer("- First point [1]\n2. Second point", sources)
        assertEquals("•", parsed.lines[0].marker)
        assertEquals("2.", parsed.lines[1].marker)
        assertEquals(1, cites(parsed.lines[0]).single().number)
    }
}
