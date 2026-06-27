package dev.audiocompanion.ai

import kotlin.coroutines.cancellation.CancellationException

/** Readiness of an OS on-device language model, mapped from the platform's own status. */
enum class OnDeviceAvailability {
    /** The model is present and ready to run now. */
    Available,

    /** Supported, but the model must be downloaded first. */
    Downloadable,

    /** Supported and currently downloading/initializing; try again later. */
    Downloading,

    /** Not supported on this device/OS, or disabled by the user. */
    Unavailable,
}

/**
 * Abstraction over an OS-provided on-device LLM (Apple Foundation Models, Android Gemini Nano via ML
 * Kit). Platform code implements this; [OnDeviceAiProvider] adapts it to [AiProvider]. Kept in
 * commonMain so the provider logic is unit-testable with a fake implementation.
 */
interface OnDeviceLanguageModel {
    /** Stable identifier recorded as the model used, e.g. "apple-foundation-models". */
    val id: String

    suspend fun availability(): OnDeviceAvailability

    /**
     * Runs the model with system-style [instructions] and a user [prompt], returning the completion
     * text. [maxOutputTokens] is a hint (null = provider default). Implementations should throw on
     * failure; [CancellationException] must propagate.
     */
    suspend fun generate(instructions: String, prompt: String, maxOutputTokens: Int?): String
}

/**
 * [AiProvider] backed by an on-device OS model. This is a fully local, private provider: it requires
 * no remote consent and no API key because no data leaves the device. It is wired into the
 * [AiModeRouter]'s local slot, so LocalOnly runs on-device and LocalFirst/RemoteFirst fall back
 * to/from the cloud as configured.
 *
 * Fail-closed: when no model is injected (platform unsupported / bridge not registered) or the model
 * reports anything other than [OnDeviceAvailability.Available], the provider is unavailable and rows
 * fall back to transcript snippets — it never blocks devices that lack on-device AI.
 */
class OnDeviceAiProvider(
    private val model: OnDeviceLanguageModel?,
    private val maxInputChars: Int = DEFAULT_MAX_INPUT_CHARS,
    private val maxOutputTokens: Int? = DEFAULT_MAX_OUTPUT_TOKENS,
) : AiProvider {
    override val id: String = model?.id ?: "on-device"

    override suspend fun isAvailable(): Boolean =
        model?.availability() == OnDeviceAvailability.Available

    override suspend fun run(request: AiRunRequest): AiProviderResult {
        val activeModel = model ?: throw AiException.ProviderUnavailable(id)
        if (activeModel.availability() != OnDeviceAvailability.Available) {
            throw AiException.ProviderUnavailable(id)
        }
        val userContent = AiTranscriptFormatting.buildUserContent(request, maxInputChars)
        val text = try {
            activeModel.generate(
                instructions = request.prompt.systemPrompt,
                prompt = userContent,
                maxOutputTokens = maxOutputTokens,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: AiException) {
            throw e
        } catch (e: Exception) {
            throw AiException.ProviderFailed("On-device AI generation failed", e)
        }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            throw AiException.ProviderFailed("On-device AI returned an empty completion")
        }
        return AiProviderResult(text = trimmed, modelUsed = activeModel.id)
    }

    companion object {
        // On-device context windows are small; keep input well under the budget. Titles/summaries
        // care about the gist, so a generous-but-bounded slice of a long transcript is fine.
        private const val DEFAULT_MAX_INPUT_CHARS = 12_000

        // Title + 1-3 sentence summary is short; cap output so generation stays fast.
        private const val DEFAULT_MAX_OUTPUT_TOKENS = 256
    }
}
