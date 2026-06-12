package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow

/**
 * Durable transcription worker for closed audio segments.
 *
 * This class owns queue state transitions only. Audio decode and provider selection are injected
 * so platform/app layers can supply real Speex->PCM sources and real local/cloud providers.
 */
class TranscriptionProcessor(
    private val queue: FileTranscriptionQueue,
    private val router: TranscriptionModeRouter,
    private val pcmSource: suspend (segmentId: String) -> Flow<ByteArray>,
    private val sampleRateHz: Int = 16_000,
    private val onStateChanged: (segmentId: String, state: TaskState) -> Unit = { _, _ -> },
    /** Persists transcript text durably before the task is marked Complete. */
    private val transcriptStore: FileTranscriptStore? = null,
) {
    fun enqueueClosedSegments(segmentIds: Iterable<String>) {
        segmentIds.forEach { queue.enqueue(it) }
    }

    suspend fun processNext(): TranscriptionTask? {
        val task = queue.nextRunnable() ?: return null
        if (!router.isAvailable()) {
            val disabled = queue.markDisabled(task.segmentId)
            onStateChanged(task.segmentId, TaskState.Disabled)
            return disabled
        }

        queue.markRunning(task.segmentId)
        onStateChanged(task.segmentId, TaskState.Running)
        return try {
            val result = router.transcribe(pcmSource(task.segmentId), sampleRateHz)
            // Durability order matters: the transcript text is on disk before the task goes
            // terminal, so a crash in between re-runs transcription instead of losing text.
            transcriptStore?.save(task.segmentId, result)
            queue.markComplete(task.segmentId, result).also {
                onStateChanged(task.segmentId, TaskState.Complete)
            }
        } catch (_: TranscriptionException.NoSpeechDetected) {
            queue.markNoSpeech(task.segmentId).also {
                onStateChanged(task.segmentId, TaskState.NoSpeech)
            }
        } catch (e: TranscriptionException.ProviderUnavailable) {
            queue.markDisabled(task.segmentId).also {
                onStateChanged(task.segmentId, TaskState.Disabled)
            }
        } catch (e: Exception) {
            queue.markFailed(task.segmentId, e.message ?: e::class.simpleName.orEmpty(),
                retryable = true).also {
                onStateChanged(task.segmentId, TaskState.Failed)
            }
        }
    }
}
