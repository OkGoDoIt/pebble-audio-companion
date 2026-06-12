package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlin.coroutines.cancellation.CancellationException

/** Router outcome with `modeUsed` provenance (which path actually produced the text). */
data class RoutedTranscription(
    val text: String,
    /**
     * The mode that actually produced this result: equal to the configured mode when the
     * primary path succeeded, or the fallback's "-Only" mode when it didn't (matching
     * CactusTranscriptionService's modeUsed semantics).
     */
    val modeUsed: TranscriptionMode,
    val providerId: String,
    val modelUsed: String?,
    val segments: List<TranscriptSegment> = emptyList(),
    val words: List<TranscriptWord> = emptyList(),
)

/**
 * Four-mode local/remote router; the routing/fallback semantics are ported from
 * mobileapp's CactusTranscriptionService.localTranscribe():
 *
 * - LocalOnly / RemoteOnly: use exactly that provider, no fallback.
 * - LocalFirst: try local; on failure (except cancellation and no-speech) fall back to
 *   remote with modeUsed = RemoteOnly.
 * - RemoteFirst: try remote; on failure fall back to local with modeUsed = LocalOnly.
 * - NoSpeechDetected is a valid result, never a reason to fall back.
 */
class TranscriptionModeRouter(
    private val local: TranscriptionProvider?,
    private val remote: TranscriptionProvider?,
    private val mode: () -> TranscriptionMode,
) {
    var lastSuccessfulMode: TranscriptionMode? = null
        private set

    suspend fun isAvailable(): Boolean = when (mode()) {
        TranscriptionMode.LocalOnly -> local?.isAvailable() == true
        TranscriptionMode.RemoteOnly -> remote?.isAvailable() == true
        TranscriptionMode.LocalFirst, TranscriptionMode.RemoteFirst ->
            local?.isAvailable() == true || remote?.isAvailable() == true
    }

    suspend fun transcribe(pcmChunks: Flow<ByteArray>, sampleRateHz: Int): RoutedTranscription {
        val result = when (val mode = mode()) {
            TranscriptionMode.LocalOnly ->
                runProvider(local, "local", pcmChunks, sampleRateHz, modeUsed = mode)

            TranscriptionMode.RemoteOnly ->
                runProvider(remote, "remote", pcmChunks, sampleRateHz, modeUsed = mode)

            TranscriptionMode.LocalFirst -> try {
                runProvider(local, "local", pcmChunks, sampleRateHz, modeUsed = mode)
            } catch (e: CancellationException) {
                throw e
            } catch (e: TranscriptionException.NoSpeechDetected) {
                throw e
            } catch (e: Exception) {
                runProvider(remote, "remote", pcmChunks, sampleRateHz,
                    modeUsed = TranscriptionMode.RemoteOnly, suppressed = e)
            }

            TranscriptionMode.RemoteFirst -> try {
                runProvider(remote, "remote", pcmChunks, sampleRateHz, modeUsed = mode)
            } catch (e: CancellationException) {
                throw e
            } catch (e: TranscriptionException.NoSpeechDetected) {
                throw e
            } catch (e: Exception) {
                runProvider(local, "local", pcmChunks, sampleRateHz,
                    modeUsed = TranscriptionMode.LocalOnly, suppressed = e)
            }
        }
        lastSuccessfulMode = result.modeUsed
        return result
    }

    private suspend fun runProvider(
        provider: TranscriptionProvider?,
        role: String,
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
        modeUsed: TranscriptionMode,
        suppressed: Exception? = null,
    ): RoutedTranscription {
        if (provider == null || !provider.isAvailable()) {
            throw TranscriptionException.ProviderUnavailable(provider?.id ?: role).apply {
                suppressed?.let(::addSuppressed)
            }
        }
        val result = try {
            provider.transcribe(pcmChunks, sampleRateHz)
        } catch (e: Exception) {
            suppressed?.let(e::addSuppressed)
            throw e
        }
        return RoutedTranscription(
            text = result.text,
            modeUsed = modeUsed,
            providerId = result.providerId,
            modelUsed = result.modelUsed,
            segments = result.segments,
            words = result.words,
        )
    }
}
