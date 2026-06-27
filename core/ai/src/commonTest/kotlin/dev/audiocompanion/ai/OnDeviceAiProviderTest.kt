package dev.audiocompanion.ai

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private class FakeOnDeviceModel(
    var availability: OnDeviceAvailability = OnDeviceAvailability.Available,
    var response: String = "TITLE: Team sync\nSUMMARY: Discussed the plan.",
    var error: Exception? = null,
    override val id: String = "fake-on-device",
) : OnDeviceLanguageModel {
    var lastInstructions: String? = null
    var lastPrompt: String? = null
    var lastMaxOutputTokens: Int? = null
    var runCount = 0

    override suspend fun availability(): OnDeviceAvailability = availability

    override suspend fun generate(instructions: String, prompt: String, maxOutputTokens: Int?): String {
        runCount += 1
        lastInstructions = instructions
        lastPrompt = prompt
        lastMaxOutputTokens = maxOutputTokens
        error?.let { throw it }
        return response
    }
}

class OnDeviceAiProviderTest {
    private fun request(text: String = "We agreed Bob ships the fix Friday.") = AiRunRequest(
        requestId = "ai-1",
        prompt = SegmentAnnotationPrompt.template,
        transcripts = listOf(TranscriptExcerpt(segmentId = "seg-1", text = text)),
    )

    @Test
    fun unavailableWhenNoModelInjected() = runTest {
        val provider = OnDeviceAiProvider(model = null)
        assertEquals(false, provider.isAvailable())
        assertFailsWith<AiException.ProviderUnavailable> { provider.run(request()) }
    }

    @Test
    fun unavailableForEveryNonAvailableStatus() = runTest {
        for (status in listOf(
            OnDeviceAvailability.Downloadable,
            OnDeviceAvailability.Downloading,
            OnDeviceAvailability.Unavailable,
        )) {
            val model = FakeOnDeviceModel(availability = status)
            val provider = OnDeviceAiProvider(model)
            assertEquals(false, provider.isAvailable(), "status $status must be unavailable")
            assertFailsWith<AiException.ProviderUnavailable> { provider.run(request()) }
            assertEquals(0, model.runCount, "must not generate when unavailable")
        }
    }

    @Test
    fun generatesWithInstructionsPromptAndModelId() = runTest {
        val model = FakeOnDeviceModel()
        val provider = OnDeviceAiProvider(model)

        val result = provider.run(request())

        assertEquals("TITLE: Team sync\nSUMMARY: Discussed the plan.", result.text)
        assertEquals("fake-on-device", result.modelUsed)
        assertEquals(SegmentAnnotationPrompt.template.systemPrompt, model.lastInstructions)
        assertTrue(model.lastPrompt!!.contains("seg-1"), "prompt should carry the segment id")
        assertTrue(
            model.lastPrompt!!.contains("We agreed Bob ships the fix Friday."),
            "prompt should carry the transcript text",
        )
        assertTrue((model.lastMaxOutputTokens ?: 0) > 0, "should pass an output cap")
    }

    @Test
    fun emptyCompletionFails() = runTest {
        val provider = OnDeviceAiProvider(FakeOnDeviceModel(response = "   "))
        assertFailsWith<AiException.ProviderFailed> { provider.run(request()) }
    }

    @Test
    fun generationErrorBecomesProviderFailed() = runTest {
        val provider = OnDeviceAiProvider(FakeOnDeviceModel(error = IllegalStateException("nano boom")))
        val failure = assertFailsWith<AiException.ProviderFailed> { provider.run(request()) }
        assertTrue(failure.message?.contains("On-device") == true)
    }

    @Test
    fun oversizedTranscriptIsTruncated() = runTest {
        val model = FakeOnDeviceModel()
        val provider = OnDeviceAiProvider(model, maxInputChars = 500)

        provider.run(request(text = "word ".repeat(1_000)))

        assertTrue(model.lastPrompt!!.contains("transcript truncated for length"))
        assertTrue(model.lastPrompt!!.length <= 600)
    }

    @Test
    fun routesAsLocalProviderWithFallback() = runTest {
        // On-device is the router's local provider; LocalOnly uses it directly.
        val onDevice = OnDeviceAiProvider(FakeOnDeviceModel(response = "TITLE: Local\nSUMMARY: x."))
        val router = AiModeRouter(local = onDevice, remote = null) { AiProcessingMode.LocalOnly }

        val result = router.run(request())
        assertEquals("TITLE: Local\nSUMMARY: x.", result.text)
        assertEquals(AiProcessingMode.LocalOnly, result.modeUsed)
        assertEquals("fake-on-device", result.providerId)
    }
}
