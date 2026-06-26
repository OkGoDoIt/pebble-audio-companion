package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The cloud speech-to-text backends the user can choose between. */
enum class CloudProvider {
    OpenAi,
    Soniox,
}

/**
 * A [TranscriptionProvider] that delegates to whichever cloud backend the user has selected, so the
 * rest of the pipeline (router, processor, live transcriber) stays provider-agnostic. The active
 * provider is resolved per call from [selected], so changing the setting takes effect immediately
 * without rebuilding the runtime.
 */
class SelectableCloudTranscriptionProvider(
    private val selected: () -> CloudProvider,
    private val openAi: TranscriptionProvider,
    private val soniox: TranscriptionProvider,
) : TranscriptionProvider, CloudUploadCapable, CloudConnectivityCheck {
    override val id: String get() = active().id
    override val status: StateFlow<ProviderStatus> = MutableStateFlow(ProviderStatus.Ready)

    override suspend fun isAvailable(): Boolean = active().isAvailable()

    override suspend fun checkConnectivity(): CloudConnectivityResult =
        (active() as? CloudConnectivityCheck)?.checkConnectivity()
            ?: CloudConnectivityResult.Failed("The selected cloud provider cannot be tested.")

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult = active().transcribe(pcmChunks, sampleRateHz)

    /** The selected backend, when it supports background upload. */
    val activeUploadCapable: CloudUploadCapable? get() = active() as? CloudUploadCapable

    override suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int): CloudUploadPlan? =
        activeUploadCapable?.uploadPlan(wav, sampleRateHz)

    override suspend fun onUploadResponse(httpStatus: Int, body: String): CloudUploadStep =
        (activeUploadCapable ?: error("active cloud provider does not support upload"))
            .onUploadResponse(httpStatus, body)

    override suspend fun completeControlPlane(controlState: String): TranscriptionResult =
        (activeUploadCapable ?: error("active cloud provider does not support upload"))
            .completeControlPlane(controlState)

    /** The currently selected cloud backend, for state keyed by provider. */
    fun selectedProvider(): CloudProvider = selected()

    /** The upload driver for a specific backend, so in-flight jobs finish on their original
     *  provider even if the selection changed mid-flight. */
    fun capable(provider: CloudProvider): CloudUploadCapable? = when (provider) {
        CloudProvider.OpenAi -> openAi as? CloudUploadCapable
        CloudProvider.Soniox -> soniox as? CloudUploadCapable
    }

    private fun active(): TranscriptionProvider = when (selected()) {
        CloudProvider.OpenAi -> openAi
        CloudProvider.Soniox -> soniox
    }
}
