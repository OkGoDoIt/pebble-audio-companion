package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.ai.SegmentAnnotationPrompt
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import dev.audiocompanion.transcription.SegmentTranscript
import kotlin.coroutines.cancellation.CancellationException

/**
 * Generates the AI title + summary used by timeline/Library rows after a segment finishes
 * transcribing (MVP requirement; ux plan Sections 8/9).
 *
 * Runs strictly under the user's AI settings: when no router is configured or the configured
 * mode has no available provider (e.g. remote consent off), it does nothing and rows fall back
 * to transcript snippets. Failed generations are recorded and retried at most
 * [MAX_ATTEMPTS] times so a broken provider cannot spin.
 */
class SegmentEnrichmentWorker(
    private val annotations: FileSegmentAnnotationStore,
    private val router: AiModeRouter?,
    private val nowMs: () -> Long,
) {
    /** Annotates transcribed segments missing an annotation. Returns segment ids annotated. */
    suspend fun enrich(
        segments: List<SegmentMeta>,
        transcriptOf: (String) -> SegmentTranscript?,
    ): List<String> {
        val activeRouter = router ?: return emptyList()
        if (!activeRouter.isAvailable()) return emptyList()

        val annotated = mutableListOf<String>()
        for (meta in segments) {
            if (meta.isOpen || meta.transcriptionState != TranscriptionState.Complete) continue
            val existing = annotations.load(meta.segmentId)
            if (existing != null && (existing.hasContent || existing.attempts >= MAX_ATTEMPTS)) continue
            val transcript = transcriptOf(meta.segmentId) ?: continue
            if (transcript.text.isBlank()) continue

            val attempts = (existing?.attempts ?: 0) + 1
            try {
                val result = activeRouter.run(
                    AiRunRequest(
                        requestId = "annotate-${meta.segmentId}-$attempts",
                        prompt = SegmentAnnotationPrompt.template,
                        transcripts = listOf(
                            TranscriptExcerpt(
                                segmentId = meta.segmentId,
                                text = transcript.text,
                                startTimeMs = meta.startTimeMs.toLong(),
                            ),
                        ),
                    ),
                )
                val parsed = SegmentAnnotationPrompt.parse(result.text)
                annotations.save(
                    SegmentAnnotation(
                        segmentId = meta.segmentId,
                        title = parsed.title,
                        summary = parsed.summary,
                        modeUsed = result.modeUsed,
                        providerId = result.providerId,
                        modelUsed = result.modelUsed,
                        createdAtMs = nowMs(),
                        attempts = attempts,
                    ),
                )
                annotated += meta.segmentId
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                annotations.save(
                    SegmentAnnotation(
                        segmentId = meta.segmentId,
                        createdAtMs = nowMs(),
                        attempts = attempts,
                        lastError = e.message ?: e::class.simpleName,
                    ),
                )
            }
        }
        return annotated
    }

    companion object {
        const val MAX_ATTEMPTS = 3
    }
}
