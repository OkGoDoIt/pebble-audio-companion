package dev.audiocompanion.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.audiocompanion.transport.ReceiverSessionState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

@Composable
fun App(
    sessionState: StateFlow<ReceiverSessionState> =
        MutableStateFlow(ReceiverSessionState.Disconnected),
    diagnostics: StateFlow<AudioCompanionDiagnostics> =
        MutableStateFlow(AudioCompanionDiagnostics()),
    settings: StateFlow<AudioCompanionSettings> =
        MutableStateFlow(AudioCompanionSettings()),
    onPairWatch: () -> Unit = {},
    onStartReceiver: () -> Unit = {},
    onStopReceiver: () -> Unit = {},
    onRefreshDiagnostics: () -> Unit = {},
    onBackgroundReceiverChanged: (Boolean) -> Unit = {},
    onCloudTranscriptionConsentChanged: (Boolean) -> Unit = {},
    onOpenAiApiKeyChanged: (String) -> Unit = {},
    onRemoteAiConsentChanged: (Boolean) -> Unit = {},
    onDiagnosticsContentChanged: (Boolean) -> Unit = {},
    onCycleTranscriptionMode: () -> Unit = {},
    onCycleAiMode: () -> Unit = {},
    onRetentionDaysChanged: (Int) -> Unit = {},
    onDeleteAll: () -> Unit = {},
    onExportDiagnostics: () -> Unit = {},
    onRevokeReceiver: () -> Unit = {},
) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            val state = sessionState.collectAsState().value
            val currentDiagnostics = diagnostics.collectAsState().value
            val currentSettings = settings.collectAsState().value
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.Start,
            ) {
                Text(text = "Pebble Audio Companion", style = MaterialTheme.typography.headlineSmall)
                Text(text = "Receiver: ${state.describe()}", style = MaterialTheme.typography.bodyLarge)
                Text(
                    text = "Stored segments: ${currentDiagnostics.segmentCount}" +
                        currentDiagnostics.openSegmentId?.let { " (open: $it)" }.orEmpty(),
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    text = "Transcription queue: ${currentDiagnostics.queuedTranscriptionTasks} queued, " +
                        "${currentDiagnostics.failedTranscriptionTasks} failed",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    text = "AI outputs: ${currentDiagnostics.aiOutputCount}",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    text = "Storage: ${currentDiagnostics.freeStorageHintKb} KB free" +
                        when {
                            currentDiagnostics.pauseRequested -> " - pause requested"
                            currentDiagnostics.lowStorage -> " - low storage"
                            else -> ""
                        },
                    style = MaterialTheme.typography.bodyMedium,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onPairWatch) {
                        Text("Pair")
                    }
                    Button(onClick = onStartReceiver) {
                        Text("Start")
                    }
                    OutlinedButton(onClick = onStopReceiver) {
                        Text("Stop")
                    }
                }
                OutlinedButton(onClick = onRefreshDiagnostics) {
                    Text("Refresh Diagnostics")
                }
                Text(text = "Privacy Controls", style = MaterialTheme.typography.titleMedium)
                ToggleRow(
                    label = "Background receiver",
                    checked = currentSettings.backgroundReceiverEnabled,
                    onCheckedChange = onBackgroundReceiverChanged,
                )
                ToggleRow(
                    label = "Cloud transcription consent",
                    checked = currentSettings.cloudTranscriptionConsent,
                    onCheckedChange = onCloudTranscriptionConsentChanged,
                )
                OutlinedTextField(
                    value = currentSettings.openAiApiKey,
                    onValueChange = onOpenAiApiKeyChanged,
                    label = { Text("OpenAI API key") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                )
                ToggleRow(
                    label = "Remote AI consent",
                    checked = currentSettings.remoteAiConsent,
                    onCheckedChange = onRemoteAiConsentChanged,
                )
                ToggleRow(
                    label = "Include content in diagnostics",
                    checked = currentSettings.diagnosticsIncludeContent,
                    onCheckedChange = onDiagnosticsContentChanged,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onCycleTranscriptionMode) {
                        Text("Transcription: ${currentSettings.transcriptionMode}")
                    }
                    OutlinedButton(onClick = onCycleAiMode) {
                        Text("AI: ${currentSettings.aiMode}")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        onRetentionDaysChanged((currentSettings.retentionDays - 7).coerceAtLeast(1))
                    }) {
                        Text("-7d")
                    }
                    Text(
                        text = "Retention: ${currentSettings.retentionDays} days",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    OutlinedButton(onClick = {
                        onRetentionDaysChanged((currentSettings.retentionDays + 7).coerceAtMost(365))
                    }) {
                        Text("+7d")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onExportDiagnostics) {
                        Text("Export Diagnostics")
                    }
                    OutlinedButton(onClick = onRevokeReceiver) {
                        Text("Revoke")
                    }
                    OutlinedButton(onClick = onDeleteAll) {
                        Text("Delete All")
                    }
                }
            }
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Switch(checked = checked, onCheckedChange = onCheckedChange)
        Text(text = label, style = MaterialTheme.typography.bodyMedium)
    }
}

private fun ReceiverSessionState.describe(): String = when (this) {
    ReceiverSessionState.Disconnected -> "disconnected"
    ReceiverSessionState.Connecting -> "connecting..."
    ReceiverSessionState.Authorizing -> "authorizing..."
    ReceiverSessionState.PendingConsent -> "confirm on your watch"
    is ReceiverSessionState.Denied -> "denied (${status ?: statusRaw})"
    ReceiverSessionState.Authorized -> "authorized, idle"
    is ReceiverSessionState.Streaming -> "streaming (stream $streamId)"
    is ReceiverSessionState.Revoked -> "revoked on watch"
}
