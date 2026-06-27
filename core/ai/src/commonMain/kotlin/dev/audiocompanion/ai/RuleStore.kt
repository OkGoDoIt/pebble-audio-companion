package dev.audiocompanion.ai

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
enum class RuleTriggerKind {
    TimeOfDay,
    Keyword,
    MeetingWindow,
    Manual,
}

@Serializable
enum class RuleActionKind {
    RunTemplate,
    Export,
    Webhook,
}

@Serializable
data class RuleTrigger(
    val kind: RuleTriggerKind,
    /** Time-of-day: "HH:mm" local; keyword: search term; meeting: calendar window id. */
    val value: String = "",
)

@Serializable
data class RuleAction(
    val kind: RuleActionKind,
    val templateId: String? = null,
    val webhookUrl: String? = null,
)

@Serializable
data class RuleCostLimits(
    val maxRunsPerDay: Int = 3,
    val maxInputTokensPerRun: Int = 8000,
    val quietHoursStart: String? = null,
    val quietHoursEnd: String? = null,
)

@Serializable
data class Rule(
    val id: String,
    val name: String,
    val trigger: RuleTrigger,
    val condition: String = "transcripts-exist",
    val action: RuleAction,
    val enabled: Boolean = true,
    val costLimits: RuleCostLimits = RuleCostLimits(),
    val createdAtMs: Long,
)

@Serializable
data class RuleRun(
    val id: String,
    val ruleId: String,
    val startedAtMs: Long,
    val finishedAtMs: Long? = null,
    val success: Boolean = false,
    val message: String? = null,
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
)

class FileRuleStore(
    private val fileSystem: FileSystem,
    root: Path,
    private val nowMs: () -> Long,
) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val ruleDir = Path(Path(root, "ai"), "rules")
    private val runDir = Path(Path(root, "ai"), "rule_runs")

    fun saveRule(rule: Rule): Rule {
        val stamped = if (rule.createdAtMs == 0L) rule.copy(createdAtMs = nowMs()) else rule
        writeRule(stamped)
        return stamped
    }

    fun listRules(): List<Rule> =
        if (!fileSystem.exists(ruleDir)) emptyList()
        else fileSystem.list(ruleDir)
            .filter { it.name.endsWith(RULE_SUFFIX) }
            .mapNotNull { loadRule(it.name.removeSuffix(RULE_SUFFIX)) }

    fun loadRule(id: String): Rule? {
        val p = Path(ruleDir, "$id$RULE_SUFFIX")
        if (!fileSystem.exists(p)) return null
        val text = fileSystem.source(p).buffered().use { it.readByteArray() }.decodeToString()
        return runCatching { json.decodeFromString(Rule.serializer(), text) }.getOrNull()
    }

    fun deleteRule(id: String) {
        fileSystem.delete(Path(ruleDir, "$id$RULE_SUFFIX"), mustExist = false)
    }

    fun deleteAll() {
        if (fileSystem.exists(ruleDir)) {
            fileSystem.list(ruleDir)
                .filter { it.name.endsWith(RULE_SUFFIX) || it.name.endsWith("$RULE_SUFFIX.tmp") }
                .forEach { fileSystem.delete(it, mustExist = false) }
        }
        if (fileSystem.exists(runDir)) {
            fileSystem.list(runDir)
                .filter { it.name.endsWith(RUN_SUFFIX) || it.name.endsWith("$RUN_SUFFIX.tmp") }
                .forEach { fileSystem.delete(it, mustExist = false) }
        }
    }

    fun saveRun(run: RuleRun): RuleRun {
        writeRun(run)
        return run
    }

    fun listRuns(ruleId: String? = null): List<RuleRun> =
        if (!fileSystem.exists(runDir)) emptyList()
        else fileSystem.list(runDir)
            .filter { it.name.endsWith(RUN_SUFFIX) }
            .mapNotNull { entry ->
                val text = fileSystem.source(entry).buffered().use { it.readByteArray() }.decodeToString()
                runCatching { json.decodeFromString(RuleRun.serializer(), text) }.getOrNull()
            }
            .filter { ruleId == null || it.ruleId == ruleId }
            .sortedByDescending { it.startedAtMs }

    private fun writeRule(rule: Rule) {
        fileSystem.createDirectories(ruleDir)
        val tmp = Path(ruleDir, "${rule.id}$RULE_SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(Rule.serializer(), rule).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, Path(ruleDir, "${rule.id}$RULE_SUFFIX"))
    }

    private fun writeRun(run: RuleRun) {
        fileSystem.createDirectories(runDir)
        val tmp = Path(runDir, "${run.id}$RUN_SUFFIX.tmp")
        fileSystem.sink(tmp).buffered().use { sink ->
            sink.write(json.encodeToString(RuleRun.serializer(), run).encodeToByteArray())
        }
        fileSystem.atomicMove(tmp, Path(runDir, "${run.id}$RUN_SUFFIX"))
    }

    companion object {
        const val RULE_SUFFIX = ".rule.json"
        const val RUN_SUFFIX = ".run.json"
    }
}
