package dev.audiocompanion.transcription

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SonioxRealtimeAccumulatorTest {

    @Test
    fun foldsFinalAndPartialTokens() {
        val acc = SonioxRealtimeAccumulator(diarization = false)

        val first = acc.accept(
            listOf(
                SonioxRtToken(text = "Hello ", isFinal = true),
                SonioxRtToken(text = "wor", isFinal = false),
            ),
            finished = false,
        )
        assertEquals("Hello", first.finalText)
        assertEquals("wor", first.partialText)
        assertEquals(false, first.isFinal)

        // Next message finalizes the rest; the previous partial is replaced, not appended twice.
        val second = acc.accept(
            listOf(SonioxRtToken(text = "world", isFinal = true)),
            finished = true,
        )
        assertEquals("Hello world", second.finalText)
        assertEquals("", second.partialText)
        assertTrue(second.isFinal)
    }

    @Test
    fun groupsFinalTokensBySpeakerWhenDiarizing() {
        val acc = SonioxRealtimeAccumulator(diarization = true)

        val update = acc.accept(
            listOf(
                SonioxRtToken("hi ", isFinal = true, speaker = "1", startMs = 0, endMs = 300),
                SonioxRtToken("there ", isFinal = true, speaker = "1", startMs = 300, endMs = 600),
                SonioxRtToken("yes", isFinal = true, speaker = "2", startMs = 800, endMs = 1100),
            ),
            finished = false,
        )

        assertEquals("hi there yes", update.finalText)
        assertEquals(listOf("1", "2"), update.segments.map { it.speaker })
        assertEquals("hi there", update.segments.first().text)
        assertEquals("yes", update.segments.last().text)
    }
}
