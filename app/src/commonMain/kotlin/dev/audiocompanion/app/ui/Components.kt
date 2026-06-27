package dev.audiocompanion.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.app.cloudTranscriptionEnabled
import dev.audiocompanion.app.cloudTranscriptionKeyConfigured
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import dev.audiocompanion.transcription.TranscriptionMode

/** Semantic colors (ux plan Section 14): platform-leaning, restrained. */
object StatusColors {
    val recording = Color(0xFF2E7D32) // green
    val success = Color(0xFF2E7D32) // green (e.g. cloud connection OK)
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
    val accent = status.severity.color()
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        // A faint wash of the severity color so the hero state reads instantly without shouting.
        color = accent.copy(alpha = 0.07f),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.22f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(Spacing.tight),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                StatusDot(status.severity)
                Text(
                    text = status.headline,
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f),
                )
            }
            status.supporting?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (detailLines.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    detailLines.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            val primaryModifier = Modifier.fillMaxWidth().padding(top = Spacing.hair)
            when (status.primaryAction) {
                PrimaryAction.Start -> Button(
                    onClick = { onPrimaryAction(PrimaryAction.Start) },
                    modifier = primaryModifier,
                ) { Text("Start Recording") }
                PrimaryAction.Stop -> OutlinedButton(
                    onClick = { onPrimaryAction(PrimaryAction.Stop) },
                    modifier = primaryModifier,
                ) { Text("Stop") }
                PrimaryAction.PairWatch -> Button(
                    onClick = { onPrimaryAction(PrimaryAction.PairWatch) },
                    modifier = primaryModifier,
                ) { Text("Find Watch") }
                PrimaryAction.SetUpAgain -> Button(
                    onClick = { onPrimaryAction(PrimaryAction.SetUpAgain) },
                    modifier = primaryModifier,
                ) { Text("Set Up Again") }
                // Calm secondary styling: an escape hatch while connecting, not an alarm.
                PrimaryAction.Reconnect -> OutlinedButton(
                    onClick = { onPrimaryAction(PrimaryAction.Reconnect) },
                    modifier = primaryModifier,
                ) { Text("Reconnect") }
                PrimaryAction.Troubleshoot, PrimaryAction.None -> Unit
            }
        }
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(top = Spacing.section, bottom = Spacing.tight),
    )
}

/** Large screen title with consistent top spacing (Today / Library / AI / Settings). */
@Composable
fun ScreenTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.headlineMedium,
        modifier = modifier.padding(top = 12.dp, bottom = Spacing.tight),
    )
}

/** A muted, slightly-tracked group label sitting above a [SettingsGroup]. */
@Composable
fun GroupHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(start = 4.dp, top = Spacing.section, bottom = Spacing.tight),
    )
}

/** Small tinted status pill (e.g. "Recording", "Transcript ready"). Background derives from [color]. */
@Composable
fun StatusBadge(text: String, color: Color, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(color.copy(alpha = 0.13f), RoundedCornerShape(999.dp))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(text = text, style = MaterialTheme.typography.labelMedium, color = color)
    }
}

/** Short badge label + color for a segment's current state. */
fun segmentBadge(meta: SegmentMeta): Pair<String, Color> = when {
    meta.isOpen -> "Recording" to StatusColors.recording
    else -> when (meta.transcriptionState) {
        TranscriptionState.Complete -> "Transcript" to StatusColors.info
        TranscriptionState.Running, TranscriptionState.Uploading -> "Transcribing" to StatusColors.info
        TranscriptionState.Pending -> "Queued" to StatusColors.neutral
        TranscriptionState.NoSpeech -> "No speech" to StatusColors.neutral
        TranscriptionState.Failed -> "Failed" to StatusColors.error
        TranscriptionState.Disabled -> "Unavailable" to StatusColors.warning
    }
}

@Composable
fun SegmentStateBadge(meta: SegmentMeta, modifier: Modifier = Modifier) {
    val (label, color) = segmentBadge(meta)
    StatusBadge(text = label, color = color, modifier = modifier)
}

/**
 * iOS-style inset grouped container: a bordered, rounded surface that wraps a column of
 * [SettingsRow]/toggle rows separated by [RowDivider]. Replaces the old flat run of rows + full
 * dividers with crisp cards.
 */
@Composable
fun SettingsGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(content = content)
    }
}

/** Inset hairline divider between rows inside a [SettingsGroup]. */
@Composable
fun RowDivider() {
    HorizontalDivider(
        color = MaterialTheme.colorScheme.outlineVariant,
        modifier = Modifier.padding(start = 16.dp),
    )
}

/**
 * One row inside a [SettingsGroup]: title (+ optional subtitle), an optional trailing value, and an
 * optional chevron when tappable. Pass [trailing] for custom trailing content (e.g. a Switch).
 */
@Composable
fun SettingsRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    value: String? = null,
    valueColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .heightIn(min = 52.dp)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
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
        when {
            trailing != null -> trailing()
            value != null -> Text(
                text = value,
                style = MaterialTheme.typography.bodyMedium,
                color = valueColor,
                textAlign = androidx.compose.ui.text.style.TextAlign.End,
            )
        }
        if (onClick != null && trailing == null) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/** Toggle row sized to sit inside a [SettingsGroup]. */
@Composable
fun GroupedToggleRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    SettingsRow(
        title = title,
        subtitle = subtitle,
        trailing = { Switch(checked = checked, onCheckedChange = onCheckedChange) },
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

fun transcriptionSetupMessage(
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
): String? {
    val localReady = localModel.downloaded
    val cloudReady = settings.cloudTranscriptionEnabled && settings.cloudTranscriptionKeyConfigured()
    return when (settings.transcriptionMode) {
        TranscriptionMode.LocalOnly ->
            if (localReady) null
            else "Local transcription model is not installed, so transcription will not run until you download it."
        TranscriptionMode.LocalFirst -> when {
            localReady -> null
            cloudReady -> "Local transcription model is not installed. Transcription can use the selected cloud provider."
            else -> "Local transcription model is not installed and the selected cloud provider needs an API key, so transcription will not run."
        }
        TranscriptionMode.RemoteOnly ->
            if (cloudReady) null
            else "Cloud transcription needs an API key for the selected provider, or switch to local only after downloading a model."
        TranscriptionMode.RemoteFirst -> when {
            cloudReady || localReady -> null
            else -> "No transcription provider is ready. Download a local model or add an API key for the selected cloud provider."
        }
    }
}

fun transcriptionQualityMessage(modelUsed: String?): String? =
    if (modelUsed?.contains("parakeet-ctc", ignoreCase = true) == true) {
        "This transcript used the experimental Parakeet CTC model. If the wording looks off, " +
            "switch to the recommended TDT local model in Settings for future recordings."
    } else {
        null
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
