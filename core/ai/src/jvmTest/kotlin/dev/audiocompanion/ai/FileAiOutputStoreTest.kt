package dev.audiocompanion.ai

import java.nio.file.Files
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FileAiOutputStoreTest {
    private var clock = 1_000L

    private fun tempRoot(): Path =
        Path(Files.createTempDirectory("audio-ai-test").toFile().absolutePath)

    @Test
    fun savesLoadsListsAndDeletesOutput() {
        val store = FileAiOutputStore(SystemFileSystem, tempRoot(), { clock })
        val request = AiRunRequest(
            requestId = "run-1",
            prompt = AiPromptTemplate(
                id = "actions",
                title = "Action Items",
                systemPrompt = "Extract action items.",
                userPrompt = "Use transcripts.",
            ),
            transcripts = listOf(
                TranscriptExcerpt(segmentId = "seg-1", text = "call Sam"),
                TranscriptExcerpt(segmentId = "seg-1", text = "email Lee"),
                TranscriptExcerpt(segmentId = "seg-2", text = "book room"),
            ),
        )
        val result = RoutedAiResult(
            text = "1. Call Sam\n2. Email Lee",
            modeUsed = AiProcessingMode.RemoteOnly,
            providerId = "remote",
            modelUsed = "model-a",
            inputTokens = 12,
            outputTokens = 8,
        )

        val saved = store.save(request, result, userConsentedToRemote = true)

        assertEquals("run-1", saved.outputId)
        assertEquals(listOf("seg-1", "seg-2"), saved.segmentIds)
        assertEquals(saved, store.load("run-1"))
        assertEquals(listOf(saved), store.list())

        store.delete("run-1")
        assertNull(store.load("run-1"))
    }
}
