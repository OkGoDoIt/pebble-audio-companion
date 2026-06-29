package dev.audiocompanion.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.AiPlainText
import dev.audiocompanion.ai.AiPromptTemplate
import dev.audiocompanion.ai.AiPromptTemplates
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

enum class LibraryFilter(val label: String) {
    All("All"),
    Today("Today"),
    Actions("Actions"),
    Ai("AI"),
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
    actionItems: List<ActionItem> = emptyList(),
    aiOutputs: List<AiOutput> = emptyList(),
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
    onRunSegmentAi: suspend (AiPromptTemplate, String) -> Result<AiOutput> = { _, _ ->
        Result.failure(IllegalStateException("AI is not wired"))
    },
    onSetActionItemDone: (String, Boolean) -> Unit = { _, _ -> },
    onAskAboutSegment: (String) -> Unit = {},
    onOpenAiOutput: (String) -> Unit = {},
    onPlaySegment: (String) -> Unit,
    onPausePlayback: () -> Unit,
    onStopPlayback: () -> Unit,
    onSeekPlayback: (String, Long) -> Unit,
    onCyclePlaybackSpeed: () -> Unit,
    loadWaveform: suspend (String) -> SegmentWaveform? = { null },
) {
    var selectedSearchQuery by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedSearchOffsetMs by rememberSaveable { mutableStateOf<Long?>(null) }
    // Hoisted above the detail branch so a tag tapped inside Segment Detail can drop the user
    // back into the list filtered by that tag.
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(LibraryFilter.All) }
    var selectedTag by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = selectedSegmentId?.let { id -> segments.firstOrNull { it.segmentId == id } }
    if (selected != null) {
        SegmentDetailScreen(
            meta = selected,
            transcript = transcriptOf(selected.segmentId),
            liveTranscript = liveTranscriptOf(selected.segmentId),
            livePreview = livePreviewOf(selected.segmentId),
            liveTranscribedFrameCount = liveTranscribedFrameCountOf(selected.segmentId),
            annotation = annotationOf(selected.segmentId),
            searchQuery = selectedSearchQuery,
            initialSearchOffsetMs = selectedSearchOffsetMs,
            actionItems = actionItemsForSegment(actionItems, selected.segmentId),
            relatedAiOutputs = aiOutputsForSegment(aiOutputs, selected.segmentId),
            settings = settings,
            localModel = localModel,
            nowMs = nowMs,
            playback = playback,
            onBack = {
                selectedSearchQuery = null
                selectedSearchOffsetMs = null
                onSelectSegment(null)
            },
            onDelete = {
                onDeleteSegment(selected.segmentId)
                selectedSearchQuery = null
                selectedSearchOffsetMs = null
                onSelectSegment(null)
            },
            onExportSegment = onExportSegment,
            onShareFile = onShareFile,
            onReprocess = { onReprocessSegment(selected.segmentId) },
            onRunSegmentAi = onRunSegmentAi,
            onSetActionItemDone = onSetActionItemDone,
            onAskAboutSegment = { onAskAboutSegment(selected.segmentId) },
            onOpenAiOutput = onOpenAiOutput,
            onTagFilter = { tag ->
                selectedTag = tag
                selectedSearchQuery = null
                selectedSearchOffsetMs = null
                onSelectSegment(null)
            },
            onPlaySegment = onPlaySegment,
            onPausePlayback = onPausePlayback,
            onStopPlayback = onStopPlayback,
            onSeekPlayback = onSeekPlayback,
            onCyclePlaybackSpeed = onCyclePlaybackSpeed,
            loadWaveform = loadWaveform,
        )
        return
    }

    val tagCounts = libraryTagCounts(segments.mapNotNull { annotationOf(it.segmentId) })
    val debouncedQuery by produceState(initialValue = query, query) {
        if (query.isBlank()) {
            value = query
        } else {
            delay(LIBRARY_SEARCH_DEBOUNCE_MS)
            value = query
        }
    }
    val visible by produceState(
        initialValue = emptyList<LibrarySegmentSearchResult>(),
        segments,
        actionItems,
        aiOutputs,
        filter,
        selectedTag,
        debouncedQuery,
        nowMs,
    ) {
        val searchInputs = librarySearchInputs(
            segments = segments,
            transcriptOf = transcriptOf,
            annotationOf = annotationOf,
            actionItems = actionItems,
            aiOutputs = aiOutputs,
        )
        value = withContext(Dispatchers.Default) {
            libraryVisibleResults(
                inputs = searchInputs,
                filter = filter,
                selectedTag = selectedTag,
                query = debouncedQuery,
                nowMs = nowMs,
            )
        }
    }

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = Spacing.screenH)) {
        ScreenTitle("Library")
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("Search transcripts, summaries, tags") },
            leadingIcon = {
                Icon(Icons.Filled.Search, contentDescription = null, modifier = Modifier.size(20.dp))
            },
            trailingIcon = if (query.isNotEmpty()) {
                {
                    IconButton(onClick = { query = "" }) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear search", modifier = Modifier.size(18.dp))
                    }
                }
            } else {
                null
            },
            singleLine = true,
            shape = MaterialTheme.shapes.large,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = MaterialTheme.colorScheme.primary,
                unfocusedBorderColor = MaterialTheme.colorScheme.outlineVariant,
                focusedContainerColor = MaterialTheme.colorScheme.surface,
                unfocusedContainerColor = MaterialTheme.colorScheme.surface,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        // Single scrollable row instead of a wrapping block — keeps the list higher above the fold.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(vertical = Spacing.tight),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LibraryFilter.entries.forEach { candidate ->
                FilterChip(
                    selected = filter == candidate,
                    onClick = { filter = candidate },
                    label = { Text(candidate.label) },
                )
            }
        }
        if (tagCounts.isNotEmpty()) {
            LibraryTagFilter(
                tagCounts = tagCounts,
                selectedTag = selectedTag,
                onSelectTag = { tag -> selectedTag = tag },
            )
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
                items(visible, key = { it.meta.segmentId }) { result ->
                    val meta = result.meta
                    val transcript = transcriptOf(meta.segmentId)
                    val annotation = annotationOf(meta.segmentId)
                    val segmentActionItems = actionItemsForSegment(actionItems, meta.segmentId)
                    val relatedOutputs = aiOutputsForSegment(aiOutputs, meta.segmentId)
                    val searchMatch = result.match
                    LibrarySegmentRow(
                        meta = meta,
                        transcript = transcript,
                        liveText = liveTranscriptOf(meta.segmentId),
                        annotation = annotation,
                        actionItems = segmentActionItems,
                        relatedAiOutputs = relatedOutputs,
                        searchQuery = debouncedQuery,
                        searchMatch = searchMatch,
                        nowMs = nowMs,
                        onClick = {
                            if (searchMatch?.kind == LibrarySearchMatchKind.Transcript) {
                                selectedSearchQuery = searchMatch.highlightTerm
                                    ?: debouncedQuery.trim().takeIf { it.isNotBlank() }
                                selectedSearchOffsetMs = searchMatch.startMs
                            } else {
                                selectedSearchQuery = null
                                selectedSearchOffsetMs = null
                            }
                            onSelectSegment(meta.segmentId)
                        },
                        onTagClick = { selectedTag = it },
                    )
                }
            }
        }
    }
}

