package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
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
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.AiException
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiPromptTemplates
import dev.audiocompanion.storage.SegmentMeta
import kotlinx.coroutines.launch

enum class AiScope(val label: String) {
    Today("Today"),
    All("All transcripts"),
}

@Composable
fun AiScreen(
    segments: List<SegmentMeta>,
    aiOutputs: List<AiOutput>,
    aiConfigured: Boolean,
    nowMs: Long,
    onRunAi: suspend (AiPromptTemplate, List<String>) -> Result<AiOutput>,
    onDeleteOutput: (String) -> Unit,
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
        )
        return
    }

    var scope by rememberSaveable { mutableStateOf(AiScope.Today) }
    var customPrompt by rememberSaveable { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

    val transcribedSegmentIds = remember(segments, scope, nowMs) {
        segments
            .filter { !it.isOpen }
            .filter { scope == AiScope.All || Formatting.isSameLocalDay(it.receivedAtMs, nowMs) }
            .map { it.segmentId }
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
                    errorMessage = when (e) {
                        is AiException.ConsentRequired ->
                            "Remote AI is off. Enable it in Settings or switch to a local mode."
                        is AiException.ProviderUnavailable ->
                            "No AI provider is available. Check Settings -> AI."
                        else -> e.message ?: "AI processing failed."
                    }
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

        SectionTitle("Scope")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AiScope.entries.forEach { candidate ->
                FilterChip(
                    selected = scope == candidate,
                    onClick = { scope = candidate },
                    label = { Text(candidate.label) },
                )
            }
        }
        Text(
            text = "${transcribedSegmentIds.size} segment${if (transcribedSegmentIds.size == 1) "" else "s"} in scope",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        SectionTitle("Templates")
        AiPromptTemplates.builtIn.forEach { template ->
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
            label = { Text("Ask about the selected transcripts") },
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

@Composable
private fun AiOutputDetail(
    output: AiOutput,
    nowMs: Long,
    onBack: () -> Unit,
    onDelete: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
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
        Text(
            text = output.text,
            style = MaterialTheme.typography.bodyMedium,
        )
        SectionTitle("Provenance")
        InfoRow("Created", Formatting.relativeTime(output.createdAtMs, nowMs))
        InfoRow("Provider", output.providerId + (output.modelUsed?.let { " ($it)" } ?: ""))
        InfoRow("Mode used", output.modeUsed.toString())
        InfoRow("Source segments", output.segmentIds.size.toString())
        output.inputTokens?.let { InfoRow("Input tokens", it.toString()) }
        output.outputTokens?.let { InfoRow("Output tokens", it.toString()) }
        InfoRow("Sent to remote provider", if (output.userConsentedToRemote) "Yes (with consent)" else "No")

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
