package dev.audiocompanion.app

import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.ai.AiRunRequest
import dev.audiocompanion.ai.FileRuleStore
import dev.audiocompanion.ai.Rule
import dev.audiocompanion.ai.RuleActionKind
import dev.audiocompanion.ai.RuleRun
import dev.audiocompanion.ai.RuleTriggerKind
import dev.audiocompanion.ai.TranscriptExcerpt
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptStore
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.atStartOfDayIn
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Clock

/**
 * Evaluates user-authored rules against durable transcripts with cost controls (M7).
 */
class RuleEvaluator(
    private val ruleStore: FileRuleStore,
    private val segmentStore: SegmentStore,
    private val transcriptStore: FileTranscriptStore,
    private val aiRouter: AiModeRouter?,
    private val timeZone: TimeZone = TimeZone.currentSystemDefault(),
    private val nowMs: () -> Long = { Clock.System.now().toEpochMilliseconds() },
) {
    suspend fun evaluateDueRules(): List<RuleRun> {
        val router = aiRouter ?: return emptyList()
        val rules = ruleStore.listRules().filter { it.enabled }
        val results = mutableListOf<RuleRun>()
        for (rule in rules) {
            if (!isTriggerDue(rule)) continue
            if (!withinCostLimits(rule)) {
                results += recordRun(rule, success = false, message = "Cost limit reached for today")
                continue
            }
            if (isQuietHours(rule)) {
                results += recordRun(rule, success = false, message = "Quiet hours")
                continue
            }
            val excerpts = loadExcerpts()
            if (excerpts.isEmpty()) {
                results += recordRun(rule, success = false, message = "No transcripts")
                continue
            }
            when (rule.action.kind) {
                RuleActionKind.RunTemplate -> {
                    val template = AiPromptTemplates.builtIn.find { it.id == rule.action.templateId }
                        ?: AiPromptTemplates.DailySummary
                    val result = router.run(
                        AiRunRequest(
                            requestId = "rule-${rule.id}-${nowMs()}",
                            prompt = template,
                            transcripts = excerpts,
                        ),
                    )
                    results += recordRun(
                        rule,
                        success = true,
                        message = "Completed",
                        inputTokens = result.inputTokens,
                        outputTokens = result.outputTokens,
                    )
                }
                RuleActionKind.Export, RuleActionKind.Webhook -> {
                    results += recordRun(
                        rule,
                        success = false,
                        message = "Action preview only — explicit user confirmation required",
                    )
                }
            }
        }
        return results
    }

    private fun isTriggerDue(rule: Rule): Boolean =
        when (rule.trigger.kind) {
            RuleTriggerKind.Manual -> false
            RuleTriggerKind.TimeOfDay -> {
                val now = localMinuteOfDay(nowMs())
                val target = parseMinuteOfDay(rule.trigger.value) ?: return false
                now == target
            }
            RuleTriggerKind.Keyword, RuleTriggerKind.MeetingWindow -> false
        }

    private fun withinCostLimits(rule: Rule): Boolean {
        val todayRuns = ruleStore.listRuns(rule.id)
            .count { it.success && it.startedAtMs >= startOfLocalDayMs() }
        return todayRuns < rule.costLimits.maxRunsPerDay
    }

    private fun isQuietHours(rule: Rule): Boolean {
        val start = rule.costLimits.quietHoursStart
        val end = rule.costLimits.quietHoursEnd
        if (start.isNullOrBlank() || end.isNullOrBlank()) return false
        val now = localMinuteOfDay(nowMs())
        val startMinute = parseMinuteOfDay(start) ?: return false
        val endMinute = parseMinuteOfDay(end) ?: return false
        return if (startMinute <= endMinute) {
            now in (startMinute + 1) until endMinute
        } else {
            now > startMinute || now < endMinute
        }
    }

    private fun loadExcerpts(): List<TranscriptExcerpt> =
        segmentStore.listSegments()
            .filter { !it.isOpen }
            .mapNotNull { meta ->
                transcriptStore.load(meta.segmentId)?.text?.trim()?.takeIf { it.isNotBlank() }?.let { text ->
                    TranscriptExcerpt(
                        segmentId = meta.segmentId,
                        text = text,
                        startTimeMs = meta.startTimeMs.toLong(),
                    )
                }
            }

    private fun startOfLocalDayMs(): Long {
        val today = Instant.fromEpochMilliseconds(nowMs()).toLocalDateTime(timeZone).date
        return today.atStartOfDayIn(timeZone).toEpochMilliseconds()
    }

    private fun localMinuteOfDay(epochMs: Long): Int {
        val time = Instant.fromEpochMilliseconds(epochMs).toLocalDateTime(timeZone).time
        return time.hour * 60 + time.minute
    }

    private fun parseMinuteOfDay(value: String): Int? {
        val parts = value.split(":")
        if (parts.size != 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].toIntOrNull() ?: return null
        if (hour !in 0..23 || minute !in 0..59) return null
        return hour * 60 + minute
    }

    private fun recordRun(
        rule: Rule,
        success: Boolean,
        message: String,
        inputTokens: Int? = null,
        outputTokens: Int? = null,
    ): RuleRun {
        val started = nowMs()
        return ruleStore.saveRun(
            RuleRun(
                id = "run-$started",
                ruleId = rule.id,
                startedAtMs = started,
                finishedAtMs = nowMs(),
                success = success,
                message = message,
                inputTokens = inputTokens,
                outputTokens = outputTokens,
            ),
        )
    }
}
