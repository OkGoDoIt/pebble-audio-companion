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
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.AiModels
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.app.AudioExportResult
import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.CloudHealth
import dev.audiocompanion.app.CloudHealthStatus
import dev.audiocompanion.app.LocalTranscriptionModelOptionState
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.app.cloudTranscriptionEnabled
import dev.audiocompanion.app.cloudTranscriptionKeyConfigured
import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.CloudProvider
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transport.ReceiverSessionState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    sessionState: ReceiverSessionState,
    settings: AudioCompanionSettings,
    diagnostics: AudioCompanionDiagnostics,
    watchServiceState: Int?,
    segments: List<SegmentMeta>,
    localModel: LocalTranscriptionModelState,
    statusHeadline: String,
    exportDirectory: String?,
    cloudHealth: CloudHealth = CloudHealth(),
    actions: AppActions,
) {
    var confirmRevoke by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var showTranscriptionModePicker by remember { mutableStateOf(false) }
    var showLocalModelPicker by remember { mutableStateOf(false) }
    var showCloudProviderPicker by remember { mutableStateOf(false) }
    var showAiModePicker by remember { mutableStateOf(false) }
    var showAiModelPicker by remember { mutableStateOf(false) }
    var supportReportText by remember { mutableStateOf<String?>(null) }
    var detailedDiagnosticsText by remember { mutableStateOf<String?>(null) }
    var exportResultText by remember { mutableStateOf<String?>(null) }
    var exportingAll by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = "Settings",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(top = 16.dp),
        )

        SectionTitle("Watch")
        InfoRow("Status", statusHeadline)
        InfoRow("Watch reports", watchServiceStateLabel(watchServiceState))
        SettingsToggleRow(
            title = "Background audio",
            subtitle = "Receive and store watch audio, including while this app is in the background.",
            checked = settings.backgroundReceiverEnabled,
            onCheckedChange = actions.setBackgroundReceiverEnabled,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = actions.pairWatch) { Text("Find Watch") }
            if (sessionState == ReceiverSessionState.Disconnected && settings.backgroundReceiverEnabled) {
                OutlinedButton(onClick = actions.startReceiver) { Text("Reconnect") }
            }
        }
        TextButton(onClick = { confirmRevoke = true }) {
            Text("Revoke receiver", color = MaterialTheme.colorScheme.error)
        }
        HorizontalDivider()

        SectionTitle("Storage & Retention")
        InfoRow("Stored segments", diagnostics.segmentCount.toString())
        InfoRow("Free phone storage", Formatting.storageSize(diagnostics.freeStorageHintKb.toLong() * 1024))
        InfoRow("Export folder", exportDirectory ?: "Unavailable")
        if (diagnostics.lowStorage) {
            Text(
                text = "Phone storage is low. Receiving will pause if it drops further.",
                style = MaterialTheme.typography.bodySmall,
                color = StatusColors.warning,
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedButton(onClick = {
                actions.setRetentionDays((settings.retentionDays - 7).coerceAtLeast(1))
            }) { Text("-") }
            Text(
                text = "Keep audio ${settings.retentionDays} days",
                style = MaterialTheme.typography.bodyMedium,
            )
            OutlinedButton(onClick = {
                actions.setRetentionDays((settings.retentionDays + 7).coerceAtMost(365))
            }) { Text("+") }
        }
        TextButton(onClick = { confirmDeleteAll = true }) {
            Text("Delete all local data", color = MaterialTheme.colorScheme.error)
        }
        SettingsToggleRow(
            title = "Auto-export WAV files",
            subtitle = "Write normal audio files for closed segments into the export folder. Off by default because WAV uses much more storage.",
            checked = settings.automaticWavExportEnabled,
            onCheckedChange = actions.setAutomaticWavExportEnabled,
        )
        OutlinedButton(
            enabled = !exportingAll,
            onClick = {
                exportingAll = true
                scope.launch {
                    val result = actions.exportAllAudio()
                    exportResultText = result.fold(
                        onSuccess = ::formatAudioExportResult,
                        onFailure = { "Export failed: ${it.message ?: it::class.simpleName}" },
                    )
                    exportingAll = false
                }
            },
        ) {
            Text(if (exportingAll) "Exporting…" else "Export all audio")
        }
        exportResultText?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        HorizontalDivider()

        SectionTitle("Transcription")
        ModePickerRow(
            title = "Mode",
            value = transcriptionModeLabel(settings.transcriptionMode),
            onClick = { showTranscriptionModePicker = true },
        )
        ModePickerRow(
            title = "Local model",
            value = localModel.selectedOption?.let {
                "${it.model.shortLabel} · ${Formatting.storageSize(it.model.downloadBytes)}"
            } ?: "Choose model",
            onClick = { if (!localModel.downloading) showLocalModelPicker = true },
        )
        localModel.selectedOption?.model?.let { model ->
            Text(
                text = model.description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        InfoRow(
            "On-device model",
            when {
                localModel.installing -> "Installing…"
                localModel.downloading -> "Downloading…"
                localModel.downloaded -> "Installed (${localModel.selectedOption?.model?.displayName ?: localModel.modelName})"
                localModel.errorMessage != null -> "Error"
                else -> "Not installed"
            },
        )
        if (localModel.downloading) {
            if (localModel.totalBytes > 0) {
                LinearProgressIndicator(
                    progress = {
                        (localModel.downloadedBytes.toFloat() / localModel.totalBytes)
                            .coerceIn(0f, 1f)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    text = "${Formatting.storageSize(localModel.downloadedBytes)} of " +
                        Formatting.storageSize(localModel.totalBytes),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }
        localModel.errorMessage?.let {
            Text(text = it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
        if (!localModel.downloaded && !localModel.downloading) {
            Text(
                text = "Transcribes on this phone with no audio leaving the device. " +
                    "Choose the model size that fits this phone, then download on Wi-Fi.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (localModel.downloading) {
                OutlinedButton(onClick = actions.cancelModelDownload) { Text("Cancel") }
            } else {
                OutlinedButton(onClick = actions.refreshLocalModel) { Text("Check") }
                Button(
                    enabled = !localModel.downloaded,
                    onClick = actions.downloadLocalModel,
                ) {
                    Text("Download selected")
                }
            }
        }
        ModePickerRow(
            title = "Cloud provider",
            value = cloudProviderLabel(settings.cloudTranscriptionProvider),
            onClick = { showCloudProviderPicker = true },
        )
        if (settings.cloudTranscriptionProvider == CloudProvider.Soniox) {
            OutlinedTextField(
                value = settings.sonioxApiKey,
                onValueChange = actions.setSonioxApiKey,
                label = { Text("Soniox API key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Text(
            text = if (settings.cloudTranscriptionEnabled) {
                "Cloud transcription, speaker labels, and live transcription are used automatically when the selected provider supports them."
            } else {
                "Local only keeps transcription on this phone. Cloud transcription is off in this mode."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (settings.cloudTranscriptionEnabled) {
            // Auto-test shortly after the key/provider settles (debounced so it never fires mid-typing
            // or per keystroke), plus a manual button. Result is shown inline below.
            LaunchedEffect(
                settings.cloudTranscriptionProvider,
                settings.openAiApiKey,
                settings.sonioxApiKey,
                settings.cloudTranscriptionEnabled,
            ) {
                if (settings.cloudTranscriptionKeyConfigured()) {
                    delay(700)
                    actions.testCloudConnection()
                }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(
                    onClick = actions.testCloudConnection,
                    enabled = settings.cloudTranscriptionKeyConfigured() &&
                        cloudHealth.status != CloudHealthStatus.Checking,
                ) { Text("Test connection") }
                if (cloudHealth.status == CloudHealthStatus.Checking) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                }
            }
            cloudConnectionStatusLine(cloudHealth, settings)?.let { (text, color) ->
                Text(text = text, style = MaterialTheme.typography.bodySmall, color = color)
            }
        }
        HorizontalDivider()

        SectionTitle("AI")
        ModePickerRow(
            title = "Mode",
            value = aiModeLabel(settings.aiMode),
            onClick = { showAiModePicker = true },
        )
        ModePickerRow(
            title = "Model",
            value = aiModelLabel(settings.aiModel),
            onClick = { showAiModelPicker = true },
        )
        SettingsToggleRow(
            title = "Remote AI",
            subtitle = "Send transcripts to the configured AI provider when you run AI. Off by default.",
            checked = settings.remoteAiConsent,
            onCheckedChange = actions.setRemoteAiConsent,
        )
        OutlinedTextField(
            value = settings.openAiApiKey,
            onValueChange = actions.setOpenAiApiKey,
            label = { Text("OpenAI API key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            text = "One key is used for both cloud transcription and remote AI.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        HorizontalDivider()

        SectionTitle("Privacy")
        Text(
            text = "Audio and transcripts stay on this phone unless the transcription mode uses " +
                "cloud or you enable remote AI above. Nothing is shared with analytics or " +
                "diagnostics services.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "You are responsible for following recording and consent laws where you " +
                "use this feature.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        HorizontalDivider()

        SectionTitle("Diagnostics")
        InfoRow("Receiver", statusHeadline)
        InfoRow(
            "Transcription queue",
            "${diagnostics.queuedTranscriptionTasks} waiting, ${diagnostics.failedTranscriptionTasks} failed",
        )
        InfoRow("AI outputs", diagnostics.aiOutputCount.toString())
        OutlinedButton(onClick = {
            supportReportText = actions.exportSupportReport()?.let { formatSupportReport(it) }
        }) { Text("View support report") }
        OutlinedButton(onClick = {
            detailedDiagnosticsText = formatDetailedDiagnostics(
                sessionState = sessionState,
                settings = settings,
                diagnostics = diagnostics,
                watchServiceState = watchServiceState,
                segments = segments,
            )
        }) { Text("View detailed logs") }
        Text(
            text = "Diagnostics contain status counters and gap metadata only — never audio or transcript text.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(bottom = 24.dp),
        )
    }

    supportReportText?.let { report ->
        AlertDialog(
            onDismissRequest = { supportReportText = null },
            title = { Text("Support report") },
            text = {
                SelectionContainer {
                    Text(
                        text = report,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { supportReportText = null }) { Text("Done") }
            },
        )
    }

    detailedDiagnosticsText?.let { report ->
        AlertDialog(
            onDismissRequest = { detailedDiagnosticsText = null },
            title = { Text("Detailed diagnostics") },
            text = {
                SelectionContainer {
                    Text(
                        text = report,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { detailedDiagnosticsText = null }) { Text("Done") }
            },
        )
    }

    if (confirmRevoke) {
        ConfirmDialog(
            title = "Revoke receiver access?",
            body = "This app will stop receiving watch audio and forget its local receiver " +
                "session. To fully unbind, also use Forget Receiver in the watch's Audio " +
                "Companion settings.",
            confirmLabel = "Revoke",
            onConfirm = actions.revokeReceiver,
            onDismiss = { confirmRevoke = false },
        )
    }
    if (confirmDeleteAll) {
        ConfirmDialog(
            title = "Delete all local data?",
            body = "This deletes all stored audio, transcripts, transcription tasks, AI " +
                "outputs, and receiver resume state from this phone. This cannot be undone.",
            confirmLabel = "Delete everything",
            onConfirm = actions.deleteAll,
            onDismiss = { confirmDeleteAll = false },
        )
    }
    if (showTranscriptionModePicker) {
        SingleChoiceDialog(
            title = "Transcription mode",
            options = TranscriptionMode.entries.map { it to transcriptionModeLabel(it) },
            descriptions = TranscriptionMode.entries.associateWith { transcriptionModeDescription(it) },
            selected = settings.transcriptionMode,
            onSelect = actions.setTranscriptionMode,
            onDismiss = { showTranscriptionModePicker = false },
        )
    }
    if (showLocalModelPicker) {
        LocalModelPickerDialog(
            options = localModel.options,
            selectedModelId = localModel.selectedModelId,
            onSelect = actions.setLocalTranscriptionModel,
            onDismiss = { showLocalModelPicker = false },
        )
    }
    if (showCloudProviderPicker) {
        SingleChoiceDialog(
            title = "Cloud provider",
            options = CloudProvider.entries.map { it to cloudProviderLabel(it) },
            descriptions = CloudProvider.entries.associateWith { cloudProviderDescription(it) },
            selected = settings.cloudTranscriptionProvider,
            onSelect = actions.setCloudTranscriptionProvider,
            onDismiss = { showCloudProviderPicker = false },
        )
    }
    if (showAiModePicker) {
        SingleChoiceDialog(
            title = "AI mode",
            options = AiProcessingMode.entries.map { it to aiModeLabel(it) },
            descriptions = AiProcessingMode.entries.associateWith { aiModeDescription(it) },
            selected = settings.aiMode,
            onSelect = actions.setAiMode,
            onDismiss = { showAiModePicker = false },
        )
    }
    if (showAiModelPicker) {
        SingleChoiceDialog(
            title = "AI model",
            options = AiModels.all.map { it.id to aiModelLabel(it.id) },
            descriptions = AiModels.all.associate { it.id to it.description },
            selected = AiModels.byId(settings.aiModel).id,
            onSelect = actions.setAiModel,
            onDismiss = { showAiModelPicker = false },
        )
    }
}

/** Display label for a model id; resolves unknown ids to the default spec. */
fun aiModelLabel(modelId: String): String = AiModels.byId(modelId).let { spec ->
    spec.displayName + if (spec.recommended) " (Recommended)" else ""
}

fun cloudProviderLabel(provider: CloudProvider): String = when (provider) {
    CloudProvider.OpenAi -> "OpenAI"
    CloudProvider.Soniox -> "Soniox"
}

fun cloudProviderDescription(provider: CloudProvider): String = when (provider) {
    CloudProvider.OpenAi -> "OpenAI Audio transcriptions (gpt-4o-transcribe). Uses the OpenAI API key."
    CloudProvider.Soniox -> "Soniox async transcription (stt-async-v5). Uses the Soniox API key."
}

@Composable
private fun LocalModelPickerDialog(
    options: List<LocalTranscriptionModelOptionState>,
    selectedModelId: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Local transcription model") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                options.forEach { option ->
                    val model = option.model
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                onSelect(model.id)
                                onDismiss()
                            }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = model.id == selectedModelId,
                            onClick = {
                                onSelect(model.id)
                                onDismiss()
                            },
                        )
                        Column {
                            Text(
                                text = model.displayName + if (model.recommended) " (Recommended)" else "",
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            Text(
                                text = "${model.shortLabel} · ${Formatting.storageSize(model.downloadBytes)}" +
                                    if (option.downloaded) " · Installed" else "",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Text(
                                text = model.description,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done") }
        },
    )
}

@Composable
private fun ModePickerRow(title: String, value: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(text = title, style = MaterialTheme.typography.bodyLarge)
        Text(
            text = value,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

@Composable
private fun <T> SingleChoiceDialog(
    title: String,
    options: List<Pair<T, String>>,
    descriptions: Map<T, String>,
    selected: T,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                options.forEach { (option, label) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                onSelect(option)
                                onDismiss()
                            }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = option == selected,
                            onClick = {
                                onSelect(option)
                                onDismiss()
                            },
                        )
                        Column {
                            Text(text = label, style = MaterialTheme.typography.bodyLarge)
                            descriptions[option]?.let {
                                Text(
                                    text = it,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done") }
        },
    )
}

/** Plain-text content-free support report (counters and states only). */
fun formatSupportReport(report: dev.audiocompanion.app.AudioCompanionSupportReport): String =
    buildString {
        appendLine("Generated: ${Formatting.timeOfDay(report.generatedAtMs)}")
        appendLine("Receiver state: ${report.receiverState}")
        val d = report.diagnostics
        appendLine("Segments stored: ${d.segmentCount}")
        appendLine("Open segment: ${if (d.openSegmentId != null) "yes" else "no"}")
        appendLine("Transcription queued: ${d.queuedTranscriptionTasks}")
        appendLine("Transcription failed: ${d.failedTranscriptionTasks}")
        appendLine("AI outputs: ${d.aiOutputCount}")
        appendLine("Low storage: ${d.lowStorage}")
        appendLine("Pause requested: ${d.pauseRequested}")
        append("Free storage: ${Formatting.storageSize(d.freeStorageHintKb.toLong() * 1024)}")
    }

/** Content-free technical diagnostics for local troubleshooting. */
fun formatDetailedDiagnostics(
    sessionState: ReceiverSessionState,
    settings: AudioCompanionSettings,
    diagnostics: AudioCompanionDiagnostics,
    watchServiceState: Int?,
    segments: List<SegmentMeta>,
): String = buildString {
    appendLine("Receiver")
    appendLine("state=${sessionState}")
    appendLine("watch=${watchServiceStateLabel(watchServiceState)} raw=${watchServiceState ?: "unknown"}")
    appendLine("enabled=${settings.backgroundReceiverEnabled}")
    appendLine("pauseRequested=${diagnostics.pauseRequested}")
    appendLine("lowStorage=${diagnostics.lowStorage}")
    appendLine("freeStorage=${Formatting.storageSize(diagnostics.freeStorageHintKb.toLong() * 1024)}")
    appendLine("segments=${diagnostics.segmentCount} open=${diagnostics.openSegmentId ?: "none"}")
    appendLine("transcriptionQueued=${diagnostics.queuedTranscriptionTasks}")
    appendLine("transcriptionFailed=${diagnostics.failedTranscriptionTasks}")
    appendLine()
    appendLine("Recent segments")
    val recent = segments.sortedByDescending { it.receivedAtMs }.take(8)
    if (recent.isEmpty()) {
        appendLine("none")
        return@buildString
    }
    recent.forEach { meta ->
        val loss = visibleLossGaps(meta)
        val quiet = quietGaps(meta)
        appendLine(
            "${Formatting.shortDate(meta.receivedAtMs, meta.receivedAtMs)} " +
                "${Formatting.timeOfDay(meta.receivedAtMs)} " +
                "id=${meta.segmentId.take(12)} " +
                "state=${if (meta.isOpen) "open" else meta.closeReason?.kind ?: "closed"} " +
                "duration=${Formatting.duration(segmentDurationMs(meta))} " +
                "frames=${meta.frameCount} gaps=${meta.gaps.size} " +
                "loss=${loss.size}/${Formatting.duration(loss.sumOf { gapDurationMs(it, meta.frameDurationMs) })} " +
                "quiet=${quiet.size}/${Formatting.duration(quiet.sumOf { gapDurationMs(it, meta.frameDurationMs) })}",
        )
        meta.gaps.sortedBy { it.firstMissingSequence }.take(16).forEach { gap ->
            appendLine("  ${formatGapDiagnostic(meta, gap)}")
        }
        if (meta.gaps.size > 16) {
            appendLine("  ... ${meta.gaps.size - 16} more gap records")
        }
    }
}

private fun formatGapDiagnostic(meta: SegmentMeta, gap: GapMeta): String {
    val rawReason = gap.reasonRaw
    val reason = rawReason?.let { GapReason.fromRaw(it) }
    val classification = if (isVisibleLossGap(gap, meta.gaps)) "missing" else "quiet"
    val first = gap.firstMissingSequence
    val last = if (gap.missingFrameCount > 0u) first + gap.missingFrameCount - 1u else first
    return "gap $classification " +
        "origin=${gap.origin} " +
        "reason=${reason?.name ?: rawReason?.toString() ?: "unknown"} " +
        "duration=${Formatting.duration(gapDurationMs(gap, meta.frameDurationMs))} " +
        "seq=$first..$last " +
        "sample=${gap.firstMissingSampleIndex} " +
        "watchDrops=${gap.watchDropCounter ?: "n/a"} " +
        "display=${gapDescription(gap)}"
}

fun formatAudioExportResult(result: AudioExportResult): String =
    when {
        result.fileCount == 0 && result.skippedOpenSegments > 0 ->
            "No closed segments exported yet. The current recording will export after it closes."
        result.fileCount == 0 ->
            "No audio was available to export."
        result.fileCount == 1 ->
            "Exported 1 WAV file to ${result.directory}."
        else ->
            "Exported ${result.fileCount} WAV files to ${result.directory}."
    }

/** Inline cloud connectivity status under the Test button: (message, color), or null when idle. */
@Composable
fun cloudConnectionStatusLine(
    cloudHealth: CloudHealth,
    settings: AudioCompanionSettings,
): Pair<String, Color>? = when (cloudHealth.status) {
    CloudHealthStatus.Checking ->
        "Testing ${cloudProviderShortName(settings.cloudTranscriptionProvider)}…" to
            MaterialTheme.colorScheme.onSurfaceVariant
    CloudHealthStatus.Ok ->
        "Connected — ${cloudProviderShortName(settings.cloudTranscriptionProvider)} is working." to
            StatusColors.success
    CloudHealthStatus.Failed ->
        (cloudHealth.message ?: "The cloud provider couldn't be reached.") to
            MaterialTheme.colorScheme.error
    CloudHealthStatus.NotConfigured ->
        (cloudHealth.message ?: "Add an API key to use cloud transcription.") to
            StatusColors.warning
    CloudHealthStatus.Unknown ->
        if (!settings.cloudTranscriptionKeyConfigured()) {
            "Add a ${cloudProviderShortName(settings.cloudTranscriptionProvider)} API key to use cloud transcription." to
                StatusColors.warning
        } else {
            null
        }
}

private fun cloudProviderShortName(provider: CloudProvider): String = when (provider) {
    CloudProvider.OpenAi -> "OpenAI"
    CloudProvider.Soniox -> "Soniox"
}

fun transcriptionModeLabel(mode: TranscriptionMode): String = when (mode) {
    TranscriptionMode.LocalOnly -> "Local only"
    TranscriptionMode.RemoteOnly -> "Cloud only"
    TranscriptionMode.LocalFirst -> "Local first"
    TranscriptionMode.RemoteFirst -> "Cloud first"
}

fun transcriptionModeDescription(mode: TranscriptionMode): String = when (mode) {
    TranscriptionMode.LocalOnly -> "Keep audio on this phone. Requires the local model."
    TranscriptionMode.RemoteOnly -> "Send audio to the cloud provider for transcription."
    TranscriptionMode.LocalFirst -> "Try local first; use cloud if local is unavailable."
    TranscriptionMode.RemoteFirst -> "Use cloud first; fall back to local if cloud is unavailable."
}

fun aiModeLabel(mode: AiProcessingMode): String = when (mode) {
    AiProcessingMode.LocalOnly -> "Local only"
    AiProcessingMode.RemoteOnly -> "Remote only"
    AiProcessingMode.LocalFirst -> "Local first"
    AiProcessingMode.RemoteFirst -> "Remote first"
}

fun aiModeDescription(mode: AiProcessingMode): String = when (mode) {
    AiProcessingMode.LocalOnly -> "Run AI on this phone only. No local AI model is available yet."
    AiProcessingMode.RemoteOnly -> "Send transcripts to the remote provider when you run AI."
    AiProcessingMode.LocalFirst -> "Prefer local AI; fall back to remote with consent."
    AiProcessingMode.RemoteFirst -> "Prefer remote AI; fall back to local when available."
}
