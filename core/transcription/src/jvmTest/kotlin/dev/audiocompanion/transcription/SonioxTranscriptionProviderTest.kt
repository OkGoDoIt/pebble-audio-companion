package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class SonioxTranscriptionProviderTest {

    private fun MockRequestHandleScope.jsonResponse(content: String) = respond(
        content = ByteReadChannel(content),
        status = HttpStatusCode.OK,
        headers = headersOf(HttpHeaders.ContentType, "application/json"),
    )

    @Test
    fun realtimeConfigUsesSonioxRawPcmFormat() {
        // Regression guard: Soniox expects "s16le" for raw PCM. "pcm_s16le" makes the server reject
        // the live stream, which silently fell back to local transcription.
        val provider = SonioxRealtimeProvider(
            client = HttpClient(MockEngine) {
                engine { addHandler { error("no requests expected") } }
            },
            apiKey = { "test-key" },
            cloudConsent = { true },
        )
        val config = provider.configJson("test-key", 16_000)
        assertTrue(config.contains("\"audio_format\":\"s16le\""), "config was: $config")
        assertTrue(!config.contains("pcm_s16le"), "must not use the invalid pcm_s16le token")
        assertTrue(config.contains("\"sample_rate\":16000"))
    }

    @Test
    fun unavailableWithoutConsentOrKey() = runTest {
        val provider = SonioxTranscriptionProvider(
            client = HttpClient(MockEngine) {
                engine { addHandler { error("no requests expected without consent/key") } }
            },
            apiKey = { "" },
            cloudConsent = { false },
        )

        assertEquals(false, provider.isAvailable())
        assertFailsWith<TranscriptionException.ProviderUnavailable> {
            provider.transcribe(flowOf(byteArrayOf(1, 2)), 16_000)
        }
    }

    @Test
    fun runsFullFlowGroupsSpeakersAndCleansUp() = runTest {
        var createBody: String? = null
        var pollCount = 0
        val deletes = mutableListOf<String>()
        val client = HttpClient(MockEngine) {
            engine {
                addHandler { request ->
                    val path = request.url.encodedPath
                    when {
                        request.method == HttpMethod.Post && path == "/v1/files" ->
                            jsonResponse("""{"id":"file-1","filename":"segment.wav","size":10}""")

                        request.method == HttpMethod.Post && path == "/v1/transcriptions" -> {
                            createBody = (request.body as? TextContent)?.text
                            jsonResponse("""{"id":"tr-1","status":"queued"}""")
                        }

                        request.method == HttpMethod.Get && path == "/v1/transcriptions/tr-1" -> {
                            pollCount += 1
                            val status = if (pollCount < 2) "processing" else "completed"
                            jsonResponse("""{"id":"tr-1","status":"$status"}""")
                        }

                        request.method == HttpMethod.Get &&
                            path == "/v1/transcriptions/tr-1/transcript" ->
                            jsonResponse(
                                """
                                {"id":"tr-1","text":"hello there general",
                                 "tokens":[
                                   {"text":"hello ","start_ms":0,"end_ms":300,"speaker":"1"},
                                   {"text":"there ","start_ms":300,"end_ms":600,"speaker":"1"},
                                   {"text":"general","start_ms":1200,"end_ms":1500,"speaker":"2"}
                                 ]}
                                """.trimIndent(),
                            )

                        request.method == HttpMethod.Delete -> {
                            deletes += path
                            respond(ByteReadChannel(""), HttpStatusCode.NoContent)
                        }

                        else -> error("unexpected ${request.method} $path")
                    }
                }
            }
        }
        val provider = SonioxTranscriptionProvider(
            client = client,
            apiKey = { "test-key" },
            cloudConsent = { true },
            diarizationEnabled = { true },
            pollIntervalMs = 1,
            sleep = {},
        )

        val result = provider.transcribe(flowOf(ByteArray(640) { 1 }), 16_000)

        assertEquals("hello there general", result.text)
        assertEquals("soniox", result.providerId)
        // Speaker change -> two segments.
        assertEquals(2, result.segments.size)
        assertEquals("1", result.segments[0].speaker)
        assertEquals("hello there", result.segments[0].text)
        assertEquals("2", result.segments[1].speaker)
        assertEquals("general", result.segments[1].text)
        assertTrue(pollCount >= 2, "expected to poll until completed")
        assertTrue(createBody?.contains("\"enable_speaker_diarization\":true") == true)
        // Best-effort cleanup of both the transcription and the file.
        assertTrue(deletes.any { it == "/v1/transcriptions/tr-1" })
        assertTrue(deletes.any { it == "/v1/files/file-1" })
    }

    @Test
    fun errorStatusFailsRetryable() = runTest {
        val client = HttpClient(MockEngine) {
            engine {
                addHandler { request ->
                    val path = request.url.encodedPath
                    when {
                        path == "/v1/files" -> jsonResponse("""{"id":"file-1"}""")
                        path == "/v1/transcriptions" && request.method == HttpMethod.Post ->
                            jsonResponse("""{"id":"tr-1","status":"queued"}""")
                        path == "/v1/transcriptions/tr-1" && request.method == HttpMethod.Get ->
                            jsonResponse("""{"id":"tr-1","status":"error","error_message":"bad audio"}""")
                        request.method == HttpMethod.Delete ->
                            respond(ByteReadChannel(""), HttpStatusCode.NoContent)
                        else -> error("unexpected ${request.method} $path")
                    }
                }
            }
        }
        val provider = SonioxTranscriptionProvider(
            client = client,
            apiKey = { "k" },
            cloudConsent = { true },
            pollIntervalMs = 1,
            sleep = {},
        )

        val failure = assertFailsWith<TranscriptionException.TranscriptionFailed> {
            provider.transcribe(flowOf(ByteArray(640) { 1 }), 16_000)
        }
        assertTrue(failure.message?.contains("bad audio") == true)
    }
}
