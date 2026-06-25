package dev.audiocompanion.transcription

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlin.coroutines.cancellation.CancellationException

/** A segment's audio ready to upload: WAV bytes plus the sample rate they were encoded at. */
data class SegmentAudio(val wav: ByteArray, val sampleRateHz: Int)

/**
 * Drives durable, suspension-proof cloud transcription uploads (plan point 7 / Phase B).
 *
 * It coordinates three durable pieces: the transcription [queue] (the `Uploading` task state is the
 * coordination token so the synchronous processor never double-runs an in-flight segment), the
 * [jobStore] (transport + control-plane state across process death), and the [uploader] transport.
 * Provider specifics live behind [CloudUploadCapable], so this class is provider-agnostic and
 * handles both single-shot (OpenAI: the response is the transcript) and upload-then-control-plane
 * (Soniox: the upload yields a file id; create/poll/fetch run when next awake) shapes.
 *
 * It runs only for cloud-primary modes ([cloudPrimary]); LocalFirst keeps its synchronous
 * local-then-cloud fallback untouched. The local path is never affected.
 */
class BackgroundCloudUploadCoordinator(
    private val uploader: BackgroundUploader,
    private val cloudProvider: SelectableCloudTranscriptionProvider,
    private val jobStore: CloudUploadJobStore,
    private val queue: FileTranscriptionQueue,
    private val transcriptStore: FileTranscriptStore,
    private val audioSource: suspend (segmentId: String) -> SegmentAudio?,
    private val onStateChanged: (segmentId: String, state: TaskState) -> Unit,
    private val fileSystem: FileSystem,
    private val bodyDir: Path,
    private val nowMs: () -> Long,
    private val cloudPrimary: () -> Boolean,
    private val maxConcurrentUploads: Int = DEFAULT_MAX_CONCURRENT_UPLOADS,
) {
    /** Starts consuming upload outcomes (including ones delivered after a relaunch). */
    fun start(scope: CoroutineScope): Job = scope.launch {
        uploader.outcomes.collect { onOutcome(it) }
    }

    /** Re-attach to in-flight uploads after a (re)launch and finish any deferred control planes. */
    suspend fun reconcile() {
        uploader.reconcile()
        val inFlight = uploader.inFlightJobIds()
        queue.resetAbandonedUploads(inFlight).forEach { onStateChanged(it, TaskState.Pending) }
        jobStore.all()
            .filter { it.phase == CloudUploadPhase.AwaitingControlPlane }
            .forEach { runControlPlane(it) }
        // Drop orphaned job records (no Uploading task and not in flight or awaiting control plane).
        jobStore.all().forEach { job ->
            val task = queue.load(job.jobId)
            val live = job.jobId in inFlight || job.phase == CloudUploadPhase.AwaitingControlPlane
            if (!live && task?.state != TaskState.Uploading) cleanup(job)
        }
    }

    /** Hands eligible Pending cloud segments to the background uploader, up to the concurrency cap. */
    suspend fun submitPending() {
        if (!cloudPrimary()) return
        val capable = cloudProvider.activeUploadCapable ?: return
        if (!cloudProvider.isAvailable()) return
        var budget = (maxConcurrentUploads - queue.uploadingSegmentIds().size).coerceAtLeast(0)
        if (budget == 0) return
        for (task in queue.all()) {
            if (budget == 0) break
            if (task.state != TaskState.Pending) continue
            val audio = audioSource(task.segmentId) ?: continue
            val plan = capable.uploadPlan(audio.wav, audio.sampleRateHz) ?: continue
            enqueueUpload(task.segmentId, plan)
            budget -= 1
        }
    }

    private suspend fun enqueueUpload(segmentId: String, plan: CloudUploadPlan) {
        fileSystem.createDirectories(bodyDir)
        val bodyPath = Path(bodyDir, "$segmentId.body")
        val contentType = MultipartBody.writeTo(
            fileSystem = fileSystem,
            path = bodyPath,
            boundary = "PebbleAudioBoundary-$segmentId",
            textFields = plan.textFields,
            file = plan.file,
        )
        jobStore.save(
            CloudUploadJob(
                jobId = segmentId,
                provider = cloudProvider.selectedProvider(),
                phase = CloudUploadPhase.Uploading,
                bodyFilePath = bodyPath.toString(),
                createdAtMs = nowMs(),
            ),
        )
        queue.markUploading(segmentId)
        onStateChanged(segmentId, TaskState.Uploading)
        uploader.enqueue(
            CloudUploadRequest(
                jobId = segmentId,
                url = plan.url,
                headers = plan.headers + ("Content-Type" to contentType),
                bodyFilePath = bodyPath.toString(),
            ),
        )
    }

    private suspend fun onOutcome(outcome: CloudUploadOutcome) {
        val job = jobStore.load(outcome.jobId) ?: return
        deleteBody(job) // the transport is done with the body file either way
        if (!outcome.isSuccess) {
            fail(job, outcome.error ?: "upload failed (${outcome.httpStatus})")
            return
        }
        val capable = cloudProvider.capable(job.provider)
        if (capable == null) {
            fail(job, "cloud provider ${job.provider} unavailable")
            return
        }
        try {
            when (val step = capable.onUploadResponse(outcome.httpStatus, outcome.responseBody)) {
                is CloudUploadStep.Done -> complete(job, step.result)
                is CloudUploadStep.NeedsControlPlane -> {
                    val updated = job.copy(
                        phase = CloudUploadPhase.AwaitingControlPlane,
                        sonioxFileId = step.controlState,
                    )
                    jobStore.save(updated)
                    runControlPlane(updated)
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: TranscriptionException.NoSpeechDetected) {
            noSpeech(job)
        } catch (e: Throwable) {
            fail(job, e.message ?: "upload processing failed")
        }
    }

    private suspend fun runControlPlane(job: CloudUploadJob) {
        val capable = cloudProvider.capable(job.provider) ?: run {
            fail(job, "cloud provider ${job.provider} unavailable")
            return
        }
        val state = job.sonioxFileId ?: run {
            fail(job, "missing control-plane state")
            return
        }
        try {
            complete(job, capable.completeControlPlane(state))
        } catch (e: CancellationException) {
            throw e
        } catch (_: TranscriptionException.NoSpeechDetected) {
            noSpeech(job)
        } catch (e: Throwable) {
            fail(job, e.message ?: "control plane failed")
        }
    }

    private fun complete(job: CloudUploadJob, result: TranscriptionResult) {
        val routed = RoutedTranscription(
            text = result.text,
            modeUsed = TranscriptionMode.RemoteOnly,
            providerId = result.providerId,
            modelUsed = result.modelUsed,
            segments = result.segments,
            words = result.words,
        )
        transcriptStore.save(job.jobId, routed)
        queue.markComplete(job.jobId, routed)
        onStateChanged(job.jobId, TaskState.Complete)
        cleanup(job)
    }

    private fun fail(job: CloudUploadJob, message: String) {
        queue.markFailed(job.jobId, message, retryable = true)
        onStateChanged(job.jobId, TaskState.Failed)
        cleanup(job)
    }

    private fun noSpeech(job: CloudUploadJob) {
        queue.markNoSpeech(job.jobId)
        onStateChanged(job.jobId, TaskState.NoSpeech)
        cleanup(job)
    }

    private fun cleanup(job: CloudUploadJob) {
        deleteBody(job)
        jobStore.delete(job.jobId)
    }

    private fun deleteBody(job: CloudUploadJob) {
        runCatching { fileSystem.delete(Path(job.bodyFilePath), mustExist = false) }
    }

    companion object {
        private const val DEFAULT_MAX_CONCURRENT_UPLOADS = 4
    }
}