private const val TOP_LIBRARY_TAGS = 6

/**
 * Compact tag filter: a single horizontally-scrollable row of the most common tags plus an
 * "All tags" control that reveals a type-to-filter picker. Replaces the old wall of every tag,
 * which could fill the whole screen once a library accumulated dozens of them.
 */
@Composable
private fun LibraryTagFilter(
    tagCounts: List<LibraryTagCount>,
    selectedTag: String?,
    onSelectTag: (String?) -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    var tagQuery by rememberSaveable { mutableStateOf("") }
    val topTags = tagCounts.take(TOP_LIBRARY_TAGS)
    val selectedInTop = selectedTag != null &&
        topTags.any { it.tag.equals(selectedTag, ignoreCase = true) }
    val hasMore = tagCounts.size > topTags.size

    Column(
        modifier = Modifier.padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // A selected tag that isn't among the common ones still needs to be visible and
            // removable, so surface it first as a chip with a clear affordance.
            if (selectedTag != null && !selectedInTop) {
                InputChip(
                    selected = true,
                    onClick = { onSelectTag(null) },
                    label = { Text(selectedTag) },
                    trailingIcon = {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = "Clear tag filter",
                            modifier = Modifier.size(16.dp),
                        )
                    },
                )
            }
            topTags.forEach { (tag, _) ->
                val isSelected = selectedTag.equals(tag, ignoreCase = true)
                FilterChip(
                    selected = isSelected,
                    onClick = { onSelectTag(if (isSelected) null else tag) },
                    label = { Text(tag) },
                )
            }
            if (hasMore) {
                FilterChip(
                    selected = expanded,
                    onClick = {
                        expanded = !expanded
                        if (!expanded) tagQuery = ""
                    },
                    label = { Text("All tags") },
                    trailingIcon = {
                        Icon(
                            if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                )
            }
        }
        if (expanded && hasMore) {
            TagPickerPanel(
                tagCounts = tagCounts,
                tagQuery = tagQuery,
                onQueryChange = { tagQuery = it },
                selectedTag = selectedTag,
                onPick = { tag ->
                    onSelectTag(tag)
                    expanded = false
                    tagQuery = ""
                },
            )
        }
    }
}

@Composable
private fun TagPickerPanel(
    tagCounts: List<LibraryTagCount>,
    tagQuery: String,
    onQueryChange: (String) -> Unit,
    selectedTag: String?,
    onPick: (String?) -> Unit,
) {
    val filtered = remember(tagCounts, tagQuery) {
        val q = tagQuery.trim()
        if (q.isBlank()) tagCounts else tagCounts.filter { it.tag.contains(q, ignoreCase = true) }
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            OutlinedTextField(
                value = tagQuery,
                onValueChange = onQueryChange,
                label = { Text("Filter tags") },
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                modifier = Modifier.fillMaxWidth(),
            )
            if (selectedTag != null) {
                TextButton(onClick = { onPick(null) }) { Text("Clear tag filter") }
            }
            if (filtered.isEmpty()) {
                Text(
                    text = "No tags match \"${tagQuery.trim()}\".",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            } else {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 260.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    filtered.forEach { (tag, count) ->
                        val isSelected = selectedTag.equals(tag, ignoreCase = true)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onPick(if (isSelected) null else tag) }
                                .padding(vertical = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = tag,
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (isSelected) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurface
                                },
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                text = count.toString(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
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
    actionItems: List<ActionItem>,
    relatedAiOutputs: List<AiOutput>,
    searchQuery: String,
    searchMatch: LibrarySearchMatch?,
    nowMs: Long,
    onClick: () -> Unit,
    onTagClick: (String) -> Unit = {},
) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    text = segmentTitle(meta, transcript, annotation, liveText),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                SegmentStateBadge(meta)
            }
            Text(
                text = "${Formatting.shortDate(meta.receivedAtMs, nowMs)} · " +
                    "${Formatting.timeOfDay(meta.receivedAtMs)} · " +
                    Formatting.duration(segmentDurationMs(meta)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            AiPlainText.clean(annotation?.summary)?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            SegmentTagRow(annotation?.tags.orEmpty(), onTagClick = onTagClick)
            gapSummary(meta)?.let { summary ->
                Text(
                    text = summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = StatusColors.warning,
                )
            }
            searchMatch?.let { match ->
                SearchMatchRow(match = match, query = searchQuery)
            }
            LibraryAiSignalRow(actionItems = actionItems, relatedAiOutputs = relatedAiOutputs)
        }
    }
}

@Composable
private fun SearchMatchRow(match: LibrarySearchMatch, query: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = match.label,
            style = MaterialTheme.typography.labelMedium,
            color = StatusColors.info,
        )
        SearchHighlightedText(
            text = match.snippet,
            query = match.highlightTerm ?: query,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
        )
    }
}

