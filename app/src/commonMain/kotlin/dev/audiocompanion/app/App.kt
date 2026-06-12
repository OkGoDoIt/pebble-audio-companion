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
import kotlinx.coroutines.delay
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import dev.audiocompanion.app.ui.AiScreen
import dev.audiocompanion.app.ui.AppActions
import dev.audiocompanion.app.ui.LibraryScreen
import dev.audiocompanion.app.ui.OnboardingScreen
import dev.audiocompanion.app.ui.PrimaryAction
import dev.audiocompanion.app.ui.SettingsScreen
import dev.audiocompanion.app.ui.TodayScreen
import dev.audiocompanion.app.ui.buildTimeline
import dev.audiocompanion.app.ui.statusUiModel
import dev.audiocompanion.transport.ReceiverSessionState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
        MutableStateFlow(LocalTranscriptionModelState(modelName = "local", modelVersion = "unknown")),
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

        // Wall-clock tick: keeps durations, "Recording now" ages, and file-backed content
        // fresh even when no state flow happens to emit.
        var nowTick by remember { mutableStateOf(Clock.System.now().toEpochMilliseconds()) }
        LaunchedEffect(Unit) {
            while (true) {
                delay(2_000)
                nowTick = Clock.System.now().toEpochMilliseconds()
            }
        }

        if (!currentSettings.onboardingComplete) {
            Surface(modifier = Modifier.fillMaxSize()) {
                OnboardingScreen(
                    sessionState = state,
                    settings = currentSettings,
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
        // Durable content snapshots, re-read when anything observable changes or the clock
        // ticks (transcription/enrichment results land in files, not flows).
        val segments = remember(currentDiagnostics, tab, nowTick) { actions.loadSegments() }
        val transcripts = remember(currentDiagnostics, tab, nowTick) {
            segments.associate { it.segmentId to actions.loadTranscript(it.segmentId) }
        }
        val annotations = remember(currentDiagnostics, tab, nowTick) {
            segments.associate { it.segmentId to actions.loadAnnotation(it.segmentId) }
        }
        val aiOutputs = remember(currentDiagnostics, tab, nowTick) { actions.loadAiOutputs() }

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
                        timeline = buildTimeline(
                            segments = segments,
                            transcriptOf = { transcripts[it] },
                            nowMs = nowMs,
                            annotationOf = { annotations[it] },
                        ),
                        nowMs = nowMs,
                        waveformBars = currentWaveformBars,
                        waveformWindowMs = waveformWindowMs,
                        isSegmentTranscribed = { segmentId ->
                            segments.firstOrNull { it.segmentId == segmentId }
                                ?.transcriptionState == dev.audiocompanion.storage.TranscriptionState.Complete
                        },
                        onPrimaryAction = onPrimaryAction,
                        onOpenSegment = { segmentId ->
                            librarySegmentId = segmentId
                            tab = AppTab.Library
                        },
                    )

                    AppTab.Library -> LibraryScreen(
                        segments = segments,
                        transcriptOf = { transcripts[it] },
                        annotationOf = { annotations[it] },
                        nowMs = nowMs,
                        playback = currentPlayback,
                        selectedSegmentId = librarySegmentId,
                        onSelectSegment = { librarySegmentId = it },
                        onDeleteSegment = actions.deleteSegment,
                        onPlaySegment = actions.playSegment,
                        onPausePlayback = actions.pausePlayback,
                        onStopPlayback = actions.stopPlayback,
                        onSeekPlayback = actions.seekPlayback,
                        onCyclePlaybackSpeed = actions.cyclePlaybackSpeed,
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
                        localModel = currentLocalModel,
                        statusHeadline = status.headline,
                        actions = actions,
                    )
                }
            }
        }
    }
}
