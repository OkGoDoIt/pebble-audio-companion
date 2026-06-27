package dev.audiocompanion.ai

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class OpenAiChatAiProviderTest {

    private fun request(prompt: AiPromptTemplate = AiPromptTemplates.ActionItems) = AiRunRequest(
        requestId = "ai-1",
        prompt = prompt,
        transcripts = listOf(
            TranscriptExcerpt(segmentId = "seg-1", text = "We agreed Bob ships the fix Friday."),
        ),
    )

    @Test
    fun unavailableWithoutConsentOrKey() = runTest {
        val provider = OpenAiChatAiProvider(
            client = HttpClient(MockEngine) {
                engine {
                    addHandler { error("no requests without consent and key") }
                }
            },
            apiKey = { "" },
            remoteConsent = { false },
        )

        assertEquals(false, provider.isAvailable())
        assertFailsWith<AiException.ConsentRequired> { provider.run(request()) }
    }

    @Test
    fun consentWithoutKeyIsUnavailable() = runTest {
        val provider = OpenAiChatAiProvider(
            client = HttpClient(MockEngine) {
                engine {
                    addHandler { error("no requests without a key") }
                }
            },
            apiKey = { null },
            remoteConsent = { true },
        )

        assertEquals(false, provider.isAvailable())
        assertFailsWith<AiException.ProviderUnavailable> { provider.run(request()) }
    }

    @Test
    fun postsPromptAndTranscriptAndParsesCompletion() = runTest {
        lateinit var captured: HttpRequestData
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    captured = it
                    respond(
                        content = ByteReadChannel(
                            """
                            {
                              "model": "gpt-4o-mini-2024",
                              "choices": [{"message": {"role": "assistant", "content": "- Bob: ship the fix by Friday"}}],
                              "usage": {"prompt_tokens": 42, "completion_tokens": 12}
                            }
                            """.trimIndent(),
                        ),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiChatAiProvider(
            client = client,
            apiKey = { "test-key" },
            remoteConsent = { true },
        )

        val result = provider.run(request())

        assertEquals("- Bob: ship the fix by Friday", result.text)
        assertEquals("gpt-4o-mini-2024", result.modelUsed)
        assertEquals(42, result.inputTokens)
        assertEquals(12, result.outputTokens)
        assertEquals("Bearer test-key", captured.headers[HttpHeaders.Authorization])
        val body = captured.body.toByteArray().decodeToString()
        assertTrue(body.contains("seg-1"), "request body should reference the segment id")
        assertTrue(
            body.contains("We agreed Bob ships the fix Friday."),
            "request body should contain the transcript text",
        )
    }

    @Test
    fun sendsConfiguredModelInRequestBody() = runTest {
        lateinit var captured: HttpRequestData
        var selectedModel = "gpt-5.5-mini"
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    captured = it
                    respond(
                        content = ByteReadChannel(
                            """{"choices": [{"message": {"role": "assistant", "content": "ok"}}]}""",
                        ),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiChatAiProvider(
            client = client,
            apiKey = { "test-key" },
            remoteConsent = { true },
            model = { selectedModel },
        )

        provider.run(request())
        assertTrue(
            captured.body.toByteArray().decodeToString().contains("\"model\":\"gpt-5.5-mini\""),
            "request should carry the configured model",
        )

        // The lambda is read per request, so a settings change takes effect on the next call.
        selectedModel = "gpt-5.5"
        provider.run(request())
        assertTrue(
            captured.body.toByteArray().decodeToString().contains("\"model\":\"gpt-5.5\""),
            "model change should apply to the next request",
        )
    }

    @Test
    fun nonOkResponseFailsWithProviderFailed() = runTest {
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    respond(
                        content = ByteReadChannel("""{"error": {"message": "rate limited"}}"""),
                        status = HttpStatusCode.TooManyRequests,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiChatAiProvider(
            client = client,
            apiKey = { "test-key" },
            remoteConsent = { true },
        )

        assertFailsWith<AiException.ProviderFailed> { provider.run(request()) }
    }

    @Test
    fun oversizedTranscriptIsTruncatedNotRejected() = runTest {
        lateinit var captured: HttpRequestData
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    captured = it
                    respond(
                        content = ByteReadChannel(
                            """{"choices": [{"message": {"role": "assistant", "content": "ok"}}]}""",
                        ),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiChatAiProvider(
            client = client,
            apiKey = { "test-key" },
            remoteConsent = { true },
            maxInputChars = 500,
        )

        val bigRequest = AiRunRequest(
            requestId = "ai-2",
            prompt = AiPromptTemplates.DailySummary,
            transcripts = listOf(TranscriptExcerpt(segmentId = "seg-1", text = "word ".repeat(1_000))),
        )
        val result = provider.run(bigRequest)

        assertEquals("ok", result.text)
        val body = captured.body.toByteArray().decodeToString()
        assertTrue(body.contains("transcript truncated for length"))
    }
}
