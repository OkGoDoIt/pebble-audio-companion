package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.PlaybackUiState
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript

/** One row in the Today timeline: a captured segment (gaps render inside the row, quietly). */
sealed interface TimelineItem {
    val key: String

    data class Segment(
        val meta: SegmentMeta,
        val title: String,
        val summary: String?,
        val stateLabel: String,
        /** Calm one-line summary of missing audio, or null. */
        val gapSummary: String?,
    ) : TimelineItem {
        override val key: String get() = "seg-${meta.segmentId}"
    }
}

/** Derives the Today timeline: today's segments newest-first. */
fun buildTimeline(
    segments: List<SegmentMeta>,
    transcriptOf: (String) -> SegmentTranscript?,
    nowMs: Long,
    todayOnly: Boolean = true,
    annotationOf: (String) -> SegmentAnnotation? = { null },
    /** Rolling live transcript of a still-recording segment (preview, not durable). */
    liveTextOf: (String) -> String? = { null },
): List<TimelineItem> {
    val relevant = segments
        .filter { !todayOnly || Formatting.isSameLocalDay(it.receivedAtMs, nowMs) }
        .sortedByDescending { it.receivedAtMs }
    return relevant.map { meta ->
        val annotation = annotationOf(meta.segmentId)
        TimelineItem.Segment(
            meta = meta,
            title = segmentTitle(
                meta,
                transcriptOf(meta.segmentId),
                annotation,
                liveText = liveTextOf(meta.segmentId),
            ),
            summary = annotation?.summary,
            stateLabel = if (meta.isOpen) "Recording" else transcriptionStateLabel(meta.transcriptionState),
            gapSummary = gapSummary(meta),
        )
    }
}

/**
 * Title preference (ux plan Sections 8/9): AI-generated title, else transcript snippet (the
 * live preview while still recording), else a neutral label. Never raw file names/ids.
 */
fun segmentTitle(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    annotation: SegmentAnnotation? = null,
    liveText: String? = null,
): String {
    annotation?.title?.takeIf { it.isNotBlank() }?.let { return it }
    transcriptSnippet(transcript?.text)?.let { return it }
    // While recording, the freshest words are the interesting ones: show the tail.
    transcriptSnippet(liveText, tail = meta.isOpen)?.let { return it }
    return if (meta.isOpen) "Recording now" else "Conversation"
}

/** A ~64-char single-line transcript snippet (head or tail), or null when blank. */
fun transcriptSnippet(text: String?, tail: Boolean = false): String? {
    val snippet = text?.trim()?.replace('\n', ' ')
    if (snippet.isNullOrBlank()) return null
    return when {
        snippet.length <= 64 -> snippet
        tail -> "…" + snippet.takeLast(64).trimStart()
        else -> snippet.take(64).trimEnd() + "…"
    }
}

@Composable
fun TodayScreen(
    status: StatusUiModel,
    diagnostics: AudioCompanionDiagnostics,
    timeline: List<TimelineItem>,
    nowMs: Long,
    waveformBars: List<dev.audiocompanion.app.WaveformBar>,
    waveformWindowMs: Long,
    playback: PlaybackUiState,
    isSegmentTranscribed: (String) -> Boolean,
    onPrimaryAction: (PrimaryAction) -> Unit,
    onOpenSegment: (String) -> Unit,
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
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
        if (playback.segmentId != null) {
            NowPlayingBar(
                playback = playback,
                title = timeline
                    .filterIsInstance<TimelineItem.Segment>()
                    .firstOrNull { it.meta.segmentId == playback.segmentId }
                    ?.title ?: "Stored audio",
                onPlaySegment = onPlaySegment,
                onPausePlayback = onPausePlayback,
                onStopPlayback = onStopPlayback,
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
                            playback = playback,
                            onClick = { onOpenSegment(item.meta.segmentId) },
                            onPlaySegment = onPlaySegment,
                            onPausePlayback = onPausePlayback,
                        )
                    }
                }
            }
        }
    }
}

/** Compact player strip shown while stored audio is playing (replay of any conversation). */
@Composable
private fun NowPlayingBar(
    playback: PlaybackUiState,
    title: String,
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
) {
    val segmentId = playback.segmentId ?: return
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        IconButton(onClick = {
            if (playback.playing) onPausePlayback() else onPlaySegment(segmentId)
        }) {
            Icon(
                imageVector = if (playback.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                contentDescription = if (playback.playing) "Pause" else "Play",
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
            )
            Text(
                text = "${Formatting.duration(playback.positionMs)} / ${Formatting.duration(playback.durationMs)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onStopPlayback) {
            Icon(imageVector = Icons.Filled.Stop, contentDescription = "Stop playback")
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
    playback: PlaybackUiState,
    onClick: () -> Unit,
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
) {
    val meta = item.meta
    val startMs = meta.receivedAtMs
    val durationMs = segmentDurationMs(meta)
    val isThisPlaying = playback.segmentId == meta.segmentId && playback.playing
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(
            modifier = Modifier.padding(start = 12.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
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
                }
                item.gapSummary?.let { summary ->
                    Text(
                        text = summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (meta.frameCount > 0) {
                IconButton(
                    onClick = {
                        if (isThisPlaying) onPausePlayback() else onPlaySegment(meta.segmentId)
                    },
                    modifier = Modifier.size(40.dp),
                ) {
                    Icon(
                        imageVector = if (isThisPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        contentDescription = if (isThisPlaying) "Pause" else "Play this conversation",
                    )
                }
            }
        }
    }
}
