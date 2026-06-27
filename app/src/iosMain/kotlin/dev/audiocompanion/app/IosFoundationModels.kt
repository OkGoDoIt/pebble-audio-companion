package dev.audiocompanion.app

import dev.audiocompanion.ai.OnDeviceAvailability
import dev.audiocompanion.ai.OnDeviceLanguageModel
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Swift-facing bridge to Apple's Foundation Models framework (iOS 26+). The framework is Swift-only,
 * so Kotlin/Native cannot call it directly; instead the iOS app target implements this interface in
 * Swift and registers it via [IosOnDeviceModelRegistry] at launch. Callback-based (not suspend)
 * because Swift can implement a Kotlin interface with closure parameters but cannot implement a
 * Kotlin `suspend` function.
 */
interface OnDeviceLanguageModelBridge {
    /** Reports current availability as one of the [IosOnDeviceModelRegistry] AVAILABILITY_* codes. */
    fun availability(callback: (Int) -> Unit)

    /**
     * Generates a completion. Calls [onResult] with (text, null) on success or (null, errorMessage)
     * on failure. Must invoke the callback exactly once.
     */
    fun generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Int,
        onResult: (String?, String?) -> Unit,
    )
}

/**
 * Holds the Swift-provided Foundation Models bridge. Swift sets [bridge] from the app delegate at
 * launch on iOS 26+ eligible devices. If it stays null (older iOS, ineligible device, or the Swift
 * side absent), on-device AI is simply reported unavailable — nothing breaks.
 */
object IosOnDeviceModelRegistry {
    var bridge: OnDeviceLanguageModelBridge? = null

    const val AVAILABILITY_AVAILABLE = 0
    const val AVAILABILITY_DOWNLOADABLE = 1
    const val AVAILABILITY_DOWNLOADING = 2
    const val AVAILABILITY_UNAVAILABLE = 3
}

/**
 * [OnDeviceLanguageModel] backed by the registered Foundation Models bridge. The bridge is resolved
 * lazily on every call, so it does not matter whether Swift registers before or after the runtime is
 * built.
 */
class IosFoundationModelsLanguageModel(
    private val bridgeProvider: () -> OnDeviceLanguageModelBridge? = { IosOnDeviceModelRegistry.bridge },
) : OnDeviceLanguageModel {
    override val id: String = "apple-foundation-models"

    override suspend fun availability(): OnDeviceAvailability {
        val bridge = bridgeProvider() ?: return OnDeviceAvailability.Unavailable
        val code = suspendCancellableCoroutine { cont ->
            bridge.availability { value -> if (cont.isActive) cont.resume(value) }
        }
        return when (code) {
            IosOnDeviceModelRegistry.AVAILABILITY_AVAILABLE -> OnDeviceAvailability.Available
            IosOnDeviceModelRegistry.AVAILABILITY_DOWNLOADABLE -> OnDeviceAvailability.Downloadable
            IosOnDeviceModelRegistry.AVAILABILITY_DOWNLOADING -> OnDeviceAvailability.Downloading
            else -> OnDeviceAvailability.Unavailable
        }
    }

    override suspend fun generate(instructions: String, prompt: String, maxOutputTokens: Int?): String {
        val bridge = bridgeProvider() ?: throw IllegalStateException("Foundation Models bridge not registered")
        return suspendCancellableCoroutine { cont ->
            bridge.generate(instructions, prompt, maxOutputTokens ?: 0) { text, error ->
                if (!cont.isActive) return@generate
                when {
                    error != null -> cont.resumeWithException(RuntimeException(error))
                    else -> cont.resume(text.orEmpty())
                }
            }
        }
    }
}
