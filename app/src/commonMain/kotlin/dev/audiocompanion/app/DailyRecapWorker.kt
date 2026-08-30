package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.minus
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Clock

/**
 * Recap days roll over at 5 AM local time, not midnight, so a late night keeps its evening
 * context on the Today recap instead of vanishing into "yesterday" exactly at 12:00 AM.
 */
object LogicalDay {
    const val ROLLOVER_HOUR = 5

    /** Digest date key ("YYYY-MM-DD") of the logical day containing [epochMs]. */
    fun keyFor(epochMs: Long, timeZone: TimeZone): String {
        val local = Instant.fromEpochMilliseconds(epochMs).toLocalDateTime(timeZone)
        val date = if (local.hour < ROLLOVER_HOUR) local.date.minus(1, DateTimeUnit.DAY) else local.date
        return date.toString()
    }
}

/**
 * Keeps one rolling AI digest per logical day (5 AM - 5 AM) built from closed, transcribed
 * segments. A day's digest regenerates whenever new transcripts land for it - debounced to
 * [minRefreshIntervalMs] - so the Today recap follows the day instead of freezing on the first
 * conversation of the morning. Runs on a slow interval and after transcription/enrichment passes.
 */
class DailyRecapEngine(
    private val listSegments: () -> List<SegmentMeta>,
    private val transcriptTextOf: (String) -> String?,
    private val digestStore: FileDailyDigestStore,
    private val aiRouter: AiModeRouter?,
    /** Receives every digest write so callers can fan it out (diagnostics, search index). */
    private val onDigestSaved: suspend (DailyDigest) -> Unit = {},
    private val timeZone: TimeZone = TimeZone.currentSystemDefault(),
    private val nowMs: () -> Long = { Clock.System.now().toEpochMilliseconds() },
    private val intervalMs: Long = 15 * 60 * 1000L,
    private val minRefreshIntervalMs: Long = 30 * 60 * 1000L,
) {
    private var job: Job? = null
    private val refreshMutex = Mutex()

    /**
     * Days whose segment set was fully handled by a previous pass (digest current, or nothing
     * usable yet). Lets the steady-state pass skip per-day digest/transcript reads entirely.
     */
    private val settledDays = HashMap<String, Set<Pair<String, TranscriptionState>>>()

    fun start(scope: CoroutineScope) {
        if (job != null) return
        job = scope.launch {
            while (isActive) {
                runCatching { refreshDigests() }
                delay(intervalMs)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
    }

    suspend fun refreshDigests(): Unit = refreshMutex.withLock {
        val router = aiRouter ?: return
        val byDay = listSegments()
            .filter { !it.isOpen }
            .groupBy { LogicalDay.keyFor(it.startTimeMs.toLong(), timeZone) }
        // Newest day first: the current logical day is the user-visible Today recap.
        for ((day, segments) in byDay.entries.sortedByDescending { it.key }) {
            val fingerprint = segments.mapTo(HashSet()) { it.segmentId to it.transcriptionState }
            if (settledDays[day] == fingerprint) continue
            val existing = digestStore.load(day)
            if (existing != null) {
                val covered = existing.segmentIds.toSet()
                val fresh = segments.filter { it.segmentId !in covered }
                // Only genuinely new transcript content justifies an AI rerun: segments removed
                // by retention must never churn (or degrade) an already-complete digest, and
                // no-speech segments never become content.
                if (fresh.none { !transcriptTextOf(it.segmentId).isNullOrBlank() }) {
                    settledDays[day] = fingerprint
                    continue
                }
                if (nowMs() - existing.createdAtMs < minRefreshIntervalMs) continue
            }
            val excerpts = segments
                .sortedBy { it.startTimeMs }
                .mapNotNull { meta ->
                    val text = transcriptTextOf(meta.segmentId)?.trim()
                    if (text.isNullOrBlank()) return@mapNotNull null
                    val startMs = meta.startTimeMs.toLong()
                    TranscriptExcerpt(
                        segmentId = meta.segmentId,
                        text = text,
                        startTimeMs = startMs,
                        timeLabel = timeLabel(startMs),
                    )
                }
            if (excerpts.isEmpty()) {
                settledDays[day] = fingerprint
                continue
            }
            val result = router.run(
                AiRunRequest(
                    requestId = "digest-${day}-${nowMs()}",
                    prompt = AiPromptTemplates.DailySummary,
                    transcripts = excerpts,
                ),
            )
            val saved = digestStore.save(
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
            settledDays[day] = fingerprint
            onDigestSaved(saved)
        }
    }

    private fun timeLabel(epochMs: Long): String {
        val local = Instant.fromEpochMilliseconds(epochMs).toLocalDateTime(timeZone)
        val hh = local.hour.toString().padStart(2, '0')
        val mm = local.minute.toString().padStart(2, '0')
        return "${local.date} $hh:$mm"
    }
}
