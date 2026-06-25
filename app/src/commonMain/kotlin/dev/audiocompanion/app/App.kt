package dev.audiocompanion.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import dev.audiocompanion.ai.AiOutput
import dev.audiocompanion.ai.SegmentAnnotation
import dev.audiocompanion.app.ui.AiScreen
import dev.audiocompanion.app.ui.AppActions
import dev.audiocompanion.app.ui.LibraryScreen
import dev.audiocompanion.app.ui.OnboardingScreen
import dev.audiocompanion.app.ui.PrimaryAction
import dev.audiocompanion.app.ui.SettingsScreen
import dev.audiocompanion.app.ui.TimelineItem
import dev.audiocompanion.app.ui.TodayScreen
import dev.audiocompanion.app.ui.buildTimeline
import dev.audiocompanion.app.ui.segmentTitle
import dev.audiocompanion.app.ui.statusUiModel
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transport.ReceiverSessionState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock

enum class AppTab(val label: String) {
    Today("Today"),
    Library("Library"),
    Ai("AI"),
    Settings("Settings"),
}

private val AppTab.icon: ImageVector
    get() = when (this) {
        AppTab.Today -> Icons.Filled.GraphicEq
        AppTab.Library -> Icons.Filled.Folder
        AppTab.Ai -> Icons.Filled.AutoAwesome
        AppTab.Settings -> Icons.Filled.Settings
    }

private data class DurableContentSnapshot(
    val segments: List<SegmentMeta> = emptyList(),
    val transcripts: Map<String, SegmentTranscript?> = emptyMap(),
    val liveTranscripts: Map<String, String?> = emptyMap(),
    val livePreviews: Map<String, LiveTranscriptPreview?> = emptyMap(),
    val annotations: Map<String, SegmentAnnotation?> = emptyMap(),
    val aiOutputs: List<AiOutput> = emptyList(),
    /** Built off the UI thread alongside the durable reads: buildTimeline is O(segments) and was
     * freezing the main thread when computed in composition over a large/gappy library. */
    val todayTimeline: List<TimelineItem> = emptyList(),
)

private const val TODAY_CONTENT_WINDOW_MS = 24L * 60 * 60 * 1000

/**
 * The shared app shell: four tabs (Today / Library / AI / Settings) per
 * docs/ux-visual-design-plan.md. All platform work goes through [AppActions]; durable content
 * is re-read whenever diagnostics change (every receive/transcription/AI event refreshes
 * diagnostics, so file-backed reads stay current without platform callbacks).
 */