private data class LibrarySegmentSearchResult(
    val meta: SegmentMeta,
    val match: LibrarySearchMatch?,
)

private data class LibrarySegmentSearchInput(
    val meta: SegmentMeta,
    val transcript: SegmentTranscript?,
    val annotation: SegmentAnnotation?,
    val actionItems: List<ActionItem>,
    val aiOutputs: List<AiOutput>,
)

private fun librarySearchInputs(
    segments: List<SegmentMeta>,
    transcriptOf: (String) -> SegmentTranscript?,
    annotationOf: (String) -> SegmentAnnotation?,
    actionItems: List<ActionItem>,
    aiOutputs: List<AiOutput>,
): List<LibrarySegmentSearchInput> {
    val actionsBySegment = actionItems.groupBy { it.sourceSegmentId }
    val outputsBySegment = linkedMapOf<String, MutableList<AiOutput>>()
    aiOutputs.forEach { output ->
        output.segmentIds.forEach { segmentId ->
            outputsBySegment.getOrPut(segmentId) { mutableListOf() } += output
        }
    }
    return segments.map { meta ->
        LibrarySegmentSearchInput(
            meta = meta,
            transcript = transcriptOf(meta.segmentId),
            annotation = annotationOf(meta.segmentId),
            actionItems = actionsBySegment[meta.segmentId].orEmpty(),
            aiOutputs = outputsBySegment[meta.segmentId].orEmpty(),
        )
    }
}

private fun libraryVisibleResults(
    inputs: List<LibrarySegmentSearchInput>,
    filter: LibraryFilter,
    selectedTag: String?,
    query: String,
    nowMs: Long,
): List<LibrarySegmentSearchResult> {
    val filtered = inputs
        .sortedByDescending { it.meta.receivedAtMs }
        .filter { input ->
            when (filter) {
                LibraryFilter.All -> true
                LibraryFilter.Today -> Formatting.isSameLocalDay(input.meta.receivedAtMs, nowMs)
                LibraryFilter.Actions -> input.actionItems.any { !it.done }
                LibraryFilter.Ai -> input.annotation?.hasContent == true || input.aiOutputs.isNotEmpty()
                // Silence the watch skipped to save power is not a gap, so a segment that
                // only has those does not belong in the "Gaps" filter.
                LibraryFilter.Gaps -> visibleLossGaps(input.meta).isNotEmpty()
                LibraryFilter.Untranscribed -> !input.meta.isFullyTranscribed
            }
        }
        .filter { input ->
            selectedTag == null || annotationHasTag(input.annotation, selectedTag)
        }

    if (query.isBlank()) {
        return filtered.map { input ->
            LibrarySegmentSearchResult(meta = input.meta, match = null)
        }
    }

    return filtered
        .mapNotNull { input ->
            librarySearchMatch(
                query = query,
                meta = input.meta,
                transcript = input.transcript,
                annotation = input.annotation,
                actionItems = input.actionItems,
                aiOutputs = input.aiOutputs,
            )?.let { match ->
                LibrarySegmentSearchResult(meta = input.meta, match = match)
            }
        }
        .sortedWith(
            compareByDescending<LibrarySegmentSearchResult> { it.match?.score ?: 0 }
                .thenByDescending { it.meta.receivedAtMs },
        )
}

@Composable
private fun SegmentTagRow(tags: List<String>, onTagClick: (String) -> Unit = {}) {
    val cleanTags = tags.mapNotNull { AiPlainText.clean(it, maxChars = 28) }.take(4)
    if (cleanTags.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        cleanTags.forEach { tag -> TagChip(tag, onClick = { onTagClick(tag) }) }
    }
}

