package dev.audiocompanion.transcription

import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileTranscriptStoreTest {
    private var clock = 9_000L

    private fun tempRoot(): Path {
        val dir = File.createTempFile("transcripts", null).apply {
            delete()
            mkdirs()
        }
        dir.deleteOnExit()
        return Path(dir.absolutePath)
    }

    private fun store(root: Path) = FileTranscriptStore(SystemFileSystem, root) { clock++ }

    private fun routed(text: String) = RoutedTranscription(
        text = text,
        modeUsed = TranscriptionMode.LocalFirst,
        providerId = "local",
        modelUsed = "model-1",
        segments = listOf(TranscriptSegment(text = "hello", startMs = 1_000, endMs = 2_000)),
        words = listOf(TranscriptWord(text = "hello", startMs = 1_000, endMs = 1_400)),
    )

    @Test
    fun saveAndLoadRoundTrip() {
        val store = store(tempRoot())

        store.save("seg-1", routed("hello world"))

        val loaded = store.load("seg-1")
        assertEquals("hello world", loaded?.text)
        assertEquals(TranscriptionMode.LocalFirst, loaded?.modeUsed)
        assertEquals("local", loaded?.providerId)
        assertEquals("model-1", loaded?.modelUsed)
        assertEquals("seg-1", loaded?.segmentId)
        assertEquals(listOf(TranscriptSegment(text = "hello", startMs = 1_000, endMs = 2_000)), loaded?.segments)
        assertEquals(listOf(TranscriptWord(text = "hello", startMs = 1_000, endMs = 1_400)), loaded?.words)
    }

    @Test
    fun saveOverwritesExistingTranscript() {
        val store = store(tempRoot())
        store.save("seg-1", routed("first"))

        store.save("seg-1", routed("second"))

        assertEquals("second", store.load("seg-1")?.text)
        assertEquals(1, store.list().size)
    }

    @Test
    fun listReturnsTranscriptsOrderedByCreation() {
        val store = store(tempRoot())
        store.save("seg-b", routed("b"))
        store.save("seg-a", routed("a"))

        assertEquals(listOf("seg-b", "seg-a"), store.list().map { it.segmentId })
    }

    @Test
    fun deleteRemovesOneTranscript() {
        val store = store(tempRoot())
        store.save("seg-1", routed("one"))
        store.save("seg-2", routed("two"))

        store.delete("seg-1")

        assertNull(store.load("seg-1"))
        assertEquals("two", store.load("seg-2")?.text)
    }

    @Test
    fun deleteAllRemovesEverything() {
        val store = store(tempRoot())
        store.save("seg-1", routed("one"))
        store.save("seg-2", routed("two"))

        store.deleteAll()

        assertTrue(store.list().isEmpty())
    }

    @Test
    fun loadOfMissingSegmentIsNull() {
        assertNull(store(tempRoot()).load("seg-missing"))
    }
}
