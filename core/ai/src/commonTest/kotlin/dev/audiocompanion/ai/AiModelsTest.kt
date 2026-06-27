package dev.audiocompanion.ai

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AiModelsTest {
    @Test
    fun defaultIsGpt54Mini() {
        assertEquals("gpt-5.4-mini", AiModels.DEFAULT_MODEL_ID)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.default.id)
        assertTrue(AiModels.default.recommended)
    }

    @Test
    fun catalogContainsRequestedModels() {
        val ids = AiModels.all.map { it.id }
        assertTrue(ids.contains("gpt-5.5"))
        assertTrue(ids.contains("gpt-5.4-mini"))
        assertTrue(ids.contains("gpt-5.4-nano"))
        assertEquals(ids.distinct(), ids, "model ids must be unique")
        assertEquals(1, AiModels.all.count { it.recommended }, "exactly one recommended default")
    }

    @Test
    fun byIdResolvesKnownAndFallsBackForUnknown() {
        assertEquals("gpt-5.5", AiModels.byId("gpt-5.5").id)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId("nonexistent-model").id)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId(null).id)
        // Legacy stored id migrates via fallback
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId("gpt-5.5-mini").id)
    }
}
