package dev.audiocompanion.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Semantic colors (ux plan Section 14): platform-leaning, restrained. */
object StatusColors {
    val recording = Color(0xFF2E7D32) // green
    val info = Color(0xFF1565C0) // blue
    val warning = Color(0xFFB26A00) // amber
    val error = Color(0xFFC62828) // red
    val neutral = Color(0xFF757575) // gray
}

fun StatusSeverity.color(): Color = when (this) {
    StatusSeverity.Neutral -> StatusColors.neutral
    StatusSeverity.Info -> StatusColors.info
    StatusSeverity.Active -> StatusColors.recording
    StatusSeverity.Warning -> StatusColors.warning
    StatusSeverity.Error -> StatusColors.error
}

@Composable
fun StatusDot(severity: StatusSeverity) {
    Box(
        modifier = Modifier
            .size(12.dp)
            .background(color = severity.color(), shape = CircleShape),
    )
}

/**
 * The status header band: dot + headline + supporting line + exactly one primary action
 * (filled), with secondary actions as outlined/text buttons (ux plan Section 8).
 */
@Composable
fun StatusHeader(
    status: StatusUiModel,
    detailLines: List<String> = emptyList(),
    onPrimaryAction: (PrimaryAction) -> Unit = {},
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            StatusDot(status.severity)
            Text(text = status.headline, style = MaterialTheme.typography.titleLarge)
        }
        status.supporting?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        detailLines.forEach { line ->
            Text(
                text = line,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        when (status.primaryAction) {
            PrimaryAction.Start -> Button(onClick = { onPrimaryAction(PrimaryAction.Start) }) {
                Text("Start Recording")
            }
            PrimaryAction.Stop -> OutlinedButton(onClick = { onPrimaryAction(PrimaryAction.Stop) }) {
                Text("Stop")
            }
            PrimaryAction.PairWatch -> Button(onClick = { onPrimaryAction(PrimaryAction.PairWatch) }) {
                Text("Find Watch")
            }
            PrimaryAction.SetUpAgain -> Button(onClick = { onPrimaryAction(PrimaryAction.SetUpAgain) }) {
                Text("Set Up Again")
            }
            PrimaryAction.Troubleshoot, PrimaryAction.None -> Unit
        }
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
    )
}

@Composable
fun SettingsToggleRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(text = value, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Destructive confirmation dialog listing exactly what will happen (ux plan Section 11). */
@Composable
fun ConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            TextButton(onClick = { onConfirm(); onDismiss() }) {
                Text(confirmLabel, color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
