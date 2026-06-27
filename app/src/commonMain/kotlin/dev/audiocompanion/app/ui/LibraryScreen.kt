package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.AiPlainText
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.AudioExportResult
import dev.audiocompanion.app.LiveTranscriptPreview
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.app.PlaybackUiState
import dev.audiocompanion.app.SegmentWaveform
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptSegment
import dev.audiocompanion.transcription.TranscriptWord
import kotlinx.coroutines.launch

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
    liveTranscriptOf: (String) -> String? = { null },
    livePreviewOf: (String) -> LiveTranscriptPreview? = { null },
    liveTranscribedFrameCountOf: (String) -> Long? = { null },
    annotationOf: (String) -> SegmentAnnotation?,
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
    nowMs: Long,
    playback: PlaybackUiState,
    selectedSegmentId: String?,
    onSelectSegment: (String?) -> Unit,
    onReprocessSegment: (String) -> Unit = {},
    onDeleteSegment: (String) -> Unit,
    onExportSegment: suspend (String) -> Result<AudioExportResult>,
    onShareFile: (String) -> Unit = {},
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
    onSeekPlayback: (String, Long) -> Unit,
    onCyclePlaybackSpeed: () -> Unit,
    loadWaveform: suspend (String) -> SegmentWaveform? = { null },
) {
    val selected = selectedSegmentId?.let { id -> segments.firstOrNull { it.segmentId == id } }
    if (selected != null) {
        SegmentDetailScreen(
            meta = selected,
            transcript = transcriptOf(selected.segmentId),
            liveTranscript = liveTranscriptOf(selected.segmentId),
            livePreview = livePreviewOf(selected.segmentId),
            liveTranscribedFrameCount = liveTranscribedFrameCountOf(selected.segmentId),
            annotation = annotationOf(selected.segmentId),
            settings = settings,
            localModel = localModel,
            nowMs = nowMs,
            playback = playback,
            onBack = { onSelectSegment(null) },
            onDelete = {
                onDeleteSegment(selected.segmentId)
                onSelectSegment(null)
            },
            onExportSegment = onExportSegment,
            onShareFile = onShareFile,
            onReprocess = { onReprocessSegment(selected.segmentId) },
            onPlaySegment = onPlaySegment,
            onPausePlayback = onPausePlayback,
            onStopPlayback = onStopPlayback,
            onSeekPlayback = onSeekPlayback,
            onCyclePlaybackSpeed = onCyclePlaybackSpeed,
            loadWaveform = loadWaveform,
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
                    // Silence the watch skipped to save power is not a gap, so a segment that
                    // only has those does not belong in the "Gaps" filter.
                    LibraryFilter.Gaps -> visibleLossGaps(meta).isNotEmpty()
                    LibraryFilter.Untranscribed -> !meta.isFullyTranscribed
                }
            }
            .filter { meta ->
                if (query.isBlank()) true
                else {
                    val transcript = transcriptOf(meta.segmentId)?.text.orEmpty()
                    val annotation = annotationOf(meta.segmentId)
                    transcript.contains(query, ignoreCase = true) ||
                        annotation?.title.orEmpty().contains(query, ignoreCase = true) ||
                        annotation?.summary.orEmpty().contains(query, ignoreCase = true)
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
                        liveText = liveTranscriptOf(meta.segmentId),
                        annotation = annotationOf(meta.segmentId),
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
    liveText: String?,
    annotation: SegmentAnnotation?,
    nowMs: Long,
    onClick: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = segmentTitle(meta, transcript, annotation, liveText),
                style = MaterialTheme.typography.bodyLarge,
            )
            AiPlainText.clean(annotation?.summary)?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
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
                    color = segmentStateColor(meta),
                )
            }
            gapSummary(meta)?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
