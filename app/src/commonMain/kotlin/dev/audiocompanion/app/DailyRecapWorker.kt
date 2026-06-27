package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Generates one daily digest per local calendar day from closed segments. Runs on a slow interval
 * and after enrichment so the Today card and Library Days view stay current.
 */
class DailyRecapEngine(
    private val scope: CoroutineScope,
    private val segmentStore: SegmentStore,
    private val transcriptStore: FileTranscriptStore,
    private val digestStore: FileDailyDigestStore,
    private val aiRouter: AiModeRouter?,
    private val zoneId: ZoneId = ZoneId.systemDefault(),
    private val nowMs: () -> Long = { System.currentTimeMillis() },
    private val intervalMs: Long = 15 * 60 * 1000L,
) {
    private var job: Job? = null

    fun start() {
        if (job != null) return
        job = scope.launch {
            while (isActive) {
                runCatching { generateMissingDigests() }
                delay(intervalMs)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }

    suspend fun generateMissingDigests() {
        val router = aiRouter ?: return
        val metas = segmentStore.listSegments().filter { !it.isOpen }
        val byDay = metas.groupBy { dayKey(it.startTimeMs.toLong()) }
        for ((day, segments) in byDay) {
            if (digestStore.load(day) != null) continue
            val excerpts = segments.mapNotNull { meta ->
                val text = transcriptStore.load(meta.segmentId)?.text?.trim()
                if (text.isNullOrBlank()) return@mapNotNull null
                TranscriptExcerpt(
                    segmentId = meta.segmentId,
                    text = text,
                    startTimeMs = meta.startTimeMs.toLong(),
                )
            }
            if (excerpts.isEmpty()) continue
            val result = router.run(
                AiRunRequest(
                    requestId = "digest-${day}-${nowMs()}",
                    prompt = AiPromptTemplates.DailySummary,
                    transcripts = excerpts,
                ),
            )
            digestStore.save(
                DailyDigest(
                    dateKey = day,
                    text = result.text.trim(),
                    segmentIds = excerpts.map { it.segmentId },
                    modeUsed = result.modeUsed,
                    providerId = result.providerId,
                    modelUsed = result.modelUsed,
                    inputTokens = result.inputTokens,
                    outputTokens = result.outputTokens,
                    createdAtMs = nowMs(),
                ),
            )
        }
    }

    private fun dayKey(startMs: Long): String =
        Instant.ofEpochMilli(startMs).atZone(zoneId).format(DateTimeFormatter.ISO_LOCAL_DATE)
}
