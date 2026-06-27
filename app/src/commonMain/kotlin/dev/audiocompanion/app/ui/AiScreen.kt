package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.FileCustomTemplateStore
import dev.audiocompanion.ai.SavedAiTemplate
import dev.audiocompanion.storage.SegmentMeta
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

enum class AiScope(val label: String) {
    Today("Today"),
    All("All"),
    DateRange("Date range"),
    Selected("Selected"),
}

@Composable
fun AiScreen(
    segments: List<SegmentMeta>,
    aiOutputs: List<AiOutput>,
    aiConfigured: Boolean,
    nowMs: Long,
    dailyDigests: List<DailyDigest> = emptyList(),
    actionItems: List<ActionItem> = emptyList(),
    customTemplates: List<SavedAiTemplate> = emptyList(),
    selectedSegmentIds: List<String> = emptyList(),
    onRunAi: suspend (AiPromptTemplate, List<String>) -> Result<AiOutput>,
    onRunAsk: suspend (String, List<String>) -> Result<AiOutput> = { _, _ ->
        Result.failure(AiException.ProviderUnavailable("not wired"))
    },
    onDeleteOutput: (String) -> Unit,
    onUpdateOutput: (String, String) -> Unit = { _, _ -> },
    onShareText: (String, String) -> Unit = { _, _ -> },
    onExportText: suspend (String, String) -> Result<String> = { _, _ ->
        Result.failure(IllegalStateException("not wired"))
    },
    onSetActionItemDone: (String, Boolean) -> Unit = { _, _ -> },
    onOpenSegment: (String) -> Unit = {},
    onRefresh: () -> Unit,
) {
    var selectedOutputId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedOutput = selectedOutputId?.let { id -> aiOutputs.firstOrNull { it.outputId == id } }
    if (selectedOutput != null) {
        AiOutputDetail(
            output = selectedOutput,
            nowMs = nowMs,
            onBack = { selectedOutputId = null },
            onDelete = {
                onDeleteOutput(selectedOutput.outputId)
                selectedOutputId = null
            },
            onRegenerate = { template, segmentIds ->
                onRunAi(template, segmentIds)
            },
            onUpdate = onUpdateOutput,
            onShareText = onShareText,
            onExportText = onExportText,
            onOpenSegment = onOpenSegment,
        )
        return
    }

    var scope by rememberSaveable { mutableStateOf(AiScope.Today) }
    var customPrompt by rememberSaveable { mutableStateOf("") }
    var askQuestion by rememberSaveable { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

    val transcribedSegmentIds = remember(segments, scope, nowMs, selectedSegmentIds) {
        val closed = segments.filter { !it.isOpen }
        when (scope) {
            AiScope.All -> closed.map { it.segmentId }
            AiScope.Today -> closed
                .filter { Formatting.isSameLocalDay(it.receivedAtMs, nowMs) }
                .map { it.segmentId }
            AiScope.Selected -> selectedSegmentIds.filter { id -> closed.any { it.segmentId == id } }
            AiScope.DateRange -> closed.map { it.segmentId }
        }
    }

    fun run(template: AiPromptTemplate) {
        if (running) return
        errorMessage = null
        running = true
        coroutineScope.launch {
            val result = onRunAi(template, transcribedSegmentIds)
            running = false
            result.fold(
                onSuccess = { output ->
                    onRefresh()
                    selectedOutputId = output.outputId
                },
                onFailure = { e ->
                    errorMessage = aiErrorMessage(e)
                },
            )
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "AI",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(top = 16.dp),
        )

        if (!aiConfigured) {
            Text(
                text = "Set up AI in Settings: choose a processing mode and, for remote AI, " +
                    "enable consent and add a provider key.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (actionItems.isNotEmpty()) {
            SectionTitle("Action items")
            actionItems.take(8).forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = item.done,
                        onCheckedChange = { onSetActionItemDone(item.id, it) },
                    )
                    Text(
                        text = item.text,
                        modifier = Modifier
                            .weight(1f)
                            .clickable { onOpenSegment(item.sourceSegmentId) },
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }

        SectionTitle("Ask")
        OutlinedTextField(
            value = askQuestion,
            onValueChange = { askQuestion = it },
            label = { Text("Question about selected transcripts") },
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = {
                if (running || askQuestion.isBlank()) return@Button
                running = true
                coroutineScope.launch {
                    val result = onRunAsk(askQuestion, transcribedSegmentIds)
                    running = false
                    result.fold(
                        onSuccess = { output ->
                            onRefresh()
                            selectedOutputId = output.outputId
                        },
                        onFailure = { e -> errorMessage = aiErrorMessage(e) },
                    )
                }
            },
            enabled = !running && askQuestion.isNotBlank() && transcribedSegmentIds.isNotEmpty(),
        ) {
            Text("Ask")
        }

        SectionTitle("Scope")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AiScope.entries.forEach { candidate ->
                FilterChip(
                    selected = scope == candidate,
                    onClick = { scope = candidate },
                    label = { Text(candidate.label) },
                    enabled = candidate != AiScope.Selected || selectedSegmentIds.isNotEmpty(),
                )
            }
        }
        Text(
            text = "${transcribedSegmentIds.size} segment${if (transcribedSegmentIds.size == 1) "" else "s"} in scope",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        SectionTitle("Templates")
        (AiPromptTemplates.builtIn + customTemplates.map(FileCustomTemplateStore::toAiPromptTemplate))
            .forEach { template ->
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !running && transcribedSegmentIds.isNotEmpty()) { run(template) },
            ) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(text = template.title, style = MaterialTheme.typography.bodyLarge)
                    Text(
                        text = template.userPrompt,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        SectionTitle("Custom prompt")
        OutlinedTextField(
            value = customPrompt,
            onValueChange = { customPrompt = it },
            label = { Text("Custom prompt") },
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = { run(AiPromptTemplates.custom(customPrompt)) },
            enabled = !running && customPrompt.isNotBlank() && transcribedSegmentIds.isNotEmpty(),
        ) {
            Text("Run")
        }

        if (running) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(modifier = Modifier.padding(4.dp))
                Text("Processing…", style = MaterialTheme.typography.bodyMedium)
            }
        }
        errorMessage?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }

        SectionTitle("Recent outputs")
        if (aiOutputs.isEmpty()) {
            Text(
                text = "Transcripts become AI-ready after processing. Outputs you create will " +
                    "be saved here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            aiOutputs.sortedByDescending { it.createdAtMs }.forEach { output ->
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { selectedOutputId = output.outputId },
                ) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text(text = output.promptTitle, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = "${Formatting.relativeTime(output.createdAtMs, nowMs)} · " +
                                "${output.segmentIds.size} segment${if (output.segmentIds.size == 1) "" else "s"}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

private fun aiErrorMessage(e: Throwable): String =
    when (e) {
        is AiException.ConsentRequired ->
            "Remote AI is off. Enable it in Settings or switch to a local mode."
        is AiException.ProviderUnavailable ->
            "No AI provider is available. Check Settings -> AI."
        else -> e.message ?: "AI processing failed."
    }

@Composable
private fun AiOutputDetail(
    output: AiOutput,
    nowMs: Long,
    onBack: () -> Unit,
    onDelete: () -> Unit,
    onRegenerate: suspend (AiPromptTemplate, List<String>) -> Result<AiOutput>,
    onUpdate: (String, String) -> Unit,
    onShareText: (String, String) -> Unit,
    onExportText: suspend (String, String) -> Result<String>,
    onOpenSegment: (String) -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var editText by remember(output.text) { mutableStateOf(output.text) }
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onBack) { Text("< AI") }
            TextButton(onClick = { confirmDelete = true }) {
                Text("Delete", color = MaterialTheme.colorScheme.error)
            }
        }
        Text(text = output.promptTitle, style = MaterialTheme.typography.headlineSmall)
        if (editing) {
            OutlinedTextField(
                value = editText,
                onValueChange = { editText = it },
                modifier = Modifier.fillMaxWidth(),
            )
            Button(onClick = {
                onUpdate(output.outputId, editText)
                editing = false
            }) {
                Text("Save edit")
            }
        } else {
            AiMarkdownText(output.text)
            val referencedSegments = remember(output.text, output.segmentIds) {
                referencedSegmentIds(output.text, output.segmentIds)
            }
            if (referencedSegments.isNotEmpty()) {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    referencedSegments.forEach { segmentId ->
                        AssistChip(
                            onClick = { onOpenSegment(segmentId) },
                            label = { Text(shortSegmentLabel(segmentId)) },
                        )
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = {
                clipboard.setText(AnnotatedString(output.text))
            }) { Text("Copy") }
            TextButton(onClick = { onShareText(output.text, output.promptTitle) }) { Text("Share") }
            TextButton(onClick = {
                scope.launch {
                    onExportText(output.text, "${output.promptTitle}.md")
                }
            }) { Text("Export") }
            TextButton(onClick = { editing = true }) { Text("Edit") }
            TextButton(onClick = {
                scope.launch {
                    val template = AiPromptTemplates.builtIn.find { it.id == output.promptTemplateId }
                        ?: AiPromptTemplates.custom(output.promptTitle)
                    onRegenerate(template, output.segmentIds)
                }
            }) { Text("Regenerate") }
        }
        SectionTitle("Provenance")
        InfoRow("Created", Formatting.relativeTime(output.createdAtMs, nowMs))
        output.editedAtMs?.let { InfoRow("Edited", Formatting.relativeTime(it, nowMs)) }
        InfoRow("Provider", output.providerId + (output.modelUsed?.let { " ($it)" } ?: ""))
        InfoRow("Source segments", output.segmentIds.size.toString())
        output.inputTokens?.let { InfoRow("Input tokens", it.toString()) }
        output.outputTokens?.let { InfoRow("Output tokens", it.toString()) }

        if (confirmDelete) {
            ConfirmDialog(
                title = "Delete this output?",
                body = "This deletes the AI output. Source transcripts are kept.",
                confirmLabel = "Delete",
                onConfirm = onDelete,
                onDismiss = { confirmDelete = false },
            )
        }
    }
}

@Composable
private fun AiMarkdownText(text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        markdownBlocks(text).forEach { block ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (block.marker != null) {
                    Text(
                        text = block.marker,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    text = basicMarkdown(block.text),
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

private data class MarkdownBlock(val marker: String?, val text: String)

private fun markdownBlocks(text: String): List<MarkdownBlock> =
    text.lines()
        .map { it.trimEnd() }
        .fold(mutableListOf<MarkdownBlock>()) { blocks, rawLine ->
            val line = rawLine.trim()
            when {
                line.isBlank() -> blocks
                line.startsWith("- [ ] ") ->
                    blocks += MarkdownBlock("☐", line.removePrefix("- [ ] ").trim())
                line.startsWith("- [x] ", ignoreCase = true) ->
                    blocks += MarkdownBlock("☑", line.substringAfter("] ").trim())
                line.startsWith("- ") ->
                    blocks += MarkdownBlock("•", line.removePrefix("- ").trim())
                line.matches(Regex("^\\d+[.)]\\s+.*")) -> {
                    val marker = line.substringBefore(' ').let {
                        if (it.endsWith(".") || it.endsWith(")")) it else "$it."
                    }
                    blocks += MarkdownBlock(marker, line.replaceFirst(Regex("^\\d+[.)]\\s+"), ""))
                }
                blocks.lastOrNull()?.marker != null && rawLine.startsWith("  ") -> {
                    val previous = blocks.removeAt(blocks.lastIndex)
                    blocks += previous.copy(text = previous.text + " " + line)
                }
                else -> blocks += MarkdownBlock(null, line)
            }
            blocks
        }

private fun basicMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    var index = 0
    while (index < text.length) {
        val boldStart = text.indexOf("**", index)
        val italicStart = text.indexOf("*", index).takeIf { it >= 0 && text.getOrNull(it + 1) != '*' } ?: -1
        val next = listOf(boldStart, italicStart).filter { it >= 0 }.minOrNull() ?: -1
        if (next < 0) {
            append(text.substring(index))
            break
        }
        append(text.substring(index, next))
        if (next == boldStart) {
            val end = text.indexOf("**", next + 2)
            if (end < 0) {
                append(text.substring(next))
                break
            }
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                append(text.substring(next + 2, end))
            }
            index = end + 2
        } else {
            val end = text.indexOf("*", next + 1)
            if (end < 0) {
                append(text.substring(next))
                break
            }
            withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                append(text.substring(next + 1, end))
            }
            index = end + 1
        }
    }
}

private fun referencedSegmentIds(text: String, sourceSegmentIds: List<String>): List<String> {
    val direct = Regex("\\bseg-[A-Za-z0-9_-]+\\b")
        .findAll(text)
        .map { it.value.trimEnd('.', ',', ')') }
        .toList()
    return (direct + sourceSegmentIds).distinct()
}

private fun shortSegmentLabel(segmentId: String): String =
    if (segmentId.length <= 14) segmentId else segmentId.take(8) + "…" + segmentId.takeLast(4)