/** Compact, lightweight tag pill — quieter than an AssistChip so dense cards stay calm. */
@Composable
private fun TagChip(tag: String, onClick: () -> Unit) {
    Text(
        text = tag,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .clickable(onClick = onClick)
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

@Composable
private fun LibraryAiSignalRow(actionItems: List<ActionItem>, relatedAiOutputs: List<AiOutput>) {
    val openActions = actionItems.count { !it.done }
    if (openActions == 0 && relatedAiOutputs.isEmpty()) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (openActions > 0) {
            Text(
                text = "$openActions action${if (openActions == 1) "" else "s"}",
                style = MaterialTheme.typography.bodySmall,
                color = StatusColors.warning,
            )
        }
        if (relatedAiOutputs.isNotEmpty()) {
            Text(
                text = "${relatedAiOutputs.size} AI output${if (relatedAiOutputs.size == 1) "" else "s"}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A library tag with how many segments carry it, frequency-sorted. */
data class LibraryTagCount(val tag: String, val count: Int)

fun libraryTagCounts(annotations: List<SegmentAnnotation>): List<LibraryTagCount> {
    val counts = linkedMapOf<String, Pair<String, Int>>()
    annotations
        .flatMap { it.tags }
        .mapNotNull { AiPlainText.clean(it, maxChars = 32) }
        .forEach { tag ->
            val key = tag.lowercase()
            val existing = counts[key]
            counts[key] = (existing?.first ?: tag) to ((existing?.second ?: 0) + 1)
        }
    return counts.values
        .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first.lowercase() })
        .map { LibraryTagCount(it.first, it.second) }
}

fun libraryTags(annotations: List<SegmentAnnotation>): List<String> =
    libraryTagCounts(annotations).map { it.tag }

fun annotationHasTag(annotation: SegmentAnnotation?, tag: String?): Boolean {
    if (annotation == null || tag.isNullOrBlank()) return false
    return annotation.tags.any { it.equals(tag, ignoreCase = true) }
}

fun actionItemsForSegment(actionItems: List<ActionItem>, segmentId: String): List<ActionItem> =
    actionItems.filter { it.sourceSegmentId == segmentId }

fun aiOutputsForSegment(aiOutputs: List<AiOutput>, segmentId: String): List<AiOutput> =
    aiOutputs.filter { segmentId in it.segmentIds }

fun segmentMatchesLibraryQuery(
    query: String,
    transcript: SegmentTranscript?,
    annotation: SegmentAnnotation?,
    actionItems: List<ActionItem>,
    aiOutputs: List<AiOutput>,
): Boolean {
    val parts = libraryQueryParts(query) ?: return true
    val searchableText = buildList {
        add(transcript?.text)
        add(annotation?.title)
        add(annotation?.summary)
        addAll(annotation?.tags.orEmpty())
        addAll(actionItems.map { it.text })
        aiOutputs.forEach { output ->
            add(output.promptTitle)
            add(output.text)
        }
    }
    if (searchableText.any { scoreLibraryText(parts, it, weight = 0) != null }) return true
    return parts.terms.size > 1 &&
        parts.terms.all { term ->
            searchableText.any { scoreLibraryTermText(term, it, weight = 0) != null }
        }
}

enum class LibrarySearchMatchKind {
    Transcript,
    Title,
    Summary,
    Tag,
    ActionItem,
    AiOutput,
}

data class LibrarySearchMatch(
    val kind: LibrarySearchMatchKind,
    val label: String,
    val snippet: String,
    val startMs: Long? = null,
    val highlightTerm: String? = null,
    val score: Int = 0,
)

fun librarySearchMatch(
    query: String,
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    annotation: SegmentAnnotation?,
    actionItems: List<ActionItem>,
    aiOutputs: List<AiOutput>,
): LibrarySearchMatch? {
    val parts = libraryQueryParts(query) ?: return null
    val candidates = librarySearchCandidates(meta, transcript, annotation, actionItems, aiOutputs)
    return candidates
        .mapIndexedNotNull { index, candidate ->
            scoreLibraryCandidate(parts, candidate)?.let { score ->
                ScoredLibrarySearchCandidate(index, candidate, score)
            }
        }
        .sortedWith(
            compareByDescending<ScoredLibrarySearchCandidate> { it.textScore.score }
                .thenBy { it.index },
        )
        .firstOrNull()
        ?.toMatch()
        ?: aggregateLibrarySearchMatch(parts, candidates)?.toMatch()
}

private fun librarySearchCandidates(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    annotation: SegmentAnnotation?,
    actionItems: List<ActionItem>,
    aiOutputs: List<AiOutput>,
): List<LibrarySearchCandidate> {
    val candidates = mutableListOf<LibrarySearchCandidate>()
    if (transcript != null) {
        transcriptTimelineItems(meta, transcript.segments, transcript.words)
            .filterIsInstance<TranscriptTimelineItem.Speech>()
            .forEach { speech ->
                candidates += LibrarySearchCandidate(
                    kind = LibrarySearchMatchKind.Transcript,
                    label = "Transcript match · ${clockTimeFor(meta, speech.startMs)}",
                    text = speech.text,
                    startMs = speech.startMs,
                    weight = 920,
                )
            }
        candidates += LibrarySearchCandidate(
            kind = LibrarySearchMatchKind.Transcript,
            label = "Transcript match",
            text = transcript.text,
            weight = 880,
        )
    }
    candidates += LibrarySearchCandidate(
        kind = LibrarySearchMatchKind.Title,
        label = "Title match",
        text = annotation?.title,
        weight = 850,
    )
    candidates += LibrarySearchCandidate(
        kind = LibrarySearchMatchKind.Summary,
        label = "Summary match",
        text = annotation?.summary,
        weight = 580,
    )
    annotation?.tags.orEmpty().forEach { tag ->
        candidates += LibrarySearchCandidate(
            kind = LibrarySearchMatchKind.Tag,
            label = "Tag match",
            text = tag,
            weight = 760,
        )
    }
    actionItems.forEach { item ->
        candidates += LibrarySearchCandidate(
            kind = LibrarySearchMatchKind.ActionItem,
            label = "Action item match",
            text = item.text,
            weight = 620,
        )
    }
    aiOutputs.forEach { output ->
        candidates += LibrarySearchCandidate(
            kind = LibrarySearchMatchKind.AiOutput,
            label = "AI output match",
            text = output.promptTitle,
            weight = 520,
        )
        candidates += LibrarySearchCandidate(
            kind = LibrarySearchMatchKind.AiOutput,
            label = "AI output match",
            text = output.text,
            weight = 480,
        )
    }
    return candidates
}

private data class LibrarySearchCandidate(
    val kind: LibrarySearchMatchKind,
    val label: String,
    val text: String?,
    val weight: Int,
    val startMs: Long? = null,
)

private data class ScoredLibrarySearchCandidate(
    val index: Int,
    val candidate: LibrarySearchCandidate,
    val textScore: LibraryTextSearchScore,
) {
    fun toMatch(): LibrarySearchMatch = LibrarySearchMatch(
        kind = candidate.kind,
        label = candidate.label,
        snippet = textScore.snippet,
        startMs = candidate.startMs,
        highlightTerm = textScore.highlightTerm,
        score = textScore.score,
    )
}

private data class LibraryQueryParts(
    val phrase: String,
    val terms: List<String>,
)

private data class LibraryTextSearchScore(
    val score: Int,
    val snippet: String,
    val highlightTerm: String,
)

private data class LibraryTermMatch(
    val start: Int,
    val end: Int,
    val text: String,
    val exact: Boolean,
    val distance: Int,
)

private data class LibrarySearchToken(
    val text: String,
    val start: Int,
    val end: Int,
)

private fun libraryQueryParts(query: String): LibraryQueryParts? {
    val phrase = normalizeSearchText(query)
    if (phrase.isBlank()) return null
    val terms = searchTokens(phrase)
        .map { it.text.lowercase() }
        .filter { it.length >= 2 }
        .distinct()
    return LibraryQueryParts(phrase = phrase, terms = terms)
}

private fun scoreLibraryCandidate(
    parts: LibraryQueryParts,
    candidate: LibrarySearchCandidate,
): LibraryTextSearchScore? =
    scoreLibraryText(parts = parts, text = candidate.text, weight = candidate.weight)

private fun aggregateLibrarySearchMatch(
    parts: LibraryQueryParts,
    candidates: List<LibrarySearchCandidate>,
): ScoredLibrarySearchCandidate? {
    if (parts.terms.size < 2) return null
    val bestPerTerm = parts.terms.map { term ->
        candidates
            .mapIndexedNotNull { index, candidate ->
                scoreLibraryTerm(candidate = candidate, term = term)?.let { score ->
                    ScoredLibrarySearchCandidate(index, candidate, score)
                }
            }
            .sortedWith(
                compareByDescending<ScoredLibrarySearchCandidate> { it.textScore.score }
                    .thenBy { it.index },
            )
            .firstOrNull()
            ?: return null
    }
    val display = bestPerTerm
        .sortedWith(
            compareByDescending<ScoredLibrarySearchCandidate> { it.textScore.score }
                .thenBy { it.index },
        )
        .first()
    val fieldSpreadPenalty = (bestPerTerm.map { it.index }.distinct().size - 1).coerceAtLeast(0) * 80
    val coverageScore = 4_500 +
        bestPerTerm.sumOf { (it.textScore.score / 20).coerceAtMost(140) } -
        fieldSpreadPenalty +
        display.candidate.weight
    return display.copy(textScore = display.textScore.copy(score = coverageScore))
}

private fun scoreLibraryTerm(
    candidate: LibrarySearchCandidate,
    term: String,
): LibraryTextSearchScore? =
    scoreLibraryTermText(term = term, text = candidate.text, weight = candidate.weight)

private fun scoreLibraryText(
    parts: LibraryQueryParts,
    text: String?,
    weight: Int,
): LibraryTextSearchScore? {
    val normalized = normalizeSearchText(text)
    if (normalized.isBlank()) return null

    val phraseIndex = normalized.indexOf(parts.phrase, ignoreCase = true)
    if (phraseIndex >= 0) {
        val highlightTerm = normalized.substring(phraseIndex, phraseIndex + parts.phrase.length)
        return LibraryTextSearchScore(
            score = weight + 10_000 + parts.phrase.length.coerceAtMost(160),
            snippet = snippetAround(normalized, phraseIndex, parts.phrase.length),
            highlightTerm = highlightTerm,
        )
    }

    if (parts.terms.isEmpty()) return null
    val tokens = searchTokens(normalized)
    val matches = parts.terms.map { term ->
        exactTermMatch(normalized, term) ?: fuzzyTermMatch(tokens, term) ?: return null
    }
    val first = matches.minBy { it.start }
    val spanStart = matches.minOf { it.start }
    val spanEnd = matches.maxOf { it.end }
    val proximityBonus = (240 - ((spanEnd - spanStart) / 8)).coerceIn(0, 240)
    val exactCount = matches.count { it.exact }
    val fuzzyCount = matches.size - exactCount
    val distancePenalty = matches.sumOf { it.distance } * 45
    return LibraryTextSearchScore(
        score = weight + 6_000 + (exactCount * 220) + (fuzzyCount * 110) +
            proximityBonus - distancePenalty,
        snippet = snippetAround(normalized, first.start, (first.end - first.start).coerceAtLeast(1)),
        highlightTerm = first.text,
    )
}

private fun scoreLibraryTermText(
    term: String,
    text: String?,
    weight: Int,
): LibraryTextSearchScore? {
    val normalized = normalizeSearchText(text)
    if (normalized.isBlank()) return null
    val match = exactTermMatch(normalized, term)
        ?: fuzzyTermMatch(searchTokens(normalized), term)
        ?: return null
    val score = weight + if (match.exact) {
        1_000
    } else {
        740 - (match.distance * 80)
    }
    return LibraryTextSearchScore(
        score = score,
        snippet = snippetAround(normalized, match.start, (match.end - match.start).coerceAtLeast(1)),
        highlightTerm = match.text,
    )
}

private fun exactTermMatch(text: String, term: String): LibraryTermMatch? {
    val index = text.indexOf(term, ignoreCase = true)
    if (index < 0) return null
    val end = (index + term.length).coerceAtMost(text.length)
    return LibraryTermMatch(
        start = index,
        end = end,
        text = text.substring(index, end),
        exact = true,
        distance = 0,
    )
}

private fun fuzzyTermMatch(tokens: List<LibrarySearchToken>, term: String): LibraryTermMatch? {
    if (term.length < 3) return null
    val threshold = fuzzyDistanceThreshold(term)
    return tokens
        .asSequence()
        .take(MAX_FUZZY_TOKENS_PER_FIELD)
        .filter { token ->
            token.text.length <= MAX_FUZZY_TOKEN_CHARS &&
                abs(token.text.length - term.length) <= threshold
        }
        .mapNotNull { token ->
            val distance = levenshteinDistanceAtMost(term, token.text.lowercase(), threshold)
            if (distance <= threshold) {
                LibraryTermMatch(
                    start = token.start,
                    end = token.end,
                    text = token.text,
                    exact = false,
                    distance = distance,
                )
            } else {
                null
            }
        }
        .sortedWith(compareBy<LibraryTermMatch> { it.distance }.thenBy { it.start })
        .firstOrNull()
}

private fun fuzzyDistanceThreshold(term: String): Int = when {
    term.length <= 4 -> 1
    term.length <= 8 -> 2
    else -> 3
}

private fun levenshteinDistanceAtMost(a: String, b: String, maxDistance: Int): Int {
    if (abs(a.length - b.length) > maxDistance) return maxDistance + 1
    var previous = IntArray(b.length + 1) { it }
    var current = IntArray(b.length + 1)
    for (i in 1..a.length) {
        current[0] = i
        var rowMin = current[0]
        for (j in 1..b.length) {
            val substitutionCost = if (a[i - 1] == b[j - 1]) 0 else 1
            current[j] = minOf(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + substitutionCost,
            )
            rowMin = minOf(rowMin, current[j])
        }
        if (rowMin > maxDistance) return maxDistance + 1
        val swap = previous
        previous = current
        current = swap
    }
    return previous[b.length]
}

private fun normalizeSearchText(text: String?): String =
    text
        ?.replace(Regex("\\s+"), " ")
        ?.trim()
        .orEmpty()

private fun searchTokens(text: String): List<LibrarySearchToken> {
    val tokens = mutableListOf<LibrarySearchToken>()
    var start: Int? = null
    text.forEachIndexed { index, char ->
        if (char.isLetterOrDigit()) {
            if (start == null) start = index
        } else {
            start?.let { tokenStart ->
                tokens += LibrarySearchToken(text.substring(tokenStart, index), tokenStart, index)
                start = null
            }
        }
    }
    start?.let { tokenStart ->
        tokens += LibrarySearchToken(text.substring(tokenStart), tokenStart, text.length)
    }
    return tokens
}

private fun snippetAround(
    normalized: String,
    index: Int,
    length: Int,
    maxChars: Int = 170,
): String {
    val radius = ((maxChars - length) / 2).coerceAtLeast(24)
    var start = (index - radius).coerceAtLeast(0)
    var end = (index + length + radius).coerceAtMost(normalized.length)
    while (start > 0 && !normalized[start - 1].isWhitespace()) start--
    while (end < normalized.length && !normalized[end].isWhitespace()) end++
    val prefix = if (start > 0) "..." else ""
    val suffix = if (end < normalized.length) "..." else ""
    return prefix + normalized.substring(start, end).trim() + suffix
}

fun searchSnippet(text: String?, query: String, maxChars: Int = 170): String? {
    val normalized = normalizeSearchText(text)
    if (normalized.isBlank()) return null
    val trimmed = query.trim()
    if (trimmed.isBlank()) return null
    val index = normalized.indexOf(trimmed, ignoreCase = true)
    if (index < 0) return null
    return snippetAround(normalized, index, trimmed.length, maxChars)
}

private const val MAX_FUZZY_TOKENS_PER_FIELD = 2_500
private const val MAX_FUZZY_TOKEN_CHARS = 36
private const val LIBRARY_SEARCH_DEBOUNCE_MS = 180L

@Composable
fun SegmentDetailScreen(
    meta: SegmentMeta,
    transcript: SegmentTranscript?,
    liveTranscript: String? = null,
    livePreview: LiveTranscriptPreview? = null,
    /** Live-transcribed frame count of the open segment, for waveform coloring. */
    liveTranscribedFrameCount: Long? = null,
    annotation: SegmentAnnotation?,
    searchQuery: String? = null,
    initialSearchOffsetMs: Long? = null,
    actionItems: List<ActionItem> = emptyList(),
    relatedAiOutputs: List<AiOutput> = emptyList(),
    settings: AudioCompanionSettings,
    localModel: LocalTranscriptionModelState,
    nowMs: Long,
    playback: PlaybackUiState,
    onBack: () -> Unit,
    onDelete: () -> Unit,
    onExportSegment: suspend (String) -> Result<AudioExportResult>,
    onShareFile: (String) -> Unit = {},
    onReprocess: () -> Unit = {},
    onRunSegmentAi: suspend (AiPromptTemplate, String) -> Result<AiOutput> = { _, _ ->
        Result.failure(IllegalStateException("AI is not wired"))
    },
    onSetActionItemDone: (String, Boolean) -> Unit = { _, _ -> },
    onAskAboutSegment: () -> Unit = {},
    onOpenAiOutput: (String) -> Unit = {},
    onTagFilter: (String) -> Unit = {},
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
    var aiRunMessage by remember(meta.segmentId) { mutableStateOf<String?>(null) }
    var runningAiTemplateId by remember(meta.segmentId) { mutableStateOf<String?>(null) }
    var searchTargetApplied by remember(meta.segmentId, searchQuery, initialSearchOffsetMs) {
        mutableStateOf(false)
    }
    val scope = rememberCoroutineScope()
    val scrollState = rememberScrollState()
    // Decoded off the UI path; re-built when more audio is stored (open segment grows).
    var waveform by remember(meta.segmentId) { mutableStateOf<SegmentWaveform?>(null) }
    LaunchedEffect(meta.segmentId, meta.frameCount) {
        waveform = loadWaveform(meta.segmentId)
    }
    val shareSegmentAudio = {
        if (!exporting) {
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
        }
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onBack) { Text("< Library") }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (meta.frameCount > 0) {
                    IconButton(
                        enabled = !exporting,
                        onClick = shareSegmentAudio,
                    ) {
                        if (exporting) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Filled.Share, contentDescription = "Share WAV")
                        }
                    }
                }
                if (!meta.isOpen) {
                    TextButton(onClick = { confirmDelete = true }) {
                        Text("Delete", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
        Text(
            text = segmentTitle(meta, transcript, annotation, liveTranscript),
            style = MaterialTheme.typography.headlineSmall,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "${Formatting.shortDate(meta.receivedAtMs, nowMs)} · " +
                    "${Formatting.timeOfDay(meta.receivedAtMs)} · " +
                    Formatting.duration(segmentDurationMs(meta)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SegmentStateBadge(meta)
        }

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
        val annotationTags = annotation?.tags.orEmpty()
        if (annotationTags.isNotEmpty()) {
            SegmentTagRow(annotationTags, onTagClick = onTagFilter)
        }
        // Only surface the AI section when there's something actionable: the run actions when the
        // segment has a durable transcript, or saved outputs/actions to show. An empty disabled
        // block was just wasting space (user feedback).
        val canRunAi = !meta.isOpen && transcript != null
        val hasAiContent = actionItems.isNotEmpty() || relatedAiOutputs.isNotEmpty()
        if (canRunAi || hasAiContent) {
            SectionTitle("AI")
            if (canRunAi) {
                SegmentAiActions(
                    runningTemplateId = runningAiTemplateId,
                    message = aiRunMessage,
                    onAskAboutSegment = onAskAboutSegment,
                    onRunTemplate = { template ->
                        if (runningAiTemplateId != null) return@SegmentAiActions
                        runningAiTemplateId = template.id
                        aiRunMessage = null
                        scope.launch {
                            val result = onRunSegmentAi(template, meta.segmentId)
                            runningAiTemplateId = null
                            aiRunMessage = result.fold(
                                onSuccess = { "${template.title} saved." },
                                onFailure = { "AI failed: ${it.message ?: it::class.simpleName}" },
                            )
                        }
                    },
                )
            }
            SegmentActionItems(
                items = actionItems,
                onSetDone = onSetActionItemDone,
            )
            SegmentRelatedAiOutputs(
                outputs = relatedAiOutputs,
                nowMs = nowMs,
                onOpenOutput = onOpenAiOutput,
            )
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
                    searchQuery = searchQuery,
                    initialSearchOffsetMs = initialSearchOffsetMs,
                    onInitialTargetVisible = { targetMs ->
                        if (!searchTargetApplied) {
                            searchTargetApplied = true
                            onSeekPlayback(meta.segmentId, targetMs)
                        }
                    },
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
private fun SegmentAiActions(
    runningTemplateId: String?,
    message: String?,
    onAskAboutSegment: () -> Unit,
    onRunTemplate: (AiPromptTemplate) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        // One compact row of equal-weight actions: Ask is primary, the two templates are
        // one-tap runs. Short labels keep all three on a single line on a phone.
        val compactPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Button(
                onClick = onAskAboutSegment,
                contentPadding = compactPadding,
                modifier = Modifier.weight(1f),
            ) {
                Text("Ask", maxLines = 1)
            }
            OutlinedButton(
                enabled = runningTemplateId == null,
                onClick = { onRunTemplate(AiPromptTemplates.ActionItems) },
                contentPadding = compactPadding,
                modifier = Modifier.weight(1f),
            ) {
                Text("Actions", maxLines = 1)
            }
            OutlinedButton(
                enabled = runningTemplateId == null,
                onClick = { onRunTemplate(AiPromptTemplates.MeetingNotes) },
                contentPadding = compactPadding,
                modifier = Modifier.weight(1f),
            ) {
                Text("Notes", maxLines = 1)
            }
        }
        if (runningTemplateId != null) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator()
                Text("Running AI…", style = MaterialTheme.typography.bodySmall)
            }
        }
        message?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SegmentActionItems(
    items: List<ActionItem>,
    onSetDone: (String, Boolean) -> Unit,
) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Action items", style = MaterialTheme.typography.titleSmall)
        items.sortedWith(compareBy<ActionItem> { it.done }.thenByDescending { it.createdAtMs })
            .forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Checkbox(
                        checked = item.done,
                        onCheckedChange = { onSetDone(item.id, it) },
                    )
                    Text(
                        text = item.text,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (item.done) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
    }
}

@Composable
private fun SegmentRelatedAiOutputs(
    outputs: List<AiOutput>,
    nowMs: Long,
    onOpenOutput: (String) -> Unit,
) {
    if (outputs.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Related AI outputs", style = MaterialTheme.typography.titleSmall)
        // Tapping an output jumps to the full answer in the AI tab. Model name is intentionally
        // omitted here — it's noise in a list; the full provenance lives on the output detail.
        outputs.sortedByDescending { it.createdAtMs }.take(4).forEach { output ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onOpenOutput(output.outputId) },
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(output.promptTitle, style = MaterialTheme.typography.bodyMedium)
                Text(
                    text = Formatting.relativeTime(output.createdAtMs, nowMs),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                AiPlainText.clean(output.text, maxChars = 160)?.let { preview ->
                    Text(
                        text = preview,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun TranscriptTimeline(
    meta: SegmentMeta,
    text: String,
    segments: List<TranscriptSegment>,
    words: List<TranscriptWord>,
    searchQuery: String? = null,
    initialSearchOffsetMs: Long? = null,
    onInitialTargetVisible: (Long) -> Unit = {},
    onSeekMs: (Long) -> Unit,
) {
    val timed = transcriptTimelineItems(meta, segments, words)
    if (timed.isEmpty()) {
        TranscriptParagraphs(text = text, searchQuery = searchQuery)
        return
    }
    val cleanSearchQuery = searchQuery?.trim()?.takeIf { it.isNotBlank() }
    val targetStartMs = initialSearchOffsetMs ?: cleanSearchQuery?.let { query ->
        timed.filterIsInstance<TranscriptTimelineItem.Speech>()
            .firstOrNull { it.text.contains(query, ignoreCase = true) }
            ?.startMs
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
                            searchQuery = cleanSearchQuery,
                            highlighted = item.startMs == targetStartMs,
                            onInitialTargetVisible = onInitialTargetVisible,
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
private fun TranscriptParagraphs(text: String, searchQuery: String? = null) {
    val paragraphs = transcriptParagraphs(text)
    val cleanSearchQuery = searchQuery?.trim()?.takeIf { it.isNotBlank() }
    val targetIndex = cleanSearchQuery?.let { query ->
        paragraphs.indexOfFirst { it.contains(query, ignoreCase = true) }.takeIf { it >= 0 }
    }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            paragraphs.forEachIndexed { index, paragraph ->
                SearchTargetColumn(
                    active = index == targetIndex,
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (paragraphs.size > 1) {
                        Text(
                            text = "Transcript section ${index + 1}",
                            style = MaterialTheme.typography.labelMedium,
                            color = StatusColors.info,
                        )
                    }
                    SearchHighlightedText(
                        text = paragraph,
                        query = cleanSearchQuery,
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
@OptIn(ExperimentalFoundationApi::class)
private fun SearchTargetColumn(
    active: Boolean,
    verticalArrangement: Arrangement.Vertical,
    content: @Composable () -> Unit,
) {
    val requester = remember { BringIntoViewRequester() }
    LaunchedEffect(active) {
        if (active) {
            delay(120)
            requester.bringIntoView()
        }
    }
    Column(
        modifier = if (active) {
            Modifier
                .bringIntoViewRequester(requester)
                .background(
                    MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.24f),
                    RoundedCornerShape(6.dp),
                )
                .padding(6.dp)
        } else {
            Modifier
        },
        verticalArrangement = verticalArrangement,
    ) {
        content()
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun SpeechTimelineRow(
    timestamp: String?,
    item: TranscriptTimelineItem.Speech,
    searchQuery: String?,
    highlighted: Boolean,
    onInitialTargetVisible: (Long) -> Unit,
    onSeekMs: (Long) -> Unit,
) {
    val speaker = item.speaker
    val accent = speaker?.let(::speakerColor)
    val requester = remember { BringIntoViewRequester() }
    LaunchedEffect(highlighted, item.startMs) {
        if (highlighted) {
            delay(120)
            requester.bringIntoView()
            onInitialTargetVisible(item.startMs)
        }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (highlighted) {
                    Modifier
                        .bringIntoViewRequester(requester)
                        .background(
                            MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.24f),
                            RoundedCornerShape(6.dp),
                        )
                        .padding(vertical = 3.dp)
                } else {
                    Modifier
                },
            )
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
        SearchHighlightedText(
            text = item.text,
            query = searchQuery,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun SearchHighlightedText(
    text: String,
    query: String?,
    style: TextStyle,
    modifier: Modifier = Modifier,
    color: Color = Color.Unspecified,
    maxLines: Int = Int.MAX_VALUE,
) {
    val cleanQuery = query?.trim()?.takeIf { it.isNotBlank() }
    val start = cleanQuery?.let { text.indexOf(it, ignoreCase = true) } ?: -1
    if (cleanQuery == null || start < 0) {
        Text(
            text = text,
            style = style,
            color = color,
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
            modifier = modifier,
        )
        return
    }
    val highlightColor = MaterialTheme.colorScheme.primaryContainer
    val annotated = buildAnnotatedString {
        append(text.substring(0, start))
        pushStyle(SpanStyle(background = highlightColor))
        append(text.substring(start, start + cleanQuery.length))
        pop()
        append(text.substring(start + cleanQuery.length))
    }
    Text(
        text = annotated,
        style = style,
        color = color,
        maxLines = maxLines,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier,
    )
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
        Text(
            text = "${Formatting.duration(positionMs)} / ${Formatting.duration(durationMs)}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (meta.isOpen) {
            Text(
                text = "Still recording — playback follows what has been stored so far.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val isPlaying = selected && playback.playing
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilledTonalButton(
                onClick = { if (isPlaying) onPausePlayback() else onPlaySegment(meta.segmentId) },
                modifier = Modifier.weight(1f),
            ) {
                Icon(
                    imageVector = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Text(if (isPlaying) "Pause" else "Play", modifier = Modifier.padding(start = 6.dp))
            }
            OutlinedButton(
                onClick = onStopPlayback,
                enabled = selected && (playback.playing || playback.positionMs > 0),
            ) {
                Icon(Icons.Filled.Stop, contentDescription = "Stop", modifier = Modifier.size(18.dp))
            }
            OutlinedButton(onClick = onCyclePlaybackSpeed) {
                Text("${if (selected) playback.speed else 1f}×")
            }
        }
    }
}
