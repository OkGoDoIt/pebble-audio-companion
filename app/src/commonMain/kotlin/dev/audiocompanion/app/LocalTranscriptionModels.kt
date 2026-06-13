package dev.audiocompanion.app

/**
 * Local Cactus-compatible speech models exposed in Settings.
 *
 * These are all Parakeet-family Cactus-Compute conversions, so the native transcription path
 * stays one-provider-one-loader while the user can choose the storage/quality tradeoff.
 */
data class LocalTranscriptionModelSpec(
    val id: String,
    val displayName: String,
    val shortLabel: String,
    val description: String,
    val repository: String,
    val revision: String,
    val archivePath: String,
    val installDirectoryName: String,
    val modelNameForProvenance: String,
    val modelVersionForProvenance: String,
    val downloadBytes: Long,
    val recommended: Boolean = false,
)

object LocalTranscriptionModels {
    const val DEFAULT_MODEL_ID = "parakeet-tdt-0.6b-v3-int8"

    val all: List<LocalTranscriptionModelSpec> = listOf(
        LocalTranscriptionModelSpec(
            id = "parakeet-tdt-0.6b-v3-int4",
            displayName = "Parakeet TDT 0.6B, small",
            shortLabel = "Small",
            description = "Smallest download. Good for testing or tight storage, with lower " +
                "quantization precision than the recommended model.",
            repository = "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision = "v1.10",
            archivePath = "weights/parakeet-tdt-0.6b-v3-int4.zip",
            installDirectoryName = "parakeet-tdt-0.6b-v3-int4",
            modelNameForProvenance = "parakeet-tdt-0.6b-v3-int4",
            modelVersionForProvenance = "v1.10",
            downloadBytes = 430_744_371L,
        ),
        LocalTranscriptionModelSpec(
            id = DEFAULT_MODEL_ID,
            displayName = "Parakeet TDT 0.6B, high quality",
            shortLabel = "Recommended",
            description = "Best default for this app: multilingual Parakeet TDT v3 with int8 " +
                "weights for better local accuracy than the small quantized option.",
            repository = "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision = "v1.10",
            archivePath = "weights/parakeet-tdt-0.6b-v3-int8.zip",
            // Preserve the directory used by the first hardware-test builds so users who
            // already downloaded the original single model do not have to fetch it again.
            installDirectoryName = "parakeet-tdt-0.6b-v3",
            modelNameForProvenance = "parakeet-tdt-0.6b-v3-int8",
            modelVersionForProvenance = "v1.10",
            downloadBytes = 706_097_687L,
            recommended = true,
        ),
        LocalTranscriptionModelSpec(
            id = "parakeet-ctc-1.1b-int8",
            displayName = "Parakeet CTC 1.1B, experimental",
            shortLabel = "Experimental",
            description = "Fast English-only CTC model for comparison. It can over-interpret " +
                "quiet or noisy watch audio, so the recommended TDT model is the safer default.",
            repository = "Cactus-Compute/parakeet-ctc-1.1b",
            revision = "v1.14",
            archivePath = "weights/parakeet-ctc-1.1b-int8.zip",
            installDirectoryName = "parakeet-ctc-1.1b-int8",
            modelNameForProvenance = "parakeet-ctc-1.1b-int8",
            modelVersionForProvenance = "v1.14",
            downloadBytes = 1_184_422_635L,
        ),
    )

    fun byId(id: String): LocalTranscriptionModelSpec =
        all.firstOrNull { it.id == id } ?: all.first { it.id == DEFAULT_MODEL_ID }
}
