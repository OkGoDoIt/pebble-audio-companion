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
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Evaluates user-authored rules against durable transcripts with cost controls (M7).
 */
class RuleEvaluator(
    private val ruleStore: FileRuleStore,
    private val segmentStore: SegmentStore,
    private val transcriptStore: FileTranscriptStore,
    private val aiRouter: AiModeRouter?,
    private val zoneId: ZoneId = ZoneId.systemDefault(),
    private val nowMs: () -> Long = { System.currentTimeMillis() },
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
                val now = LocalTime.now(zoneId)
                val target = LocalTime.parse(rule.trigger.value, DateTimeFormatter.ofPattern("HH:mm"))
                now.hour == target.hour && now.minute == target.minute
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
        val now = LocalTime.now(zoneId)
        val startT = LocalTime.parse(start, DateTimeFormatter.ofPattern("HH:mm"))
        val endT = LocalTime.parse(end, DateTimeFormatter.ofPattern("HH:mm"))
        return now.isAfter(startT) && now.isBefore(endT)
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
        val today = java.time.LocalDate.now(zoneId)
        return today.atStartOfDay(zoneId).toInstant().toEpochMilli()
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
