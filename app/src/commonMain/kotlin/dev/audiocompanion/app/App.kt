package dev.audiocompanion.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    onPairWatch: () -> Unit = {},
    onStartReceiver: () -> Unit = {},
    onStopReceiver: () -> Unit = {},
    onRefreshDiagnostics: () -> Unit = {},
) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            val state = sessionState.collectAsState().value
            val currentDiagnostics = diagnostics.collectAsState().value
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
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
            }
        }
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