@Composable
fun App(
    sessionState: StateFlow<ReceiverSessionState> =
        MutableStateFlow(ReceiverSessionState.Disconnected),
    diagnostics: StateFlow<AudioCompanionDiagnostics> =
        MutableStateFlow(AudioCompanionDiagnostics()),
    watchServiceState: StateFlow<Int?> = MutableStateFlow(null),
    settings: StateFlow<AudioCompanionSettings> =
        MutableStateFlow(AudioCompanionSettings()),
    localModelState: StateFlow<LocalTranscriptionModelState> =
        MutableStateFlow(
            LocalTranscriptionModelState(
                modelName = "local",
                modelVersion = "unknown",
                selectedModelId = LocalTranscriptionModels.DEFAULT_MODEL_ID,
                options = LocalTranscriptionModels.all.map {
                    LocalTranscriptionModelOptionState(it, downloaded = false)
                },
            ),
        ),
    liveTranscriptPreviews: StateFlow<Map<String, LiveTranscriptPreview>> =
        MutableStateFlow(emptyMap()),
    waveformBars: StateFlow<List<WaveformBar>> = MutableStateFlow(emptyList()),
    waveformWindowMs: Long = 60_000,
    playbackState: StateFlow<PlaybackUiState> = MutableStateFlow(PlaybackUiState()),
    actions: AppActions = AppActions(),
) {
    MaterialTheme {
        val state = sessionState.collectAsState().value
        val currentDiagnostics = diagnostics.collectAsState().value
        val currentWatchState = watchServiceState.collectAsState().value
        val currentSettings = settings.collectAsState().value
        val currentLocalModel = localModelState.collectAsState().value
        val currentPlayback = playbackState.collectAsState().value
        val currentLivePreviews = liveTranscriptPreviews.collectAsState().value

        // Wall-clock tick: keeps durations and "Recording now" ages fresh without forcing
        // durable file reads on every tick.
        var nowTick by remember { mutableStateOf(Clock.System.now().toEpochMilliseconds()) }
        LaunchedEffect(Unit) {
            while (true) {
                delay(500)
                nowTick = Clock.System.now().toEpochMilliseconds()
            }
        }

        if (!currentSettings.onboardingComplete) {
            Surface(modifier = Modifier.fillMaxSize()) {
                OnboardingScreen(
                    sessionState = state,
                    settings = currentSettings,
                    localModel = currentLocalModel,
                    actions = actions,
                )
            }
            return@MaterialTheme
        }

        var tab by rememberSaveable { mutableStateOf(AppTab.Today) }
        var librarySegmentId by rememberSaveable { mutableStateOf<String?>(null) }

        // The live waveform decodes only while Today is visible (ux plan Section 8).
        DisposableEffect(tab) {
            actions.setWaveformActive(tab == AppTab.Today)
            onDispose { actions.setWaveformActive(false) }
        }
        val currentWaveformBars = waveformBars.collectAsState().value

        val nowMs = nowTick
        // Durable content snapshots are file-backed, so hydrate them away from the UI thread.
        // The previous snapshot remains visible while storage refreshes; first launch can paint
        // immediately instead of blocking on a large library.
        var durableContent by remember { mutableStateOf(DurableContentSnapshot()) }
        LaunchedEffect(currentDiagnostics, tab, currentLivePreviews) {
            val previousAiOutputs = durableContent.aiOutputs
            try {
                durableContent = withContext(Dispatchers.Default) {
                    val snapshotNow = Clock.System.now().toEpochMilliseconds()
                    val loadedSegments = actions.loadSegments()
                    val contentSegments = when (tab) {
                        AppTab.Today -> loadedSegments.filter {
                            it.isOpen || it.receivedAtMs >= snapshotNow - TODAY_CONTENT_WINDOW_MS
                        }
                        AppTab.Settings -> emptyList()
                        AppTab.Library, AppTab.Ai -> loadedSegments
                    }
                    val transcriptsMap = contentSegments.associate {
                        it.segmentId to actions.loadTranscript(it.segmentId)
                    }
                    val livePreviewsMap = contentSegments.associate {
                        it.segmentId to (
                            currentLivePreviews[it.segmentId]
                                ?: actions.loadLiveTranscriptPreview(it.segmentId)
                            )
                    }
                    val liveTranscriptsMap = contentSegments.associate {
                        it.segmentId to (
                            livePreviewsMap[it.segmentId]?.text
                                ?: actions.loadLiveTranscript(it.segmentId)
                            )
                    }
                    val annotationsMap = contentSegments.associate {
                        it.segmentId to actions.loadAnnotation(it.segmentId)
                    }
                    val timeline = buildTimeline(
                        segments = loadedSegments,
                        transcriptOf = { transcriptsMap[it] },
                        nowMs = snapshotNow,
                        annotationOf = { annotationsMap[it] },
                        liveTextOf = { liveTranscriptsMap[it] },
                    )
                    DurableContentSnapshot(
                        segments = loadedSegments,
                        transcripts = transcriptsMap,
                        liveTranscripts = liveTranscriptsMap,
                        livePreviews = livePreviewsMap,
                        annotations = annotationsMap,
                        aiOutputs = if (tab == AppTab.Ai) {
                            actions.loadAiOutputs()
                        } else {
                            previousAiOutputs
                        },
                        todayTimeline = timeline,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                logBackgroundFailure("durable content reload", t)
            }
        }
        val segments = durableContent.segments
        val transcripts = durableContent.transcripts
        val liveTranscripts = durableContent.liveTranscripts
        val livePreviews = durableContent.livePreviews
        val annotations = durableContent.annotations
        val aiOutputs = durableContent.aiOutputs
        // Built off the UI thread in the durable reload above (see DurableContentSnapshot).
        val todayTimeline = durableContent.todayTimeline
        val displayedTodayTimeline =
            remember(todayTimeline, currentLivePreviews, transcripts, annotations) {
                todayTimeline.map { item ->
                    when (item) {
                        is TimelineItem.Segment -> {
                            val livePreview = currentLivePreviews[item.meta.segmentId]
                            if (livePreview == null) {
                                item
                            } else {
                                item.copy(
                                    title = segmentTitle(
                                        item.meta,
                                        transcripts[item.meta.segmentId],
                                        annotations[item.meta.segmentId],
                                        liveText = livePreview.text,
                                    ),
                                )
                            }
                        }
                    }
                }
            }

        val status = statusUiModel(state, currentSettings, currentDiagnostics, currentWatchState)
        val onPrimaryAction: (PrimaryAction) -> Unit = { action ->
            when (action) {
                // The enabled flag drives the receiver on both platforms (service/bootstrap),
                // so Start/Stop stay symmetric and survive app restarts.
                PrimaryAction.Start -> actions.setBackgroundReceiverEnabled(true)
                PrimaryAction.Stop -> actions.setBackgroundReceiverEnabled(false)
                PrimaryAction.PairWatch, PrimaryAction.SetUpAgain -> actions.pairWatch()
                PrimaryAction.Troubleshoot -> tab = AppTab.Settings
                PrimaryAction.None -> Unit
            }
        }

        Scaffold(
            bottomBar = {
                NavigationBar {
                    AppTab.entries.forEach { candidate ->
                        NavigationBarItem(
                            selected = tab == candidate,
                            onClick = { tab = candidate },
                            icon = { Icon(candidate.icon, contentDescription = candidate.label) },
                            label = { Text(candidate.label) },
                        )
                    }
                }
            },
        ) { padding ->
            Surface(modifier = Modifier.fillMaxSize().padding(padding)) {
                when (tab) {
                    AppTab.Today -> TodayScreen(
                        status = status,
                        diagnostics = currentDiagnostics,
                        settings = currentSettings,
                        localModel = currentLocalModel,
                        timeline = displayedTodayTimeline,
                        nowMs = nowMs,
                        waveformBars = currentWaveformBars,
                        waveformWindowMs = waveformWindowMs,
                        playback = currentPlayback,
                        isSegmentTranscribed = { segmentId ->
                            segments.firstOrNull { it.segmentId == segmentId }
                                ?.isFullyTranscribed == true
                        },
                        liveTranscribedSampleIndex = { segmentId ->
                            currentLivePreviews[segmentId]?.lastSampleIndexExclusive
                                ?: livePreviews[segmentId]?.lastSampleIndexExclusive
                        },
                        onPrimaryAction = onPrimaryAction,
                        onOpenSegment = { segmentId ->
                            librarySegmentId = segmentId
                            tab = AppTab.Library
                        },
                        onPlaySegment = actions.playSegment,
                        onPausePlayback = actions.pausePlayback,
                        onStopPlayback = actions.stopPlayback,
                    )

                    AppTab.Library -> LibraryScreen(
                        segments = segments,
                        transcriptOf = { transcripts[it] },
                        liveTranscriptOf = { liveTranscripts[it] },
                        livePreviewOf = { currentLivePreviews[it] ?: livePreviews[it] },
                        liveTranscribedFrameCountOf = { segmentId ->
                            currentLivePreviews[segmentId]?.transcribedFrameCount?.toLong()
                                ?: livePreviews[segmentId]?.transcribedFrameCount?.toLong()
                        },
                        annotationOf = { annotations[it] },
                        settings = currentSettings,
                        localModel = currentLocalModel,
                        nowMs = nowMs,
                        playback = currentPlayback,
                        selectedSegmentId = librarySegmentId,
                        onSelectSegment = { librarySegmentId = it },
                        onDeleteSegment = actions.deleteSegment,
                        onExportSegment = actions.exportSegmentAudio,
                        onShareFile = actions.shareFile,
                        onPlaySegment = actions.playSegment,
                        onPausePlayback = actions.pausePlayback,
                        onStopPlayback = actions.stopPlayback,
                        onSeekPlayback = actions.seekPlayback,
                        onCyclePlaybackSpeed = actions.cyclePlaybackSpeed,
                        loadWaveform = actions.loadSegmentWaveform,
                    )

                    AppTab.Ai -> AiScreen(
                        segments = segments,
                        aiOutputs = aiOutputs,
                        // Only the remote provider exists today; configured = consent + key.
                        aiConfigured = currentSettings.remoteAiConsent &&
                            currentSettings.openAiApiKey.isNotBlank(),
                        nowMs = nowMs,
                        onRunAi = actions.runAi,
                        onDeleteOutput = actions.deleteAiOutput,
                        onRefresh = actions.refreshDiagnostics,
                    )

                    AppTab.Settings -> SettingsScreen(
                        sessionState = state,
                        settings = currentSettings,
                        diagnostics = currentDiagnostics,
                        watchServiceState = currentWatchState,
                        segments = segments,
                        localModel = currentLocalModel,
                        statusHeadline = status.headline,
                        exportDirectory = actions.audioExportDirectory(),
                        actions = actions,
                    )
                }
            }
        }
    }
}
