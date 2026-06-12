package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript

enum class LibraryFilter(val label: String) {
    All("All"),
    Today("Today"),
    Gaps("Gaps"),
    Untranscribed("Untranscribed"),
}

@Composable
fun LibraryScreen(
    segments: List<SegmentMeta>,
    transcriptOf: (String) -> SegmentTranscript?,
    nowMs: Long,
    selectedSegmentId: String?,
    onSelectSegment: (String?) -> Unit,
    onDeleteSegment: (String) -> Unit,
) {
    val selected = selectedSegmentId?.let { id -> segments.firstOrNull { it.segmentId == id } }
    if (selected != null) {
        SegmentDetailScreen(
            meta = selected,
            transcript = transcriptOf(selected.segmentId),
            nowMs = nowMs,
            onBack = { onSelectSegment(null) },
            onDelete = {
                onDeleteSegment(selected.segmentId)
                onSelectSegment(null)
            },
        )
        return
    }

    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(LibraryFilter.All) }

    val visible = remember(segments, query, filter, nowMs) {
        segments
            .sortedByDescending { it.receivedAtMs }
            .filter { meta ->
                when (filter) {
                    LibraryFilter.All -> true
                    LibraryFilter.Today -> Formatting.isSameLocalDay(meta.receivedAtMs, nowMs)
                    LibraryFilter.Gaps -> meta.gaps.isNotEmpty()
                    LibraryFilter.Untranscribed -> !meta.isFullyTranscribed
                }
            }
            .filter { meta ->
                if (query.isBlank()) true
                else {
                    val transcript = transcriptOf(meta.segmentId)?.text.orEmpty()
                    transcript.contains(query, ignoreCase = true)
                }
            }
    }

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Text(
            text = "Library",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(top = 16.dp, bottom = 8.dp),
        )
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("Search transcripts") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(vertical = 8.dp),
        ) {
            LibraryFilter.entries.forEach { candidate ->
                FilterChip(
                    selected = filter == candidate,
                    onClick = { filter = candidate },
                    label = { Text(candidate.label) },
                )
            }
        }
        if (visible.isEmpty()) {
            Text(
                text = if (segments.isEmpty()) {
                    "Audio segments will appear here once your watch starts recording."
                } else {
                    "Nothing matches this search or filter."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 24.dp),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp),
            ) {
                items(visible, key = { it.segmentId }) { meta ->
                    LibrarySegmentRow(
                        meta = meta,
                        transcript = transcriptOf(meta.segmentId),
                        nowMs = nowMs,
                        onClick = { onSelectSegment(meta.segmentId) },
                    )
                }
            }
        }
    }
}

@Composable
private fun LibrarySegmentRow(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    nowMs: Long,
    onClick: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(text = segmentTitle(meta, transcript), style = MaterialTheme.typography.bodyLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "${Formatting.shortDate(meta.receivedAtMs, nowMs)} " +
                        "${Formatting.timeOfDay(meta.receivedAtMs)} · " +
                        Formatting.duration(segmentDurationMs(meta)),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = if (meta.isOpen) "Recording" else transcriptionStateLabel(meta.transcriptionState),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (meta.gaps.isNotEmpty()) {
                    Text(
                        text = "${meta.gaps.size} gap${if (meta.gaps.size == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = StatusColors.warning,
                    )
                }
            }
        }
    }
}

@Composable
fun SegmentDetailScreen(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
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
            TextButton(onClick = onBack) { Text("< Library") }
            if (!meta.isOpen) {
                TextButton(onClick = { confirmDelete = true }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            }
        }
        Text(text = segmentTitle(meta, transcript), style = MaterialTheme.typography.headlineSmall)
        Text(
            text = "${Formatting.shortDate(meta.receivedAtMs, nowMs)} " +
                "${Formatting.timeOfDay(meta.receivedAtMs)} · " +
                Formatting.duration(segmentDurationMs(meta)),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = if (meta.isOpen) "Recording now" else transcriptionStateLabel(meta.transcriptionState),
            style = MaterialTheme.typography.bodyMedium,
            color = if (meta.isOpen) StatusColors.recording else MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (meta.gaps.isNotEmpty()) {
            SectionTitle("Gaps")
            meta.gaps.forEach { gap ->
                Text(
                    text = buildString {
                        append(gapDescription(gap))
                        val approx = gapDurationMs(gap, meta.frameDurationMs)
                        if (approx > 0) {
                            append(" · about ")
                            append(Formatting.duration(approx))
                        }
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = StatusColors.warning,
                )
            }
        }

        SectionTitle("Transcript")
        if (transcript != null) {
            Text(text = transcript.text, style = MaterialTheme.typography.bodyMedium)
        } else {
            Text(
                text = when (meta.transcriptionState) {
                    dev.audiocompanion.storage.TranscriptionState.NoSpeech -> "No speech was detected in this audio."
                    dev.audiocompanion.storage.TranscriptionState.Failed -> "Transcription failed. It will be retried."
                    dev.audiocompanion.storage.TranscriptionState.Disabled ->
                        "Transcription is unavailable. Install the local model or enable cloud transcription in Settings."
                    else -> "Audio is stored. The transcript will appear here after processing."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        SectionTitle("Details")
        InfoRow("Source", "Pebble watch")
        InfoRow("Audio length", Formatting.duration(segmentDurationMs(meta)))
        transcript?.let {
            InfoRow("Transcribed with", it.providerId + (it.modelUsed?.let { m -> " ($m)" } ?: ""))
            InfoRow("Processing mode", it.modeUsed.toString())
            InfoRow("Transcribed", Formatting.relativeTime(it.createdAtMs, nowMs))
        }
        InfoRow("Stored on this phone", Formatting.storageSize(meta.frameCount * 27))
        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        OutlinedButton(onClick = onBack) { Text("Back to Library") }

        if (confirmDelete) {
            ConfirmDialog(
                title = "Delete this segment?",
                body = "This deletes the stored audio, its transcript, and AI outputs created " +
                    "only from this segment. This cannot be undone.",
                confirmLabel = "Delete",
                onConfirm = onDelete,
                onDismiss = { confirmDelete = false },
            )
        }
    }
}