fun SegmentDetailScreen(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    liveTranscript: String? = null,
    livePreview: LiveTranscriptPreview? = null,
    /** Live-transcribed frame count of the open segment, for waveform coloring. */
    liveTranscribedFrameCount: Long? = null,
    annotation: SegmentAnnotation?,
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
    nowMs: Long,
    playback: PlaybackUiState,
    onBack: () -> Unit,
    onDelete: () -> Unit,
    onExportSegment: suspend (String) -> Result<AudioExportResult>,
    onShareFile: (String) -> Unit = {},
    onReprocess: () -> Unit = {},
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
    onSeekPlayback: (String, Long) -> Unit,
    onCyclePlaybackSpeed: () -> Unit,
    loadWaveform: suspend (String) -> SegmentWaveform? = { null },
) {
    var confirmDelete by remember { mutableStateOf(false) }
    var exportMessage by remember(meta.segmentId) { mutableStateOf<String?>(null) }
    var exporting by remember(meta.segmentId) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // Decoded off the UI path; re-built when more audio is stored (open segment grows).
    var waveform by remember(meta.segmentId) { mutableStateOf<SegmentWaveform?>(null) }
    LaunchedEffect(meta.segmentId, meta.frameCount) {
        waveform = loadWaveform(meta.segmentId)
    }
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
        Text(
            text = segmentTitle(meta, transcript, annotation, liveTranscript),
            style = MaterialTheme.typography.headlineSmall,
        )
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
            color = segmentStateColor(meta),
        )

        if (meta.frameCount > 0) {
            SectionTitle("Audio")
            waveform?.let { wave ->
                val selected = playback.segmentId == meta.segmentId
                SegmentWaveformView(
                    waveform = wave,
                    positionFraction = if (selected && wave.mediaDurationMs > 0) {
                        (playback.positionMs.toFloat() / wave.mediaDurationMs).coerceIn(0f, 1f)
                    } else {
                        null
                    },
                    onSeekFraction = { fraction ->
                        onSeekPlayback(meta.segmentId, (fraction * wave.mediaDurationMs).toLong())
                    },
                    // Blue = transcribed: the whole bar once the final transcript exists, or
                    // the live-transcribed prefix while still recording.
                    transcribedFraction = when {
                        meta.isFullyTranscribed -> 1f
                        liveTranscribedFrameCount != null && meta.frameCount > 0 ->
                            (liveTranscribedFrameCount.toFloat() / meta.frameCount).coerceIn(0f, 1f)
                        else -> null
                    },
                )
                WaveformLegend(showTranscribed = true)
            } ?: Text(
                text = "Preparing waveform…",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            gapSummary(meta)?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            PlaybackControls(
                meta = meta,
                playback = playback,
                onPlaySegment = onPlaySegment,
                onPausePlayback = onPausePlayback,
                onStopPlayback = onStopPlayback,
                onSeekPlayback = onSeekPlayback,
                onCyclePlaybackSpeed = onCyclePlaybackSpeed,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    enabled = !exporting,
                    onClick = {
                        exporting = true
                        scope.launch {
                            val result = onExportSegment(meta.segmentId)
                            exportMessage = result.fold(
                                onSuccess = {
                                    if (it.fileCount == 0) {
                                        "No audio frames were available to export."
                                    } else {
                                        // Hand straight to the platform share sheet: on iOS the
                                        // raw file path is not reachable for users.
                                        onShareFile(it.files.first().path)
                                        "Exported — use the share sheet to save or send the WAV."
                                    }
                                },
                                onFailure = { "Export failed: ${it.message ?: it::class.simpleName}" },
                            )
                            exporting = false
                        }
                    },
                ) {
                    Text(if (exporting) "Exporting…" else "Share WAV")
                }
            }
            exportMessage?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        AiPlainText.clean(annotation?.summary)?.let { summary ->
            SectionTitle("AI Summary")
            Text(text = summary, style = MaterialTheme.typography.bodyMedium)
        }

        SectionTitle("Transcript")
        transcriptionSetupMessage(settings, localModel)?.let { message ->
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                color = StatusColors.warning,
            )
        }
        when {
            transcript != null -> {
                transcriptionQualityMessage(transcript.modelUsed)?.let { message ->
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodySmall,
                        color = StatusColors.warning,
                    )
                }
                TranscriptTimeline(
                    meta = meta,
                    text = transcript.text,
                    segments = transcript.segments,
                    words = transcript.words,
                    onSeekMs = { onSeekPlayback(meta.segmentId, it) },
                )
            }
            !liveTranscript.isNullOrBlank() -> {
                liveTranscriptionSourceLabel(livePreview)?.let { source ->
                    Text(
                        text = source,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TranscriptTimeline(
                    meta = meta,
                    text = liveTranscript,
                    segments = livePreview?.segments.orEmpty(),
                    words = emptyList(),
                    onSeekMs = { onSeekPlayback(meta.segmentId, it) },
                )
                Text(
                    text = if (meta.isOpen) {
                        "Live transcript — updates while the recording continues. The final " +
                            "transcript replaces this when the recording ends."
                    } else {
                        "Preliminary transcript — the final pass over the full recording is " +
                            "still processing."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            else -> Text(
                text = when {
                    meta.transcriptionState == dev.audiocompanion.storage.TranscriptionState.NoSpeech ->
                        "No speech was detected in this audio."
                    meta.transcriptionState == dev.audiocompanion.storage.TranscriptionState.Failed ->
                        "Transcription failed. It will be retried."
                    meta.transcriptionState == dev.audiocompanion.storage.TranscriptionState.Disabled ->
                        "Transcription is unavailable. Install the local model or add an API key for the selected cloud provider in Settings."
                    meta.isOpen ->
                        "Recording — the transcript will appear here as speech is recognized."
                    else -> "Audio is stored. The transcript will appear here after processing."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Re-transcribe a closed segment with the *current* settings — e.g. to upgrade an
        // on-device transcript to cloud accuracy after enabling cloud transcription.
        if (!meta.isOpen) {
            OutlinedButton(onClick = onReprocess) { Text("Re-transcribe") }
            Text(
                text = "Runs transcription again using your current settings " +
                    "(e.g. cloud for higher accuracy).",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        SectionTitle("Details")
        InfoRow("Source", "Pebble watch")
        InfoRow("Audio length", Formatting.duration(segmentDurationMs(meta)))
        transcript?.let {
            // Only what actually produced the text matters: on-device + model, or cloud service.
            InfoRow("Transcribed with", transcriptionSourceLabel(it.providerId, it.modelUsed))
            InfoRow("Transcribed", Formatting.relativeTime(it.createdAtMs, nowMs))
        }
        InfoRow(
            "Stored on this phone",
            Formatting.storageSize(
                // Actual on-disk log size when known; estimate for metas from older builds.
                if (meta.logBytes > 0) meta.logBytes else meta.frameCount * 39,
            ),
        )
        InterruptionDetails(meta)
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

@Composable
private fun TranscriptTimeline(
    meta: SegmentMeta,
    text: String,
    segments: List<TranscriptSegment>,
    words: List<TranscriptWord>,
    onSeekMs: (Long) -> Unit,
) {
    val timed = transcriptTimelineItems(meta, segments, words)
    if (timed.isEmpty()) {
        TranscriptParagraphs(text = text)
        return
    }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            var previousTimestamp: String? = null
            timed.forEach { item ->
                when (item) {
                    is TranscriptTimelineItem.Speech -> {
                        val timestamp = clockTimeFor(meta, item.startMs)
                        SpeechTimelineRow(
                            timestamp = timestamp.takeIf { it != previousTimestamp },
                            item = item,
                            onSeekMs = onSeekMs,
                        )
                        previousTimestamp = timestamp
                    }
                    is TranscriptTimelineItem.Break -> BreakTimelineRow()
                    is TranscriptTimelineItem.Pause -> {
                        val timestamp = clockTimeFor(meta, item.startMs)
                        PauseTimelineRow(
                            timestamp = timestamp.takeIf { it != previousTimestamp },
                            item = item,
                        )
                        previousTimestamp = timestamp
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptParagraphs(text: String) {
    val paragraphs = transcriptParagraphs(text)
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            paragraphs.forEachIndexed { index, paragraph ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (paragraphs.size > 1) {
                        Text(
                            text = "Transcript section ${index + 1}",
                            style = MaterialTheme.typography.labelMedium,
                            color = StatusColors.info,
                        )
                    }
                    Text(
                        text = paragraph,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                }
                if (index < paragraphs.lastIndex) {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        }
    }
}

@Composable
private fun SpeechTimelineRow(
    timestamp: String?,
    item: TranscriptTimelineItem.Speech,
    onSeekMs: (Long) -> Unit,
) {
    val speaker = item.speaker
    val accent = speaker?.let(::speakerColor)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clickable { onSeekMs(item.startMs) },
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.Top,
    ) {
        if (speaker == null || accent == null) {
            TimestampPill(timestamp)
        } else {
            TranscriptSpeakerGutter(
                timestamp = timestamp,
                speaker = speaker,
                color = accent,
            )
        }
        if (accent != null) SpeakerAccentBar(accent)
        Text(
            text = item.text,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun TranscriptSpeakerGutter(timestamp: String?, speaker: String, color: Color) {
    Column(
        modifier = Modifier.width(68.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        timestamp?.let { TimestampPill(it, width = 68.dp) }
        Text(
            text = speaker,
            style = MaterialTheme.typography.labelSmall,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SpeakerAccentBar(color: Color) {
    Box(
        modifier = Modifier
            .width(3.dp)
            .fillMaxHeight()
            .background(color.copy(alpha = 0.82f), RoundedCornerShape(999.dp)),
    )
}

internal fun speakerColor(speaker: String): Color {
    val index = speakerColorIndex(speaker)
    return speakerColors[index]
}

internal fun speakerColorIndex(speaker: String): Int {
    val normalized = speaker.trim()
    val speakerNumber = normalized
        .removePrefix("Speaker ")
        .takeIf { it.isNotBlank() && it.all(Char::isDigit) }
        ?.toIntOrNull()
    return if (speakerNumber != null && speakerNumber > 0) {
        (speakerNumber - 1) % speakerColors.size
    } else {
        normalized.lowercase().fold(0) { acc, char -> acc * 31 + char.code }
            .let { hash -> ((hash % speakerColors.size) + speakerColors.size) % speakerColors.size }
    }
}

@Composable
private fun BreakTimelineRow() {
    Box(modifier = Modifier.fillMaxWidth().height(8.dp))
}

@Composable
private fun PauseTimelineRow(timestamp: String?, item: TranscriptTimelineItem.Pause) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TimestampPill(timestamp, muted = true)
        Text(
            text = item.label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun TimestampPill(text: String?, muted: Boolean = false, width: Dp = 72.dp) {
    if (text == null) {
        Box(modifier = Modifier.width(width))
        return
    }
    Box(
        modifier = Modifier
            .width(width)
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (muted) 0.55f else 1f),
                RoundedCornerShape(999.dp),
            )
            .padding(vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private val speakerColors = listOf(
    Color(0xFF6F55B5),
    Color(0xFF007C89),
    Color(0xFFB45F06),
    Color(0xFF2E7D32),
    Color(0xFFB3265D),
    Color(0xFF1565C0),
)

sealed interface TranscriptTimelineItem {
    val startMs: Long

    data class Speech(
        override val startMs: Long,
        val endMs: Long,
        val text: String,
        val speaker: String?,
    ) : TranscriptTimelineItem

    data class Break(
        override val startMs: Long,
        val durationMs: Long,
    ) : TranscriptTimelineItem

    data class Pause(
        override val startMs: Long,
        val durationMs: Long,
        val missing: Boolean,
        val reasons: List<String> = emptyList(),
    ) : TranscriptTimelineItem {
        val label: String
            get() = if (missing) {
                val base = if (durationMs < 1_000) {
                    "audio briefly interrupted"
                } else {
                    "audio interrupted for ${Formatting.duration(durationMs)}"
                }
                reasonSummary?.let { "$base ($it)" } ?: base
            } else {
                "quiet for ${Formatting.duration(durationMs)}"
            }

        private val reasonSummary: String?
            get() = when (reasons.size) {
                0 -> null
                1 -> reasons.single()
                else -> "several reasons"
            }
    }
}

fun transcriptTimelineItems(
    meta: SegmentMeta,
    segments: List<TranscriptSegment>,
    words: List<TranscriptWord> = emptyList(),
): List<TranscriptTimelineItem> {
    val speech = coalescedSpeechBlocks(segments, words).flatMap(::splitSpeechBlock)
    if (speech.isEmpty()) return emptyList()

    val gaps = collapsedTranscriptGaps(meta)
    val items = mutableListOf<TranscriptTimelineItem>()
    var gapIndex = 0
    var previousSpeechEnd: Long? = null
    speech.forEach { block ->
        var insertedGapBeforeBlock = false
        while (gapIndex < gaps.size && gaps[gapIndex].startMs <= block.startMs) {
            items += gaps[gapIndex++]
            insertedGapBeforeBlock = true
        }
        previousSpeechEnd?.takeUnless { insertedGapBeforeBlock }?.let { previousEnd ->
            val pauseMs = block.startMs - previousEnd
            if (pauseMs >= QUIET_PAUSE_THRESHOLD_MS) {
                items += TranscriptTimelineItem.Pause(
                    startMs = previousEnd,
                    durationMs = pauseMs,
                    missing = false,
                )
            } else if (pauseMs >= SILENCE_BREAK_THRESHOLD_MS) {
                items += TranscriptTimelineItem.Break(
                    startMs = previousEnd,
                    durationMs = pauseMs,
                )
            }
        }
        items += block
        previousSpeechEnd = maxOf(previousSpeechEnd ?: block.endMs, block.endMs)
    }
    while (gapIndex < gaps.size) items += gaps[gapIndex++]
    val deduped = items.distinctBy { item ->
        when (item) {
            is TranscriptTimelineItem.Speech -> "speech:${item.startMs}:${item.endMs}:${item.text}"
            is TranscriptTimelineItem.Break -> "break:${item.startMs}:${item.durationMs}"
            is TranscriptTimelineItem.Pause ->
                "pause:${item.startMs}:${item.durationMs}:${item.missing}:${item.reasons.joinToString("|")}"
        }
    }
    return coalesceTimelineQuiet(deduped)
}

/**
 * Collapses consecutive non-speech rows of the same kind so the transcript reads cleanly: a run
 * of quiet spans (skipped silence, breaks, or stretches too quiet to transcribe) becomes one quiet
 * period of their combined length, and a run of interruptions becomes one. The merged quiet total
 * is then labelled by length — 30 s+ gets a "quiet for…" label, 5–30 s a bare break, shorter is
 * dropped — matching the natural between-speech pauses.
 */
private fun coalesceTimelineQuiet(
    items: List<TranscriptTimelineItem>,
): List<TranscriptTimelineItem> {
    val out = mutableListOf<TranscriptTimelineItem>()
    var i = 0
    while (i < items.size) {
        val kind = timelineQuietKind(items[i])
        if (kind == null) {
            out += items[i]
            i++
            continue
        }
        val startMs = items[i].startMs
        var totalMs = 0L
        var j = i
        while (j < items.size && timelineQuietKind(items[j]) == kind) {
            totalMs += timelineItemDurationMs(items[j])
            j++
        }
        when {
            kind == TimelineQuietKind.Loss ->
                out += TranscriptTimelineItem.Pause(
                    startMs = startMs,
                    durationMs = totalMs,
                    missing = true,
                    reasons = items.subList(i, j)
                        .filterIsInstance<TranscriptTimelineItem.Pause>()
                        .flatMap { it.reasons }
                        .distinct(),
                )
            totalMs >= QUIET_PAUSE_THRESHOLD_MS ->
                out += TranscriptTimelineItem.Pause(startMs, totalMs, missing = false)
            totalMs >= SILENCE_BREAK_THRESHOLD_MS ->
                out += TranscriptTimelineItem.Break(startMs, totalMs)
            // Shorter than a break: nothing to show.
        }
        i = j
    }
    return out
}

private enum class TimelineQuietKind { Quiet, Loss }

/** Quiet (skipped silence / too-quiet pause / break) vs interruption; null for speech. */
private fun timelineQuietKind(item: TranscriptTimelineItem): TimelineQuietKind? = when (item) {
    is TranscriptTimelineItem.Speech -> null
    is TranscriptTimelineItem.Break -> TimelineQuietKind.Quiet
    is TranscriptTimelineItem.Pause ->
        if (item.missing) TimelineQuietKind.Loss else TimelineQuietKind.Quiet
}

private fun timelineItemDurationMs(item: TranscriptTimelineItem): Long = when (item) {
    is TranscriptTimelineItem.Speech -> 0L
    is TranscriptTimelineItem.Break -> item.durationMs
    is TranscriptTimelineItem.Pause -> item.durationMs
}

/** Presents a raw provider speaker id ("1", "agent") as a friendly label ("Speaker 1", "Agent"). */
internal fun speakerLabel(speaker: String): String {
    val trimmed = speaker.trim()
    if (trimmed.isEmpty()) return trimmed
    return if (trimmed.all { it.isDigit() }) {
        "Speaker $trimmed"
    } else {
        trimmed.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
    }
}

private fun coalescedSpeechBlocks(
    segments: List<TranscriptSegment>,
    words: List<TranscriptWord>,
): List<TranscriptTimelineItem.Speech> {
    // Prefer word-level timings for the finest timeline, EXCEPT when diarization labeled the
    // segments with speakers (words carry no speaker) — then segment-level keeps the speaker labels.
    val hasSpeakers = segments.any { !it.speaker.isNullOrBlank() }
    val raw = if (words.isNotEmpty() && !hasSpeakers) {
        words.map {
            TranscriptTimelineItem.Speech(
                startMs = it.startMs.coerceAtLeast(0),
                endMs = it.endMs.coerceAtLeast(it.startMs),
                text = it.text.trim(),
                speaker = null,
            )
        }
    } else {
        segments.map {
            TranscriptTimelineItem.Speech(
                startMs = it.startMs.coerceAtLeast(0),
                endMs = it.endMs.coerceAtLeast(it.startMs),
                text = it.text.trim(),
                speaker = it.speaker?.let(::speakerLabel),
            )
        }
    }.filter { it.text.isNotBlank() }.sortedBy { it.startMs }

    val blocks = mutableListOf<TranscriptTimelineItem.Speech>()
    var current: TranscriptTimelineItem.Speech? = null
    raw.forEach { next ->
        val existing = current
        if (existing != null &&
            next.startMs - existing.endMs < SILENCE_BREAK_THRESHOLD_MS &&
            next.speaker == existing.speaker
        ) {
            current = existing.copy(
                endMs = maxOf(existing.endMs, next.endMs),
                text = joinTranscriptText(existing.text, next.text),
            )
        } else {
            existing?.let { blocks += it }
            current = next
        }
    }
    current?.let { blocks += it }
    return blocks
}

private fun splitSpeechBlock(
    block: TranscriptTimelineItem.Speech,
    maxChars: Int = 260,
    maxWords: Int = 34,
): List<TranscriptTimelineItem.Speech> {
    val chunks = readableChunks(block.text, maxChars, maxWords)
    if (chunks.size <= 1) return listOf(block)
    val totalWords = wordCount(block.text).coerceAtLeast(1)
    val durationMs = (block.endMs - block.startMs).coerceAtLeast(0)
    var consumedWords = 0
    return chunks.map { chunk ->
        val chunkWords = wordCount(chunk).coerceAtLeast(1)
        val startOffset = durationMs * consumedWords / totalWords
        consumedWords += chunkWords
        val endOffset = durationMs * consumedWords / totalWords
        block.copy(
            startMs = block.startMs + startOffset,
            endMs = (block.startMs + endOffset).coerceAtLeast(block.startMs + startOffset),
            text = chunk,
        )
    }
}

private fun collapsedTranscriptGaps(meta: SegmentMeta): List<TranscriptTimelineItem.Pause> {
    if (meta.gaps.isEmpty()) return emptyList()
    val segmentDuration = segmentDurationMs(meta).coerceAtLeast(0)

    fun rangeOf(gap: GapMeta): Pair<Long, Long> {
        val rawStart = sampleOffsetMs(meta, gap.firstMissingSampleIndex)
        val start = if (segmentDuration > 0) rawStart.coerceIn(0, segmentDuration) else rawStart.coerceAtLeast(0)
        val rawDuration = gapDurationMs(gap, meta.frameDurationMs).coerceAtLeast(0)
        val end = if (segmentDuration > 0) {
            (start + rawDuration).coerceAtMost(segmentDuration)
        } else {
            start + rawDuration
        }
        return start to end.coerceAtLeast(start)
    }

    data class GapCluster(
        val startMs: Long,
        val endMs: Long,
        val gaps: List<GapMeta>,
    )

    fun collapse(gaps: List<GapMeta>): List<GapCluster> {
        val ranges = gaps.map { gap ->
            val (start, end) = rangeOf(gap)
            GapCluster(start, end, listOf(gap))
        }.sortedBy { it.startMs }
        val merged = mutableListOf<GapCluster>()
        ranges.forEach { range ->
            val last = merged.lastOrNull()
            if (last != null && range.startMs <= last.endMs + GAP_COLLAPSE_WINDOW_MS) {
                merged[merged.lastIndex] = last.copy(
                    endMs = maxOf(last.endMs, range.endMs),
                    gaps = last.gaps + range.gaps,
                )
            } else {
                merged += range
            }
        }
        return merged
    }

    fun pauses(gaps: List<GapMeta>, missing: Boolean) = collapse(gaps).map { cluster ->
        TranscriptTimelineItem.Pause(
            startMs = cluster.startMs,
            durationMs = (cluster.endMs - cluster.startMs).coerceAtLeast(0),
            missing = missing,
            reasons = if (missing) cluster.gaps.map { gapDescription(it) }.distinct() else emptyList(),
        )
    }

    // Silence-suppressed spans are known-quiet audio, marked missing=false ("quiet"); genuine loss
    // is missing=true ("audio interrupted"). They collapse separately so a quiet stretch never
    // inherits an interruption's framing. The length-based labelling (30 s+ label, shorter → break
    // or nothing) is applied later by coalesceTimelineQuiet, on the combined total, so consecutive
    // quiet spans from any source read as one period.
    val lost = pauses(visibleLossGaps(meta), missing = true)
    val quiet = pauses(quietGaps(meta), missing = false)
    return (lost + quiet).sortedBy { it.startMs }
}

private fun joinTranscriptText(a: String, b: String): String =
    when {
        a.isBlank() -> b
        b.isBlank() -> a
        b.firstOrNull() in listOf('.', ',', '!', '?', ';', ':') -> a + b
        else -> "$a $b"
    }

private fun sampleOffsetMs(meta: SegmentMeta, sampleIndex: ULong): Long {
    val base = meta.firstSampleIndex ?: sampleIndex
    val samples = if (sampleIndex >= base) sampleIndex - base else 0UL
    return (samples.toLong() * 1_000L) / meta.sampleRateHz.toLong()
}

private fun clockTimeFor(meta: SegmentMeta, offsetMs: Long): String =
    Formatting.timeOfDay(meta.receivedAtMs + offsetMs)

/** Human-readable transcription source: on-device with model, or the cloud service used. */
fun transcriptionSourceLabel(providerId: String, modelUsed: String?): String {
    val service = when {
        providerId == "cactus-local" -> "On-device"
        providerId == "soniox" -> "Soniox (cloud)"
        providerId.startsWith("openai") -> "OpenAI (cloud)"
        else -> providerId
    }
    return modelUsed?.takeIf { it.isNotBlank() }?.let { "$service · $it" } ?: service
}

/** Source line for an in-progress live transcript ("Live · …"), or null when unknown. */
fun liveTranscriptionSourceLabel(preview: LiveTranscriptPreview?): String? {
    val providerId = preview?.providerId ?: return null
    return "Live · " + transcriptionSourceLabel(providerId, preview.modelUsed)
}

@Composable
private fun InterruptionDetails(meta: SegmentMeta) {
    val breakdown = gapReasonBreakdown(meta)
    if (breakdown.isEmpty()) return

    SectionTitle("Interruption details")
    Text(
        text = "Missing audio only. Quiet periods are not counted as interruptions.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        breakdown.forEach { item ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(text = item.reason, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        text = "${item.count} interruption${if (item.count == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    text = "about ${Formatting.duration(item.durationMs)}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

private const val SILENCE_BREAK_THRESHOLD_MS = 5_000L
private const val QUIET_PAUSE_THRESHOLD_MS = 30_000L
private const val GAP_COLLAPSE_WINDOW_MS = 5_000L

fun transcriptParagraphs(
    text: String,
    maxChars: Int = 280,
    maxWords: Int = 34,
): List<String> {
    val normalized = text.trim().replace('\r', '\n')
    if (normalized.isBlank()) return emptyList()
    val paragraphs = mutableListOf<String>()
    val current = StringBuilder()
    var currentWords = 0
    fun flush() {
        if (current.isNotEmpty()) {
            paragraphs += current.toString()
            current.clear()
            currentWords = 0
        }
    }
    normalized.split(Regex("\\n{2,}")).forEachIndexed { blockIndex, block ->
        if (blockIndex > 0) flush()
        for (sentence in sentencesIn(block).flatMap { readableChunks(it, maxChars, maxWords) }) {
            val words = wordCount(sentence)
            if (current.isNotEmpty() &&
                (current.length + 1 + sentence.length > maxChars || currentWords + words > maxWords)
            ) {
                flush()
            }
            if (current.isNotEmpty()) current.append(' ')
            current.append(sentence)
            currentWords += words
        }
    }
    flush()
    return paragraphs
}

private fun readableChunks(text: String, maxChars: Int, maxWords: Int): List<String> {
    val words = text.replace(Regex(" +"), " ").trim().split(' ').filter { it.isNotBlank() }
    if (words.isEmpty()) return emptyList()
    if (text.length <= maxChars && words.size <= maxWords) return listOf(text.trim())
    val chunks = mutableListOf<String>()
    val current = mutableListOf<String>()
    var currentChars = 0
    fun flush() {
        if (current.isNotEmpty()) {
            chunks += current.joinToString(" ")
            current.clear()
            currentChars = 0
        }
    }
    for (word in words) {
        val nextChars = currentChars + word.length + if (current.isEmpty()) 0 else 1
        if (current.isNotEmpty() && (nextChars > maxChars || current.size >= maxWords)) {
            flush()
        }
        current += word
        currentChars += word.length + if (current.size == 1) 0 else 1
    }
    flush()
    return chunks
}

private fun wordCount(text: String): Int =
    text.split(Regex("\\s+")).count { it.isNotBlank() }

private fun sentencesIn(block: String): List<String> {
    val sentences = mutableListOf<String>()
    val current = StringBuilder()
    for (index in block.indices) {
        val char = block[index]
        current.append(if (char == '\n' || char == '\t') ' ' else char)
        val next = block.getOrNull(index + 1)
        val nextAfterSpace = block.drop(index + 1).firstOrNull { !it.isWhitespace() }
        if ((char == '.' || char == '!' || char == '?') &&
            next?.isWhitespace() == true &&
            (nextAfterSpace == null || nextAfterSpace.isUpperCase() || nextAfterSpace.isDigit())
        ) {
            sentences += current.toString().replace(Regex(" +"), " ").trim()
            current.clear()
        }
    }
    val tail = current.toString().replace(Regex(" +"), " ").trim()
    if (tail.isNotBlank()) sentences += tail
    return sentences
}

@Composable
private fun PlaybackControls(
    meta: SegmentMeta,
    playback: PlaybackUiState,
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
    onSeekPlayback: (String, Long) -> Unit,
    onCyclePlaybackSpeed: () -> Unit,
) {
    val selected = playback.segmentId == meta.segmentId
    val durationMs = if (selected && playback.durationMs > 0) {
        playback.durationMs
    } else {
        segmentDurationMs(meta)
    }.coerceAtLeast(0)
    val positionMs = if (selected) playback.positionMs.coerceIn(0, durationMs) else 0L

    // The waveform above is the one and only progress bar: it draws the playback cursor and
    // seeks on tap, so there is deliberately no second Slider here.
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = "${Formatting.duration(positionMs)} / ${Formatting.duration(durationMs)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "Speed ${if (selected) playback.speed else 1f}x",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (meta.isOpen) {
            Text(
                text = "Still recording — playback follows what has been stored so far.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = {
                    if (selected && playback.playing) onPausePlayback() else onPlaySegment(meta.segmentId)
                },
            ) {
                Text(if (selected && playback.playing) "Pause" else "Play")
            }
            OutlinedButton(
                onClick = onStopPlayback,
                enabled = selected && (playback.playing || playback.positionMs > 0),
            ) {
                Text("Stop")
            }
            OutlinedButton(onClick = onCyclePlaybackSpeed) {
                Text("Speed")
            }
        }
    }
}
