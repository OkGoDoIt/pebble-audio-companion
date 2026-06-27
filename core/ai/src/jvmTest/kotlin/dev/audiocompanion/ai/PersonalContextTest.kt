package dev.audiocompanion.ai

import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.files.SystemTemporaryDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PersonalContextStoreTest {
    private val root = Path(SystemTemporaryDirectory, "pc-store-test-${System.nanoTime()}")

  @Test
    fun roundTripAndClear() {
        val store = FilePersonalContextStore(SystemFileSystem, root)
        val saved = store.save(
            PersonalContext(
                profileText = "I work at Pebble. Sarah is my manager.",
                derivedTerms = listOf("Pebble", "Sarah"),
                derivedTermsSourceHash = "abc",
            ),
        )
        assertEquals("I work at Pebble. Sarah is my manager.", saved.profileText)
        val loaded = store.load()
        assertEquals(saved, loaded)
        store.clear()
        assertEquals(PersonalContext(), store.load())
    }
}

class PersonalContextFormattingTest {
    @Test
    fun clampsLongProfileForSonioxAndGrounding() {
        val long = "word ".repeat(5_000)
        val ctx = PersonalContext(profileText = long, biasTranscription = true, groundAi = true)
        val text = PersonalContextFormatting.transcriptionText(ctx, budgetChars = 100)
        assertEquals(100, text!!.length)
        assertTrue(text.endsWith("..."))
    }

    @Test
    fun openAiSttPromptUsesDerivedTermsOnly() {
        val ctx = PersonalContext(
            profileText = "Long prose about my life",
            derivedTerms = listOf("Pebble", "Sarah"),
            biasTranscription = true,
        )
        assertEquals("Pebble, Sarah", PersonalContextFormatting.openAiSttPrompt(ctx))
    }

    @Test
    fun disabledBiasReturnsNull() {
        val ctx = PersonalContext(profileText = "hello", biasTranscription = false)
        assertNull(PersonalContextFormatting.transcriptionText(ctx))
        assertTrue(PersonalContextFormatting.transcriptionTerms(ctx).isEmpty())
    }
}
