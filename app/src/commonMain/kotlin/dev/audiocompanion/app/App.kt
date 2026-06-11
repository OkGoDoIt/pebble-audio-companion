package dev.audiocompanion.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
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

/**
 * Placeholder shell: shows the receiver session state. Real onboarding/diagnostics/settings
 * surfaces come later (plan 6.7); for now the UI just proves the Compose Multiplatform
 * toolchain and the :core dependency wiring.
 */
@Composable
fun App(
    sessionState: StateFlow<ReceiverSessionState> =
        MutableStateFlow(ReceiverSessionState.Disconnected),
) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            val state = sessionState.collectAsState().value
            Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(text = "Pebble Audio Companion", style = MaterialTheme.typography.headlineSmall)
                Text(text = "Receiver: ${state.describe()}", style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

private fun ReceiverSessionState.describe(): String = when (this) {
    ReceiverSessionState.Disconnected -> "disconnected"
    ReceiverSessionState.Connecting -> "connecting…"
    ReceiverSessionState.Authorizing -> "authorizing…"
    ReceiverSessionState.PendingConsent -> "confirm on your watch"
    is ReceiverSessionState.Denied -> "denied (${status ?: statusRaw})"
    ReceiverSessionState.Authorized -> "authorized, idle"
    is ReceiverSessionState.Streaming -> "streaming (stream $streamId)"
    is ReceiverSessionState.Revoked -> "revoked on watch"
}
