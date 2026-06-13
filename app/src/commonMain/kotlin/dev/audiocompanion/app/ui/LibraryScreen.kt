package dev.audiocompanion.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.app.AudioExportResult
import dev.audiocompanion.app.LiveTranscriptPreview
import dev.audiocompanion.app.LocalTranscriptionModelState
import dev.audiocompanion.app.PlaybackUiState
import dev.audiocompanion.app.SegmentWaveform
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptSegment
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
                    LibraryFilter.Gaps -> meta.gaps.isNotEmpty()
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
            annotation?.summary?.takeIf { it.isNotBlank() }?.let { summary ->
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

        annotation?.summary?.takeIf { it.isNotBlank() }?.let { summary ->
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
                TranscriptTimeline(
                    meta = meta,
                    text = transcript.text,
                    segments = transcript.segments,
                    onSeekMs = { onSeekPlayback(meta.segmentId, it) },
                )
            }
            !liveTranscript.isNullOrBlank() -> {
                TranscriptTimeline(
                    meta = meta,
                    text = liveTranscript,
                    segments = livePreview?.segments.orEmpty(),
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
                        "Transcription is unavailable. Install the local model or enable cloud transcription in Settings."
                    meta.isOpen ->
                        "Recording — the transcript will appear here as speech is recognized."
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
        InfoRow(
            "Stored on this phone",
            Formatting.storageSize(
                // Actual on-disk log size when known; estimate for metas from older builds.
                if (meta.logBytes > 0) meta.logBytes else meta.frameCount * 39,
            ),
        )
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
    onSeekMs: (Long) -> Unit,
) {
    val timed = transcriptTimelineItems(meta, segments)
    if (timed.isEmpty()) {
        TranscriptParagraphs(text = text)
        return
    }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            timed.forEach { item ->
                when (item) {
                    is TranscriptTimelineItem.Speech -> SpeechTimelineRow(meta, item, onSeekMs)
                    is TranscriptTimelineItem.Pause -> PauseTimelineRow(meta, item)
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
                        style = MaterialTheme.typography.bodyLarge.copy(lineHeight = 28.sp),
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
    meta: SegmentMeta,
    item: TranscriptTimelineItem.Speech,
    onSeekMs: (Long) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onSeekMs(item.startMs) },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        TimestampPill(clockTimeFor(meta, item.startMs))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            item.speaker?.let { speaker ->
                Text(
                    text = speaker,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Text(
                text = item.text,
                style = MaterialTheme.typography.bodyLarge.copy(lineHeight = 28.sp),
            )
        }
    }
}

@Composable
private fun PauseTimelineRow(meta: SegmentMeta, item: TranscriptTimelineItem.Pause) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 1.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TimestampPill(clockTimeFor(meta, item.startMs), muted = true)
        Text(
            text = item.label,
            style = MaterialTheme.typography.labelSmall,
            color = if (item.missing) {
                StatusColors.warning
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f)
            },
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun TimestampPill(text: String, muted: Boolean = false) {
    Box(
        modifier = Modifier
            .width(72.dp)
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

sealed interface TranscriptTimelineItem {
    val startMs: Long

    data class Speech(
        override val startMs: Long,
        val endMs: Long,
        val text: String,
        val speaker: String?,
    ) : TranscriptTimelineItem

    data class Pause(
        override val startMs: Long,
        val durationMs: Long,
        val missing: Boolean,
    ) : TranscriptTimelineItem {
        val label: String
            get() = if (missing) {
                "missing audio for ${Formatting.duration(durationMs)}"
            } else {
                "quiet for ${Formatting.duration(durationMs)}"
            }
    }
}

fun transcriptTimelineItems(
    meta: SegmentMeta,
    segments: List<TranscriptSegment>,
): List<TranscriptTimelineItem> {
    val speech = segments
        .filter { it.text.isNotBlank() }
        .sortedBy { it.startMs }
        .map {
            TranscriptTimelineItem.Speech(
                startMs = it.startMs.coerceAtLeast(0),
                endMs = it.endMs.coerceAtLeast(it.startMs),
                text = it.text.trim(),
                speaker = it.speaker,
            )
        }
    if (speech.isEmpty()) return emptyList()

    val gaps = meta.gaps.map {
        TranscriptTimelineItem.Pause(
            startMs = sampleOffsetMs(meta, it.firstMissingSampleIndex),
            durationMs = it.missingFrameCount.toLong() * meta.frameDurationMs,
            missing = true,
        )
    }
    val items = mutableListOf<TranscriptTimelineItem>()
    var gapIndex = 0
    var previousSpeechEnd: Long? = null
    speech.forEach { block ->
        while (gapIndex < gaps.size && gaps[gapIndex].startMs < block.startMs) {
            items += gaps[gapIndex++]
        }
        previousSpeechEnd?.let { previousEnd ->
            val pauseMs = block.startMs - previousEnd
            if (pauseMs >= QUIET_PAUSE_THRESHOLD_MS) {
                items += TranscriptTimelineItem.Pause(
                    startMs = previousEnd,
                    durationMs = pauseMs,
                    missing = false,
                )
            }
        }
        items += block
        previousSpeechEnd = maxOf(previousSpeechEnd ?: block.endMs, block.endMs)
    }
    while (gapIndex < gaps.size) items += gaps[gapIndex++]
    return items.distinctBy { item ->
        when (item) {
            is TranscriptTimelineItem.Speech -> "speech:${item.startMs}:${item.endMs}:${item.text}"
            is TranscriptTimelineItem.Pause -> "pause:${item.startMs}:${item.durationMs}:${item.missing}"
        }
    }
}

private fun sampleOffsetMs(meta: SegmentMeta, sampleIndex: ULong): Long {
    val base = meta.firstSampleIndex ?: sampleIndex
    val samples = if (sampleIndex >= base) sampleIndex - base else 0UL
    return (samples.toLong() * 1_000L) / meta.sampleRateHz.toLong()
}

private fun clockTimeFor(meta: SegmentMeta, offsetMs: Long): String =
    Formatting.timeOfDay(meta.receivedAtMs + offsetMs)

private const val QUIET_PAUSE_THRESHOLD_MS = 30_000L

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
