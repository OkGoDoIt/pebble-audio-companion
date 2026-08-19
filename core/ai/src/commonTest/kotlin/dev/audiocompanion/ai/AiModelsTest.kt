package dev.audiocompanion.ai

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AiModelsTest {
    @Test
    fun defaultIsGpt56Luna() {
        assertEquals("gpt-5.6-luna", AiModels.DEFAULT_MODEL_ID)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.default.id)
        assertTrue(AiModels.default.recommended)
    }

    @Test
    fun catalogContainsRequestedModels() {
        val ids = AiModels.all.map { it.id }
        assertTrue(ids.contains("gpt-5.6-luna"))
        assertTrue(ids.contains("gpt-5.6-terra"))
        assertTrue(ids.contains("gpt-5.6-sol"))
        assertEquals(ids.distinct(), ids, "model ids must be unique")
        assertEquals(1, AiModels.all.count { it.recommended }, "exactly one recommended default")
    }

    @Test
    fun byIdResolvesKnownAndFallsBackForUnknown() {
        assertEquals("gpt-5.6-sol", AiModels.byId("gpt-5.6-sol").id)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId("nonexistent-model").id)
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId(null).id)
    }

    @Test
    fun legacyIdsMigrateToTheEquivalentTier() {
        // Budget picks stay budget, frontier picks stay frontier.
        assertEquals("gpt-5.6-luna", AiModels.byId("gpt-5.4-nano").id)
        assertEquals("gpt-5.6-luna", AiModels.byId("gpt-5.4-mini").id)
        assertEquals("gpt-5.6-terra", AiModels.byId("gpt-5.4").id)
        assertEquals("gpt-5.6-sol", AiModels.byId("gpt-5.5").id)
        // An id that was never in the catalog still falls back to the default.
        assertEquals(AiModels.DEFAULT_MODEL_ID, AiModels.byId("gpt-5.5-mini").id)
    }

    @Test
    fun everyLegacyReplacementResolvesToACatalogEntry() {
        val ids = AiModels.all.map { it.id }.toSet()
        listOf("gpt-5.4-nano", "gpt-5.4-mini", "gpt-5.4", "gpt-5.5").forEach { legacy ->
            assertTrue(AiModels.byId(legacy).id in ids, "$legacy must map into the catalog")
        }
    }
}
