package dev.audiocompanion.ai

import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SegmentAnnotationStoreTest {
    private var clock = 7_000L

    private fun tempRoot(): Path {
        val dir = File.createTempFile("annotations", null).apply {
            delete()
            mkdirs()
        }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun store(root: Path) = FileSegmentAnnotationStore(SystemFileSystem, root) { clock++ }

    @Test
    fun saveAndLoadRoundTrip() {
        val store = store(tempRoot())
        store.save(
            SegmentAnnotation(
                segmentId = "seg-1",
                title = "Team sync",
                summary = "Discussed the launch plan.",
                modeUsed = AiProcessingMode.RemoteOnly,
                providerId = "openai-chat",
                modelUsed = "gpt-4o-mini",
                createdAtMs = 0,
                attempts = 1,
            ),
        )

        val loaded = store.load("seg-1")
        assertEquals("Team sync", loaded?.title)
        assertEquals("Discussed the launch plan.", loaded?.summary)
        assertEquals(AiProcessingMode.RemoteOnly, loaded?.modeUsed)
        assertEquals(1, loaded?.attempts)
        assertTrue(loaded!!.hasContent)
    }

    @Test
    fun failureRecordHasNoContent() {
        val store = store(tempRoot())
        store.save(
            SegmentAnnotation(segmentId = "seg-1", createdAtMs = 0, attempts = 2, lastError = "boom"),
        )

        val loaded = store.load("seg-1")
        assertEquals(2, loaded?.attempts)
        assertEquals("boom", loaded?.lastError)
        assertEquals(false, loaded?.hasContent)
    }

    @Test
    fun deleteAndDeleteAll() {
        val store = store(tempRoot())
        store.save(SegmentAnnotation(segmentId = "seg-1", title = "a", createdAtMs = 0))
        store.save(SegmentAnnotation(segmentId = "seg-2", title = "b", createdAtMs = 0))

        store.delete("seg-1")
        assertNull(store.load("seg-1"))
        assertEquals(1, store.list().size)

        store.deleteAll()
        assertTrue(store.list().isEmpty())
    }
}

class SegmentAnnotationPromptTest {
    @Test
    fun parsesWellFormedResponse() {
        val parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Quarterly budget review\nSUMMARY: The team reviewed Q3 spend. Cuts were agreed.",
        )
        assertEquals("Quarterly budget review", parsed.title)
        assertEquals("The team reviewed Q3 spend. Cuts were agreed.", parsed.summary)
    }

    @Test
    fun parsesCaseInsensitiveAndPadded() {
        val parsed = SegmentAnnotationPrompt.parse(
            "  title: Coffee chat \n\n  Summary:  Casual conversation about weekend plans. ",
        )
        assertEquals("Coffee chat", parsed.title)
        assertEquals("Casual conversation about weekend plans.", parsed.summary)
    }

    @Test
    fun fallsBackToFirstLineAsTitle() {
        val parsed = SegmentAnnotationPrompt.parse("Planning discussion\nThey planned the sprint.")
        assertEquals("Planning discussion", parsed.title)
        assertEquals("They planned the sprint.", parsed.summary)
    }

    @Test
    fun boundsOversizedFields() {
        val parsed = SegmentAnnotationPrompt.parse(
            "TITLE: ${"t".repeat(300)}\nSUMMARY: ${"s".repeat(2000)}",
        )
        assertEquals(80, parsed.title?.length)
        assertEquals(600, parsed.summary?.length)
    }
}
