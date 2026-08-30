package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlin.coroutines.cancellation.CancellationException

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
    /**
     * True while the segment is open (recording). A RESUME reattach can reopen a segment that was
     * briefly closed and even already transcribed; an open segment must never be transcribed (the
     * result would cover a stale prefix and terminally mask the audio appended after reattach).
     */
    private val isSegmentOpen: (segmentId: String) -> Boolean = { false },
) {
    /**
     * [segmentIds] are the closed, not-fully-transcribed segments. One with a terminal-success
     * task is a reattached segment that grew after transcription — requeue it; the rest enqueue
     * idempotently.
     */
    fun enqueueClosedSegments(segmentIds: Iterable<String>) {
        segmentIds.forEach { segmentId ->
            val existing = queue.load(segmentId)
            if (existing != null &&
                (existing.state == TaskState.Complete || existing.state == TaskState.NoSpeech)
            ) {
                queue.requeue(segmentId)
                onStateChanged(segmentId, TaskState.Pending)
            } else {
                queue.enqueue(segmentId)
            }
        }
    }

    suspend fun isTranscriptionAvailable(): Boolean = router.isAvailable()

    /**
     * Re-queues tasks that were parked as Disabled while no provider was usable. Call when
     * transcription availability may have changed (model downloaded, key/consent added, mode
     * switched). Returns the segment ids reset to Pending.
     */
    suspend fun reconsiderDisabled(): List<String> {
        if (!router.isAvailable()) return emptyList()
        return queue.resetDisabled().onEach { segmentId ->
            onStateChanged(segmentId, TaskState.Pending)
        }
    }

    /** Soonest time a failed task becomes retryable, or null when none is waiting. */
    fun nextRetryAtMs(): Long? = queue.nextRetryAtMs()

    suspend fun processNext(): TranscriptionTask? {
        val task = queue.nextRunnable() ?: return null
        // A segment that reattached (RESUME) while its task waited is recording again: leave the
        // task Pending; it runs after the segment's final close.
        if (isSegmentOpen(task.segmentId)) return null
        if (!router.isAvailable()) {
            val disabled = queue.markDisabled(task.segmentId)
            onStateChanged(task.segmentId, TaskState.Disabled)
            return disabled
        }

        queue.markRunning(task.segmentId)
        onStateChanged(task.segmentId, TaskState.Running)
        return try {
            val result = router.transcribe(pcmSource(task.segmentId), sampleRateHz)
            if (isSegmentOpen(task.segmentId)) {
                // The segment reattached mid-transcription; this result covers a stale prefix.
                // Discard it and re-run after the final close.
                return queue.requeue(task.segmentId).also {
                    onStateChanged(task.segmentId, TaskState.Pending)
                }
            }
            // Durability order matters: the transcript text is on disk before the task goes
            // terminal, so a crash in between re-runs transcription instead of losing text.
            transcriptStore?.save(task.segmentId, result)
            queue.markComplete(task.segmentId, result).also {
                onStateChanged(task.segmentId, TaskState.Complete)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: TranscriptionException.NoSpeechDetected) {
            queue.markNoSpeech(task.segmentId).also {
                onStateChanged(task.segmentId, TaskState.NoSpeech)
            }
        } catch (e: TranscriptionException.ProviderUnavailable) {
            queue.markDisabled(task.segmentId).also {
                onStateChanged(task.segmentId, TaskState.Disabled)
            }
        } catch (e: Throwable) {
            queue.markFailed(task.segmentId, e.message ?: e::class.simpleName.orEmpty(),
                retryable = true).also {
                onStateChanged(task.segmentId, TaskState.Failed)
            }
        }
    }
}
