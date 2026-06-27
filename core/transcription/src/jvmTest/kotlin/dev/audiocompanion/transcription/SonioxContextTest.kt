package dev.audiocompanion.transcription

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonioxContextTest {
    @Test
    fun configJsonIncludesContextWhenProvided() {
        val provider = SonioxRealtimeProvider(
            client = HttpClient(MockEngine) {
                engine { addHandler { error("no network in unit test") } }
            },
            apiKey = { "key" },
            cloudConsent = { true },
            contextText = { "About me: Roger at Pebble" },
            contextTerms = { listOf("Pebble", "Sarah") },
        )
        val json = provider.configJson("key", 16000)
        assertTrue(json.contains("\"context\""))
        assertTrue(json.contains("About me: Roger at Pebble"))
        assertTrue(json.contains("Pebble"))
    }

    @Test
    fun buildSonioxContextJsonObjectOmitsWhenEmpty() {
        assertNull(buildSonioxContextJsonObject(null, emptyList()))
        val obj = buildSonioxContextJsonObject("notes", listOf("Term"))
        assertNotNull(obj)
        assertEquals("notes", obj["text"]?.toString()?.trim('"'))
    }
}
