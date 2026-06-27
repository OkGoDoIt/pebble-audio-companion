package dev.audiocompanion.app

import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import dev.audiocompanion.ai.OnDeviceAvailability
import dev.audiocompanion.ai.OnDeviceLanguageModel
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * [OnDeviceLanguageModel] backed by Android's on-device Gemini Nano via the ML Kit GenAI Prompt API
 * (AICore). Available only on supported devices (Pixel 9/10, Galaxy S25, …) with the feature
 * downloaded; everywhere else [availability] reports a non-Available status and the provider stays
 * unavailable, so unsupported devices are unaffected.
 *
 * When the feature is downloadable, a one-shot background download is kicked off so on-device AI can
 * activate on a later pass without blocking the current one or surprising the user with a foreground
 * wait.
 */
class AndroidGeminiNanoLanguageModel(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val clientFactory: () -> GenerativeModel = { Generation.getClient() },
) : OnDeviceLanguageModel {
    override val id: String = "gemini-nano"

    private val mutex = Mutex()
    private var client: GenerativeModel? = null
    private val downloadTriggered = AtomicBoolean(false)

    private suspend fun client(): GenerativeModel = mutex.withLock {
        client ?: clientFactory().also { client = it }
    }

    override suspend fun availability(): OnDeviceAvailability {
        val status = try {
            client().checkStatus()
        } catch (e: Exception) {
            return OnDeviceAvailability.Unavailable
        }
        return when (status) {
            FeatureStatus.AVAILABLE -> OnDeviceAvailability.Available
            FeatureStatus.DOWNLOADING -> OnDeviceAvailability.Downloading
            FeatureStatus.DOWNLOADABLE -> {
                triggerDownloadOnce()
                OnDeviceAvailability.Downloadable
            }
            else -> OnDeviceAvailability.Unavailable
        }
    }

    private fun triggerDownloadOnce() {
        if (!downloadTriggered.compareAndSet(false, true)) return
        scope.launch {
            try {
                client().download().collect { /* progress ignored; availability polls report state */ }
            } catch (e: Exception) {
                // Allow a retry on a later availability check (e.g. transient/AICore not ready).
                downloadTriggered.set(false)
            }
        }
    }

    override suspend fun generate(instructions: String, prompt: String, maxOutputTokens: Int?): String {
        // The Prompt API has no separate system role, so prepend the instructions to the prompt.
        val combined = if (instructions.isBlank()) prompt else "$instructions\n\n$prompt"
        val request = generateContentRequest(TextPart(combined)) {
            temperature = 0.3f
            this.maxOutputTokens = maxOutputTokens
        }
        val response = client().generateContent(request)
        return response.candidates.firstOrNull()?.text.orEmpty()
    }
}
