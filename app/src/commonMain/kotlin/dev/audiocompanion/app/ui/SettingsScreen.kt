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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.AiProcessingMode
import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transport.ReceiverSessionState

@Composable
fun SettingsScreen(
    sessionState: ReceiverSessionState,
    settings: AudioCompanionSettings,
    diagnostics: AudioCompanionDiagnostics,
    localModel: LocalTranscriptionModelState,
    statusHeadline: String,
    actions: AppActions,
) {
    var confirmRevoke by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var showTranscriptionModePicker by remember { mutableStateOf(false) }
    var showAiModePicker by remember { mutableStateOf(false) }

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
        InfoRow("Receiver status", statusHeadline)
        SettingsToggleRow(
            title = "Background receiving",
            subtitle = "Keep receiving watch audio while this app is in the background.",
            checked = settings.backgroundReceiverEnabled,
            onCheckedChange = actions.setBackgroundReceiverEnabled,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = actions.pairWatch) { Text("Find Watch") }
            when (sessionState) {
                ReceiverSessionState.Disconnected ->
                    OutlinedButton(onClick = actions.startReceiver) { Text("Reconnect") }
                else ->
                    OutlinedButton(onClick = actions.stopReceiver) { Text("Disconnect") }
            }
        }
        TextButton(onClick = { confirmRevoke = true }) {
            Text("Revoke receiver", color = MaterialTheme.colorScheme.error)
        }
        HorizontalDivider()

        SectionTitle("Storage And Retention")
        InfoRow("Stored segments", diagnostics.segmentCount.toString())
        InfoRow("Free phone storage", Formatting.storageSize(diagnostics.freeStorageHintKb.toLong() * 1024))
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
        HorizontalDivider()

        SectionTitle("Transcription")
        ModePickerRow(
            title = "Mode",
            value = transcriptionModeLabel(settings.transcriptionMode),
            onClick = { showTranscriptionModePicker = true },
        )
        InfoRow(
            "Local model",
            when {
                localModel.downloading -> "Downloading…"
                localModel.downloaded -> "Installed (${localModel.modelName})"
                localModel.errorMessage != null -> "Error"
                else -> "Not installed"
            },
        )
        localModel.errorMessage?.let {
            Text(text = it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = actions.refreshLocalModel) { Text("Check") }
            Button(
                enabled = !localModel.downloaded && !localModel.downloading,
                onClick = actions.downloadLocalModel,
            ) {
                Text(if (localModel.downloading) "Downloading…" else "Download Model")
            }
        }
        SettingsToggleRow(
            title = "Cloud transcription",
            subtitle = "Send audio to the configured cloud provider for transcription. Off by default.",
            checked = settings.cloudTranscriptionConsent,
            onCheckedChange = actions.setCloudTranscriptionConsent,
        )
        HorizontalDivider()

        SectionTitle("AI")
        ModePickerRow(
            title = "Mode",
            value = aiModeLabel(settings.aiMode),
            onClick = { showAiModePicker = true },
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
            text = "Audio and transcripts stay on this phone unless you enable cloud " +
                "transcription or remote AI above. Nothing is shared with analytics or " +
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
        OutlinedButton(onClick = actions.exportSupportReport) { Text("Export support report") }
        Text(
            text = "Support reports contain status counters only — never audio or transcript text.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(bottom = 24.dp),
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

fun transcriptionModeLabel(mode: TranscriptionMode): String = when (mode) {
    TranscriptionMode.LocalOnly -> "Local only"
    TranscriptionMode.RemoteOnly -> "Cloud only"
    TranscriptionMode.LocalFirst -> "Local first"
    TranscriptionMode.RemoteFirst -> "Cloud first"
}

fun transcriptionModeDescription(mode: TranscriptionMode): String = when (mode) {
    TranscriptionMode.LocalOnly -> "Keep audio on this phone. Requires the local model."
    TranscriptionMode.RemoteOnly -> "Send audio to the cloud provider for transcription."
    TranscriptionMode.LocalFirst -> "Try local first; use cloud if local is unavailable and cloud is enabled."
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
