package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class OpenAiTranscriptionProviderTest {
    @Test
    fun unavailableWithoutConsentOrKey() = runTest {
        val provider = OpenAiTranscriptionProvider(
            client = HttpClient(MockEngine) {
                engine {
                    addHandler {
                        error("provider should not issue requests without consent and an API key")
                    }
                }
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
    fun uploadsWavMultipartAndParsesText() = runTest {
        lateinit var request: HttpRequestData
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    request = it
                    respond(
                        content = ByteReadChannel("""{"text":"hello watch"}"""),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiTranscriptionProvider(
            client = client,
            apiKey = { "test-key" },
            cloudConsent = { true },
            model = { "gpt-transcribe" },
        )

        val result = provider.transcribe(flowOf(ByteArray(640) { 1 }), 16_000)

        assertEquals("hello watch", result.text)
        assertEquals("openai", result.providerId)
        assertEquals("Bearer test-key", request.headers[HttpHeaders.Authorization])
    }

    @Test
    fun splitsLargePcmIntoMultipleUploads() = runTest {
        var calls = 0
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    calls += 1
                    respond(
                        content = ByteReadChannel("""{"text":"part $calls"}"""),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiTranscriptionProvider(
            client = client,
            apiKey = { "test-key" },
            cloudConsent = { true },
            maxUploadBytes = 100,
        )

        val result = provider.transcribe(flowOf(ByteArray(120) { 7 }), 16_000)

        assertEquals(3, calls)
        assertEquals("part 1\npart 2\npart 3", result.text)
    }

    @Test
    fun parsesWhisperVerboseTimestamps() = runTest {
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    respond(
                        content = ByteReadChannel(
                            """
                            {
                              "text": "hello watch",
                              "segments": [
                                {"start": 1.25, "end": 2.5, "text": "hello watch"}
                              ],
                              "words": [
                                {"start": 1.25, "end": 1.7, "word": "hello"},
                                {"start": 1.8, "end": 2.5, "word": "watch"}
                              ]
                            }
                            """.trimIndent(),
                        ),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiTranscriptionProvider(
            client = client,
            apiKey = { "test-key" },
            cloudConsent = { true },
            model = { "whisper-1" },
        )

        val result = provider.transcribe(flowOf(ByteArray(640) { 1 }), 16_000)

        assertEquals("hello watch", result.text)
        assertEquals(listOf(TranscriptSegment("hello watch", 1_250, 2_500)), result.segments)
        assertEquals(listOf(TranscriptWord("hello", 1_250, 1_700), TranscriptWord("watch", 1_800, 2_500)), result.words)
    }

    @Test
    fun diarizationUsesDiarizeModelAndParsesSpeakers() = runTest {
        lateinit var request: HttpRequestData
        val client = HttpClient(MockEngine) {
            engine {
                addHandler {
                    request = it
                    respond(
                        content = ByteReadChannel(
                            """
                            {
                              "text": "hi there",
                              "segments": [
                                {"type":"transcript.text.segment","id":"s0","start":0.0,"end":1.0,
                                 "text":"hi","speaker":"agent"},
                                {"type":"transcript.text.segment","id":"s1","start":1.0,"end":2.0,
                                 "text":"there","speaker":"customer"}
                              ]
                            }
                            """.trimIndent(),
                        ),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        }
        val provider = OpenAiTranscriptionProvider(
            client = client,
            apiKey = { "test-key" },
            cloudConsent = { true },
            model = { "gpt-transcribe" }, // overridden by diarization
            diarizationEnabled = { true },
        )

        val result = provider.transcribe(flowOf(ByteArray(640) { 1 }), 16_000)

        assertEquals("hi there", result.text)
        assertEquals("gpt-4o-transcribe-diarize", result.modelUsed)
        assertEquals(listOf("agent", "customer"), result.segments.map { it.speaker })
        assertEquals(0L, result.segments.first().startMs)
        assertEquals(2_000L, result.segments.last().endMs)
    }

    @Test
    fun wavEncoderWritesExpectedHeader() {
        val wav = PcmWav.encodeMono16(byteArrayOf(1, 2, 3, 4), 16_000)

        assertEquals("RIFF", wav.decodeToString(0, 4))
        assertEquals("WAVE", wav.decodeToString(8, 12))
        assertEquals("fmt ", wav.decodeToString(12, 16))
        assertEquals("data", wav.decodeToString(36, 40))
        assertEquals(48, wav.size)
        assertTrue(wav.copyOfRange(44, 48).contentEquals(byteArrayOf(1, 2, 3, 4)))
    }
}
