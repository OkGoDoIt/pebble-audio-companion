package dev.audiocompanion.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.audiocompanion.app.PlaybackUiState
import dev.audiocompanion.transcription.SegmentTranscript
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

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun AiScreen(
    segments: List<SegmentMeta>,
    aiOutputs: List<AiOutput>,
    aiConfigured: Boolean,
    nowMs: Long,
    transcriptOf: (String) -> SegmentTranscript? = { null },
    playback: PlaybackUiState = PlaybackUiState(),
    dailyDigests: List<DailyDigest> = emptyList(),
    actionItems: List<ActionItem> = emptyList(),
    customTemplates: List<SavedAiTemplate> = emptyList(),
    selectedSegmentIds: List<String> = emptyList(),
    // Output selection is lifted to the host so other tabs (e.g. a Library "Related AI output"
    // tap) can deep-link straight to a specific saved output.
    selectedOutputId: String? = null,
    onSelectOutput: (String?) -> Unit = {},
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
    onPlaySegment: (String) -> Unit = {},
    onPausePlayback: () -> Unit = {},
    onRefresh: () -> Unit,
) {
    val selectedOutput = selectedOutputId?.let { id -> aiOutputs.firstOrNull { it.outputId == id } }
    if (selectedOutput != null) {
        // System back / iOS edge swipe-back pops this AI answer back to the list (see App.kt).
        BackHandler { onSelectOutput(null) }
        AiOutputDetail(
            output = selectedOutput,
            nowMs = nowMs,
            segments = segments,
            transcriptOf = transcriptOf,
            playback = playback,
            onBack = { onSelectOutput(null) },
            onDelete = {
                onDeleteOutput(selectedOutput.outputId)
                onSelectOutput(null)
            },
            onRegenerate = { template, segmentIds ->
                onRunAi(template, segmentIds)
            },
            onUpdate = onUpdateOutput,
            onShareText = onShareText,
            onExportText = onExportText,
            onOpenSegment = onOpenSegment,
            onPlaySegment = onPlaySegment,
            onPausePlayback = onPausePlayback,
        )
        return
    }

    var scope by rememberSaveable { mutableStateOf(AiScope.Today) }
    var customPrompt by rememberSaveable { mutableStateOf("") }
    var askQuestion by rememberSaveable { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()
    LaunchedEffect(selectedSegmentIds) {
        if (selectedSegmentIds.isNotEmpty()) scope = AiScope.Selected
    }

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
                    onSelectOutput(output.outputId)
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
            .padding(horizontal = Spacing.screenH),
        verticalArrangement = Arrangement.spacedBy(Spacing.tight),
    ) {
        ScreenTitle("AI")

        if (!aiConfigured) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.medium,
                color = StatusColors.warning.copy(alpha = 0.10f),
                border = BorderStroke(1.dp, StatusColors.warning.copy(alpha = 0.25f)),
            ) {
                Text(
                    text = "Set up AI in Settings: choose a processing mode and, for remote AI, " +
                        "enable consent and add a provider key.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(12.dp),
                )
            }
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
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = MaterialTheme.shapes.medium,
            color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        ) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(Spacing.tight),
            ) {
                OutlinedTextField(
                    value = askQuestion,
                    onValueChange = { askQuestion = it },
                    placeholder = { Text("Ask anything about these transcripts") },
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    suggestedQuestions(scope).forEach { question ->
                        AssistChip(onClick = { askQuestion = question }, label = { Text(question) })
                    }
                }
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
                                    onSelectOutput(output.outputId)
                                },
                                onFailure = { e -> errorMessage = aiErrorMessage(e) },
                            )
                        }
                    },
                    enabled = !running && askQuestion.isNotBlank() && transcribedSegmentIds.isNotEmpty(),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Ask")
                }
            }
        }

        SectionTitle("Scope")
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
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
            text = "${transcribedSegmentIds.size} segment${if (transcribedSegmentIds.size == 1) "" else "s"} in scope" +
                if (scope == AiScope.Selected && selectedSegmentIds.isNotEmpty()) " · ${selectedSegmentIds.size} selected" else "",
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
                shape = MaterialTheme.shapes.medium,
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(text = template.title, style = MaterialTheme.typography.titleMedium)
                        Text(
                            text = template.userPrompt,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
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
                        .clickable { onSelectOutput(output.outputId) },
                    shape = MaterialTheme.shapes.medium,
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(text = output.promptTitle, style = MaterialTheme.typography.titleMedium)
                            Text(
                                text = "${Formatting.relativeTime(output.createdAtMs, nowMs)} · " +
                                    "${output.segmentIds.size} segment${if (output.segmentIds.size == 1) "" else "s"}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        )
                    }
                }
            }
        }
    }
}

private fun suggestedQuestions(scope: AiScope): List<String> =
    when (scope) {
        AiScope.Selected -> listOf(
            "What were the main points?",
            "What needs follow-up?",
            "What decisions were made?",
        )
        AiScope.Today -> listOf(
            "What did I talk about today?",
            "What needs follow-up?",
            "What changed since this morning?",
        )
        AiScope.All, AiScope.DateRange -> listOf(
            "Find related conversations",
            "What commitments are still open?",
            "Summarize the recurring themes",
        )
    }

