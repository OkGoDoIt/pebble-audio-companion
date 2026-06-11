package dev.audiocompanion.ai

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AiModeRouterTest {
    private val request = AiRunRequest(
        requestId = "run-1",
        prompt = AiPromptTemplate(
            id = "summary",
            title = "Summary",
            systemPrompt = "Summarize.",
            userPrompt = "Use the transcript.",
        ),
        transcripts = listOf(TranscriptExcerpt(segmentId = "seg-1", text = "hello world")),
    )

    @Test
    fun localFirstFallsBackToRemoteOnProviderFailure() = runTest {
        val router = AiModeRouter(
            local = FakeAiProvider("local", failure = IllegalStateException("local failed")),
            remote = FakeAiProvider("remote", text = "remote summary"),
            mode = { AiProcessingMode.LocalFirst },
        )

        val result = router.run(request)

        assertEquals("remote summary", result.text)
        assertEquals(AiProcessingMode.RemoteOnly, result.modeUsed)
        assertEquals("remote", result.providerId)
        assertEquals(AiProcessingMode.RemoteOnly, router.lastSuccessfulMode)
    }

    @Test
    fun consentFailureDoesNotFallBack() = runTest {
        val router = AiModeRouter(
            local = FakeAiProvider("local", failure = AiException.ConsentRequired("local")),
            remote = FakeAiProvider("remote", text = "remote summary"),
            mode = { AiProcessingMode.LocalFirst },
        )

        assertFailsWith<AiException.ConsentRequired> {
            router.run(request)
        }
    }

    @Test
    fun remoteOnlyDoesNotUseLocalFallback() = runTest {
        val router = AiModeRouter(
            local = FakeAiProvider("local", text = "local summary"),
            remote = FakeAiProvider("remote", available = false),
            mode = { AiProcessingMode.RemoteOnly },
        )

        assertFailsWith<AiException.ProviderUnavailable> {
            router.run(request)
        }
    }

    private class FakeAiProvider(
        override val id: String,
        private val available: Boolean = true,
        private val text: String = "ok",
        private val failure: Exception? = null,
    ) : AiProvider {
        override suspend fun isAvailable(): Boolean = available

        override suspend fun run(request: AiRunRequest): AiProviderResult {
            failure?.let { throw it }
            return AiProviderResult(text = text, modelUsed = "$id-model")
        }
    }
}
