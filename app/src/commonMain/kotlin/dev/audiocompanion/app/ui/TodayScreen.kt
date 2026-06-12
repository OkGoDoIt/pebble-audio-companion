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
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript

/** One row in the Today timeline: a captured segment or a gap inside it. */
sealed interface TimelineItem {
    val key: String

    data class Segment(
        val meta: SegmentMeta,
        val title: String,
        val summary: String?,
        val stateLabel: String,
    ) : TimelineItem {
        override val key: String get() = "seg-${meta.segmentId}"
    }

    data class Gap(
        val segmentId: String,
        val index: Int,
        val description: String,
        val approxDurationMs: Long,
    ) : TimelineItem {
        override val key: String get() = "gap-$segmentId-$index"
    }
}

/** Derives the Today timeline: today's segments newest-first, gaps shown inline. */
fun buildTimeline(
    segments: List<SegmentMeta>,
    transcriptOf: (String) -> SegmentTranscript?,
    nowMs: Long,
    todayOnly: Boolean = true,
    annotationOf: (String) -> SegmentAnnotation? = { null },
): List<TimelineItem> {
    val relevant = segments
        .filter { !todayOnly || Formatting.isSameLocalDay(it.receivedAtMs, nowMs) }
        .sortedByDescending { it.receivedAtMs }
    val items = mutableListOf<TimelineItem>()
    for (meta in relevant) {
        val annotation = annotationOf(meta.segmentId)
        items += TimelineItem.Segment(
            meta = meta,
            title = segmentTitle(meta, transcriptOf(meta.segmentId), annotation),
            summary = annotation?.summary,
            stateLabel = if (meta.isOpen) "Recording" else transcriptionStateLabel(meta.transcriptionState),
        )
        meta.gaps.forEachIndexed { index, gap ->
            items += TimelineItem.Gap(
                segmentId = meta.segmentId,
                index = index,
                description = gapDescription(gap),
                approxDurationMs = gapDurationMs(gap, meta.frameDurationMs),
            )
        }
    }
    return items
}

/**
 * Title preference (ux plan Sections 8/9): AI-generated title, else transcript snippet, else a
 * neutral label. Never raw file names/ids.
 */
fun segmentTitle(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    annotation: SegmentAnnotation? = null,
): String {
    annotation?.title?.takeIf { it.isNotBlank() }?.let { return it }
    val snippet = transcript?.text?.trim()?.replace('\n', ' ')
    if (!snippet.isNullOrBlank()) {
        return if (snippet.length <= 64) snippet else snippet.take(64).trimEnd() + "…"
    }
    return if (meta.isOpen) "Recording now" else "Conversation"
}

@Composable
fun TodayScreen(
    status: StatusUiModel,
    diagnostics: AudioCompanionDiagnostics,
    timeline: List<TimelineItem>,
    nowMs: Long,
    waveformBars: List<dev.audiocompanion.app.WaveformBar>,
    waveformWindowMs: Long,
    isSegmentTranscribed: (String) -> Boolean,
    onPrimaryAction: (PrimaryAction) -> Unit,
    onOpenSegment: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Text(
            text = "Today",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(top = 16.dp),
        )
        StatusHeader(
            status = status,
            detailLines = buildList {
                val queued = diagnostics.queuedTranscriptionTasks
                add(if (queued > 0) "Transcribing $queued segment${if (queued == 1) "" else "s"}" else "Transcription up to date")
                add("${Formatting.storageSize(diagnostics.freeStorageHintKb.toLong() * 1024)} free for audio")
                if (diagnostics.failedTranscriptionTasks > 0) {
                    add("${diagnostics.failedTranscriptionTasks} transcription task${if (diagnostics.failedTranscriptionTasks == 1) "" else "s"} failed")
                }
            },
            onPrimaryAction = onPrimaryAction,
        )
        if (waveformBars.isNotEmpty()) {
            LiveWaveform(
                bars = waveformBars,
                windowMs = waveformWindowMs,
                nowMs = nowMs,
                isSegmentTranscribed = isSegmentTranscribed,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }
        HorizontalDivider()
        if (timeline.isEmpty()) {
            TodayEmptyState(status)
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 12.dp),
            ) {
                items(timeline, key = { it.key }) { item ->
                    when (item) {
                        is TimelineItem.Segment -> TimelineSegmentRow(
                            item = item,
                            nowMs = nowMs,
                            onClick = { onOpenSegment(item.meta.segmentId) },
                        )
                        is TimelineItem.Gap -> TimelineGapRow(item)
                    }
                }
            }
        }
    }
}

@Composable
private fun TodayEmptyState(status: StatusUiModel) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = if (status.severity == StatusSeverity.Active) "Listening…" else "No audio captured yet",
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            text = when {
                status.severity == StatusSeverity.Active ->
                    "Captured audio will appear here as it is stored."
                else -> "Start background audio after authorizing your watch."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun TimelineSegmentRow(
    item: TimelineItem.Segment,
    nowMs: Long,
    onClick: () -> Unit,
) {
    val meta = item.meta
    val startMs = meta.receivedAtMs
    val durationMs = segmentDurationMs(meta)
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(text = item.title, style = MaterialTheme.typography.bodyLarge)
            item.summary?.takeIf { it.isNotBlank() }?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "${Formatting.timeOfDay(startMs)} · ${Formatting.duration(durationMs)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = item.stateLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (meta.isOpen) StatusColors.recording else MaterialTheme.colorScheme.onSurfaceVariant,
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
fun TimelineGapRow(item: TimelineItem.Gap) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = buildString {
                append(item.description)
                if (item.approxDurationMs > 0) {
                    append(" · about ")
                    append(Formatting.duration(item.approxDurationMs))
                }
            },
            style = MaterialTheme.typography.bodySmall,
            color = StatusColors.warning,
        )
    }
}