private fun aiErrorMessage(e: Throwable): String =
    when (e) {
        is AiException.ConsentRequired ->
            "Remote AI is off. Enable it in Settings or switch to a local mode."
        is AiException.ProviderUnavailable ->
            "No AI provider is available. Check Settings -> AI."
        else -> e.message ?: "AI processing failed."
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AiOutputDetail(
    output: AiOutput,
    nowMs: Long,
    segments: List<SegmentMeta>,
    transcriptOf: (String) -> SegmentTranscript?,
    playback: PlaybackUiState,
    onBack: () -> Unit,
    onDelete: () -> Unit,
    onRegenerate: suspend (AiPromptTemplate, List<String>) -> Result<AiOutput>,
    onUpdate: (String, String) -> Unit,
    onShareText: (String, String) -> Unit,
    onExportText: suspend (String, String) -> Result<String>,
    onOpenSegment: (String) -> Unit,
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var editText by remember(output.text) { mutableStateOf(output.text) }
    // The moment a tapped citation points at; non-null drives the verify-in-place evidence sheet.
    var evidenceSegmentId by remember { mutableStateOf<String?>(null) }
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    val metaById = remember(segments) { segments.associateBy { it.segmentId } }

    val answer = remember(output.text, output.segmentIds) {
        parseGroundedAnswer(output.text, output.segmentIds)
    }
    // Cited moments lead. When an answer made no inline citations (e.g. a Daily summary), fall back
    // to the full source set so provenance stays visible and honest.
    val sourceList = answer.citedSegmentIds.ifEmpty { output.segmentIds }
    val numbered = answer.citedSegmentIds.isNotEmpty()

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
            NavBackButton(label = "AI", onClick = onBack)
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
            GroundedAnswerView(
                answer = answer,
                onTapCitation = { evidenceSegmentId = it.segmentId },
            )
            if (sourceList.isNotEmpty()) {
                SourcesSection(
                    sources = sourceList,
                    numbered = numbered,
                    metaOf = { metaById[it] },
                    transcriptOf = transcriptOf,
                    nowMs = nowMs,
                    onTapSource = { evidenceSegmentId = it },
                )
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

    val evidenceId = evidenceSegmentId
    if (evidenceId != null) {
        ModalBottomSheet(
            onDismissRequest = { evidenceSegmentId = null },
            sheetState = rememberModalBottomSheetState(),
        ) {
            EvidenceSheet(
                segmentId = evidenceId,
                number = sourceList.indexOf(evidenceId).takeIf { it >= 0 && numbered }?.plus(1),
                meta = metaById[evidenceId],
                transcript = transcriptOf(evidenceId),
                playback = playback,
                nowMs = nowMs,
                onPlay = onPlaySegment,
                onPause = onPausePlayback,
                onOpenInLibrary = {
                    evidenceSegmentId = null
                    onOpenSegment(evidenceId)
                },
            )
        }
    }
}

/**
 * Renders the answer as clean prose with inline, tappable citation chips placed exactly where each
 * claim is made — the chip number ties back to the "Based on" list and the evidence sheet.
 */
@Composable
private fun GroundedAnswerView(
    answer: GroundedAnswer,
    onTapCitation: (AnswerToken.Citation) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        answer.lines.forEach { line ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (line.marker != null) {
                    Text(
                        text = line.marker,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                AnswerLineText(
                    line = line,
                    modifier = Modifier.weight(1f),
                    onTapCitation = onTapCitation,
                )
            }
        }
    }
}

@Composable
private fun AnswerLineText(
    line: AnswerLine,
    modifier: Modifier = Modifier,
    onTapCitation: (AnswerToken.Citation) -> Unit,
) {
    val inlineContent = LinkedHashMap<String, InlineTextContent>()
    val annotated = buildAnnotatedString {
        line.tokens.forEachIndexed { index, token ->
            when (token) {
                is AnswerToken.Span -> append(basicMarkdown(token.text))
                is AnswerToken.Citation -> {
                    val id = "cite$index"
                    val digits = token.number.toString().length
                    inlineContent[id] = InlineTextContent(
                        Placeholder(
                            width = (15 + digits * 7).sp,
                            height = 16.sp,
                            placeholderVerticalAlign = PlaceholderVerticalAlign.Center,
                        ),
                    ) {
                        CitationChip(number = token.number, onClick = { onTapCitation(token) })
                    }
                    append(" ") // thin space so the chip doesn't crowd the preceding word
                    appendInlineContent(id, "[${token.number}]")
                }
            }
        }
    }
    Text(
        text = annotated,
        inlineContent = inlineContent,
        modifier = modifier,
        style = MaterialTheme.typography.bodyMedium,
    )
}

@Composable
private fun CitationChip(number: Int, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(5.dp))
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.14f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = number.toString(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

/**
 * Honest, human provenance: "Based on N moments · 1:50–2:38 PM", expandable into a chronological
 * list of the actual source moments (numbered to match the inline chips), each opening the same
 * evidence sheet. Replaces the old grid of opaque segment-id buttons.
 */
@Composable
private fun SourcesSection(
    sources: List<String>,
    numbered: Boolean,
    metaOf: (String) -> SegmentMeta?,
    transcriptOf: (String) -> SegmentTranscript?,
    nowMs: Long,
    onTapSource: (String) -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val metas = remember(sources) { sources.mapNotNull(metaOf) }
    val span = remember(metas, nowMs) { momentsSpanLabel(metas, nowMs) }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Based on ${sources.size} moment${if (sources.size == 1) "" else "s"}",
                        style = MaterialTheme.typography.titleSmall,
                    )
                    span?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = if (expanded) "Hide sources" else "Show sources",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (expanded) {
                sources.forEachIndexed { index, segmentId ->
                    SourceRow(
                        number = if (numbered) index + 1 else null,
                        meta = metaOf(segmentId),
                        transcript = transcriptOf(segmentId),
                        nowMs = nowMs,
                        onClick = { onTapSource(segmentId) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SourceRow(
    number: Int?,
    meta: SegmentMeta?,
    transcript: SegmentTranscript?,
    nowMs: Long,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (number != null) {
            NumberBadge(number)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = if (meta != null) momentLabel(meta, nowMs) else "Moment",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = transcriptSnippet(transcript?.text) ?: "No transcript yet",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        )
    }
}

@Composable
private fun NumberBadge(number: Int, large: Boolean = false) {
    Box(
        modifier = Modifier
            .size(if (large) 30.dp else 22.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = number.toString(),
            style = if (large) MaterialTheme.typography.titleSmall else MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

/**
 * The verify-in-place sheet: when you tap a citation you see *when* it was, the actual words, and a
 * one-tap way to hear that exact moment — without leaving the answer or losing your place.
 */
@Composable
private fun EvidenceSheet(
    segmentId: String,
    number: Int?,
    meta: SegmentMeta?,
    transcript: SegmentTranscript?,
    playback: PlaybackUiState,
    nowMs: Long,
    onPlay: (String) -> Unit,
    onPause: () -> Unit,
    onOpenInLibrary: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (number != null) NumberBadge(number, large = true)
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (meta != null) momentLabel(meta, nowMs) else "This moment",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = "Captured moment" +
                        (meta?.let { " · ${Formatting.relativeTime(it.receivedAtMs, nowMs)}" } ?: ""),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        val missingMs = meta?.gaps
            ?.sumOf { it.missingFrameCount.toLong() * meta.frameDurationMs } ?: 0L
        if (missingMs > 0L) {
            Text(
                text = "Some audio was missing here — this moment may be incomplete.",
                style = MaterialTheme.typography.bodySmall,
                color = StatusColors.warning,
            )
        }

        val quote = transcript?.text?.trim()
        if (!quote.isNullOrBlank()) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
            ) {
                Text(
                    text = quote,
                    modifier = Modifier
                        .heightIn(max = 220.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(14.dp),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        } else {
            Text(
                text = "This moment hasn't been transcribed yet. You can still play it or open it " +
                    "in Library.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        val isPlayingThis = playback.segmentId == segmentId && playback.playing
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilledTonalButton(onClick = { if (isPlayingThis) onPause() else onPlay(segmentId) }) {
                Icon(
                    imageVector = if (isPlayingThis) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = if (isPlayingThis) "Pause" else "Play this moment",
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
            TextButton(onClick = onOpenInLibrary) { Text("Open in Library") }
        }
    }
}

/** "Today, 2:14 PM" or "Jun 28, 2:14 PM" — the human identity of a captured moment. */
private fun momentLabel(meta: SegmentMeta, nowMs: Long): String {
    val time = Formatting.timeOfDay(meta.receivedAtMs)
    return if (Formatting.isSameLocalDay(meta.receivedAtMs, nowMs)) {
        "Today, $time"
    } else {
        "${Formatting.shortDate(meta.receivedAtMs, nowMs)}, $time"
    }
}

/** "Today · 1:50 – 2:38 PM" for the "Based on" header; null when there are no dated moments. */
private fun momentsSpanLabel(metas: List<SegmentMeta>, nowMs: Long): String? {
    if (metas.isEmpty()) return null
    val times = metas.map { it.receivedAtMs }.sorted()
    val first = times.first()
    val last = times.last()
    return if (Formatting.isSameLocalDay(first, last)) {
        val day = if (Formatting.isSameLocalDay(first, nowMs)) "Today" else Formatting.shortDate(first, nowMs)
        if (first == last) "$day · ${Formatting.timeOfDay(first)}"
        else "$day · ${Formatting.timeOfDay(first)} – ${Formatting.timeOfDay(last)}"
    } else {
        "${Formatting.shortDate(first, nowMs)} – ${Formatting.shortDate(last, nowMs)}"
    }
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
