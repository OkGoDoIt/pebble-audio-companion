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
 * Generates the AI title + summary shown on timeline/Library rows (ux plan Sections 8/9).
 *
 * Two passes per segment:
 *  - **Live/provisional**: while a conversation is still recording, summarize the rolling live
 *    preview transcript. The first provisional appears once there is enough text
 *    ([LIVE_MIN_CHARS]); it is then refreshed only when the transcript has grown meaningfully
 *    ([LIVE_REFRESH_MIN_GROWTH_CHARS]) and a minimum interval has elapsed
 *    ([LIVE_REFRESH_MIN_INTERVAL_MS]) so a long conversation does not hammer the provider.
 *  - **Final/authoritative**: once the segment is closed and fully transcribed, regenerate from the
 *    complete durable transcript and mark the annotation final, overriding any provisional. This
 *    runs exactly once on success and is bounded to [MAX_ATTEMPTS] final attempts so a broken
 *    provider cannot spin.
 *
 * Runs strictly under the user's AI settings: when no router is configured or the configured mode
 * has no available provider (e.g. remote consent off), it does nothing and rows fall back to
 * transcript snippets.
 */
class SegmentEnrichmentWorker(
    private val annotations: FileSegmentAnnotationStore,
    private val router: AiModeRouter?,
    private val nowMs: () -> Long,
) {
    /** What, if anything, the worker should do for one segment this pass. */
    private sealed interface Plan {
        object None : Plan
        data class Generate(val text: String, val isFinal: Boolean) : Plan
    }

    /**
     * Annotates segments that are due for a live refresh or a final pass. [transcriptOf] returns the
     * durable transcript of a closed segment; [liveTextOf] returns the rolling live preview of the
     * still-open segment. Returns the ids that received fresh content this pass.
     */
    suspend fun enrich(
        segments: List<SegmentMeta>,
        transcriptOf: (String) -> SegmentTranscript?,
        liveTextOf: (String) -> String? = { null },
    ): List<String> {
        val activeRouter = router ?: return emptyList()
        if (!activeRouter.isAvailable()) return emptyList()

        val now = nowMs()
        val annotated = mutableListOf<String>()
        for (meta in segments) {
            val existing = annotations.load(meta.segmentId)
            val plan = planFor(meta, existing, transcriptOf, liveTextOf, now)
            if (plan !is Plan.Generate) continue
            if (runPlan(activeRouter, meta, existing, plan)) {
                annotated += meta.segmentId
            }
        }
        return annotated
    }

    private fun planFor(
        meta: SegmentMeta,
        existing: SegmentAnnotation?,
        transcriptOf: (String) -> SegmentTranscript?,
        liveTextOf: (String) -> String?,
        now: Long,
    ): Plan {
        // Final/authoritative pass takes precedence: a fully transcribed, closed segment.
        if (!meta.isOpen && meta.transcriptionState == TranscriptionState.Complete) {
            val durable = transcriptOf(meta.segmentId)?.text?.trim()
            if (durable.isNullOrBlank()) return Plan.None
            // Older final annotations were title/summary only. Treat tagless finals as due for
            // one structured final pass so library tags backfill automatically.
            if (existing?.isFinal == true && existing.tags.isNotEmpty()) return Plan.None
            if ((existing?.finalAttempts ?: 0) >= MAX_ATTEMPTS) return Plan.None
            return Plan.Generate(durable, isFinal = true)
        }

        // Live/provisional pass: still recording.
        if (meta.isOpen) {
            // A final annotation should never exist while open, but never downgrade it if it does.
            if (existing?.isFinal == true) return Plan.None
            val live = liveTextOf(meta.segmentId)?.trim()
            if (live.isNullOrBlank() || live.length < LIVE_MIN_CHARS) return Plan.None
            if (existing == null) return Plan.Generate(live, isFinal = false)
            val grownEnough = live.length >= existing.sourceCharCount + LIVE_REFRESH_MIN_GROWTH_CHARS
            val intervalElapsed = now - existing.createdAtMs >= LIVE_REFRESH_MIN_INTERVAL_MS
            return if (grownEnough && intervalElapsed) Plan.Generate(live, isFinal = false) else Plan.None
        }

        // Closed but not yet fully transcribed (Running/Uploading/Pending/Failed/...): keep any
        // provisional annotation and wait for the final pass.
        return Plan.None
    }

    /** Runs one generation. Returns true when fresh content was produced and stored. */
    private suspend fun runPlan(
        activeRouter: AiModeRouter,
        meta: SegmentMeta,
        existing: SegmentAnnotation?,
        plan: Plan.Generate,
    ): Boolean {
        val attempts = (existing?.attempts ?: 0) + 1
        val finalAttempts = (existing?.finalAttempts ?: 0) + if (plan.isFinal) 1 else 0
        return try {
            val result = activeRouter.run(
                AiRunRequest(
                    requestId = "annotate-${meta.segmentId}-${if (plan.isFinal) "final" else "live"}-$attempts",
                    prompt = SegmentAnnotationPrompt.forPass(live = !plan.isFinal),
                    transcripts = listOf(
                        TranscriptExcerpt(
                            segmentId = meta.segmentId,
                            text = plan.text,
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
                    tags = parsed.tags,
                    modeUsed = result.modeUsed,
                    providerId = result.providerId,
                    modelUsed = result.modelUsed,
                    createdAtMs = nowMs(),
                    attempts = attempts,
                    isFinal = plan.isFinal,
                    sourceCharCount = plan.text.length,
                    finalAttempts = finalAttempts,
                ),
            )
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Preserve any existing (provisional) content so the row does not blank out on a
            // transient failure; record the error and bump the relevant counters. The interval
            // gate (anchored on createdAtMs, which the store rewrites here) throttles live retries.
            annotations.save(
                (existing ?: SegmentAnnotation(segmentId = meta.segmentId, createdAtMs = nowMs())).copy(
                    attempts = attempts,
                    finalAttempts = finalAttempts,
                    lastError = e.message ?: e::class.simpleName,
                ),
            )
            false
        }
    }

    companion object {
        /** Bounds the authoritative final pass so a persistently failing provider cannot spin. */
        const val MAX_ATTEMPTS = 3

        /** Minimum live-transcript length before the first provisional annotation is worthwhile. */
        const val LIVE_MIN_CHARS = 120

        /** Live transcript must grow at least this much before a provisional refresh. */
        const val LIVE_REFRESH_MIN_GROWTH_CHARS = 280

        /** Minimum time between provisional refreshes for one open segment. */
        const val LIVE_REFRESH_MIN_INTERVAL_MS = 45_000L
    }
}
