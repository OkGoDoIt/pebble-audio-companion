package dev.audiocompanion.ai

import kotlin.coroutines.cancellation.CancellationException

/**
 * Local/remote AI routing for manual transcript processing.
 *
 * Semantics intentionally match the transcription router: Only modes never fall back; First modes
 * try the preferred provider and then fall back to the other provider for ordinary provider
 * failures. Cancellation and explicit consent failures are never swallowed.
 */
class AiModeRouter(
    private val local: AiProvider?,
    private val remote: AiProvider?,
    private val mode: () -> AiProcessingMode,
) {
    var lastSuccessfulMode: AiProcessingMode? = null
        private set

    suspend fun isAvailable(): Boolean = when (mode()) {
        AiProcessingMode.LocalOnly -> local?.isAvailable() == true
        AiProcessingMode.RemoteOnly -> remote?.isAvailable() == true
        AiProcessingMode.LocalFirst, AiProcessingMode.RemoteFirst ->
            local?.isAvailable() == true || remote?.isAvailable() == true
    }

    suspend fun run(request: AiRunRequest): RoutedAiResult {
        val result = when (val mode = mode()) {
            AiProcessingMode.LocalOnly ->
                runProvider(local, "local", request, modeUsed = mode)

            AiProcessingMode.RemoteOnly ->
                runProvider(remote, "remote", request, modeUsed = mode)

            AiProcessingMode.LocalFirst -> try {
                runProvider(local, "local", request, modeUsed = mode)
            } catch (e: CancellationException) {
                throw e
            } catch (e: AiException.ConsentRequired) {
                throw e
            } catch (e: Exception) {
                runProvider(remote, "remote", request, modeUsed = AiProcessingMode.RemoteOnly, suppressed = e)
            }

            AiProcessingMode.RemoteFirst -> try {
                runProvider(remote, "remote", request, modeUsed = mode)
            } catch (e: CancellationException) {
                throw e
            } catch (e: AiException.ConsentRequired) {
                throw e
            } catch (e: Exception) {
                runProvider(local, "local", request, modeUsed = AiProcessingMode.LocalOnly, suppressed = e)
            }
        }
        lastSuccessfulMode = result.modeUsed
        return result
    }

    private suspend fun runProvider(
        provider: AiProvider?,
        role: String,
        request: AiRunRequest,
        modeUsed: AiProcessingMode,
        suppressed: Exception? = null,
    ): RoutedAiResult {
        if (provider == null || !provider.isAvailable()) {
            throw AiException.ProviderUnavailable(provider?.id ?: role).apply {
                suppressed?.let(::addSuppressed)
            }
        }
        val providerResult = try {
            provider.run(request)
        } catch (e: Exception) {
            suppressed?.let(e::addSuppressed)
            throw e
        }
        return RoutedAiResult(
            text = providerResult.text,
            modeUsed = modeUsed,
            providerId = provider.id,
            modelUsed = providerResult.modelUsed,
            inputTokens = providerResult.inputTokens,
            outputTokens = providerResult.outputTokens,
        )
    }
}
