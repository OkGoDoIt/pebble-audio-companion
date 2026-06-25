package dev.audiocompanion.transcription

/**
 * Provider-side knowledge for driving a background (suspension-proof) upload. Keeping this on the
 * provider lets the upload coordinator stay completely provider-agnostic: it only assembles the
 * body, hands it to the transport, and asks the provider what a response means.
 *
 * Two shapes are supported:
 *  - single-shot (OpenAI): the upload's HTTP response IS the transcript -> [CloudUploadStep.Done].
 *  - upload-then-control-plane (Soniox): the upload returns a file handle; the small create/poll/
 *    fetch control plane runs later in an awake window -> [CloudUploadStep.NeedsControlPlane].
 */
interface CloudUploadCapable {
    /** The initial background upload (endpoint, headers, multipart parts) for [wav], or null if
     *  this provider cannot currently background-upload (e.g. no key / consent). */
    suspend fun uploadPlan(wav: ByteArray, sampleRateHz: Int): CloudUploadPlan?

    /** Interprets the upload's HTTP response: a finished transcript, or a follow-up step. */
    suspend fun onUploadResponse(httpStatus: Int, body: String): CloudUploadStep

    /** Runs the remaining control plane (e.g. Soniox create/poll/fetch) from [controlState]. */
    suspend fun completeControlPlane(controlState: String): TranscriptionResult
}

/** Endpoint + headers + parts the coordinator assembles into a body file for the transport. */
data class CloudUploadPlan(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val textFields: List<Pair<String, String>> = emptyList(),
    val file: MultipartBody.FilePart,
)

sealed class CloudUploadStep {
    /** The upload response already contains the transcript. */
    data class Done(val result: TranscriptionResult) : CloudUploadStep()

    /** A follow-up control plane is required; [controlState] is opaque provider state (e.g. file id). */
    data class NeedsControlPlane(val controlState: String) : CloudUploadStep()
}
