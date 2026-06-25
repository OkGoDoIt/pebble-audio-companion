package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow

/**
 * A pre-assembled HTTP upload to run on a suspension-proof background transport (iOS background
 * NSURLSession / Android WorkManager). The body is already on disk so the platform can keep
 * uploading it while the app is suspended and hand back the result on relaunch.
 */
data class CloudUploadRequest(
    /** Stable id used to correlate the outcome back to a job (the segment id for these uploads). */
    val jobId: String,
    val url: String,
    val method: String = "POST",
    val headers: Map<String, String> = emptyMap(),
    /** Path to the already-assembled request body on disk. */
    val bodyFilePath: String,
)

/** Terminal result of a [CloudUploadRequest]. */
data class CloudUploadOutcome(
    val jobId: String,
    /** HTTP status, or 0 on a transport error (no response). */
    val httpStatus: Int,
    val responseBody: String = "",
    /** Non-null when the upload failed at the transport layer (no HTTP response). */
    val error: String? = null,
) {
    val isSuccess: Boolean get() = error == null && httpStatus in 200..299
}

/**
 * Suspension-proof HTTP upload transport. On iOS this is a background `NSURLSession` that keeps
 * uploading while the app is suspended and relaunches the app on completion; on Android a
 * WorkManager job. Implementations are durable across process death.
 */
interface BackgroundUploader {
    /** Queues [request] for background upload. Safe to call again for an already-queued job id. */
    suspend fun enqueue(request: CloudUploadRequest)

    /** Outcomes as uploads finish — including ones that completed while the app was suspended. */
    val outcomes: Flow<CloudUploadOutcome>

    /** Re-attach to in-flight uploads after a relaunch and replay completed-while-dead outcomes. */
    suspend fun reconcile()

    /** Job ids the transport still considers in flight, so the coordinator can reconcile state. */
    suspend fun inFlightJobIds(): Set<String>
}
