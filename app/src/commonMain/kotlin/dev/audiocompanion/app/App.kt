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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
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
    settings: StateFlow<AudioCompanionSettings> =
        MutableStateFlow(AudioCompanionSettings()),
    localModelState: StateFlow<LocalTranscriptionModelState> =
        MutableStateFlow(LocalTranscriptionModelState(modelName = "local", modelVersion = "unknown")),
    actions: AppActions = AppActions(),
) {
    MaterialTheme {
        val state = sessionState.collectAsState().value
        val currentDiagnostics = diagnostics.collectAsState().value
        val currentSettings = settings.collectAsState().value
        val currentLocalModel = localModelState.collectAsState().value

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

        val nowMs = Clock.System.now().toEpochMilliseconds()
        // Durable content snapshots, re-read when anything observable changes.
        val segments = remember(currentDiagnostics, tab) { actions.loadSegments() }
        val transcripts = remember(currentDiagnostics, tab) {
            segments.associate { it.segmentId to actions.loadTranscript(it.segmentId) }
        }
        val annotations = remember(currentDiagnostics, tab) {
            segments.associate { it.segmentId to actions.loadAnnotation(it.segmentId) }
        }
        val aiOutputs = remember(currentDiagnostics, tab) { actions.loadAiOutputs() }

        val status = statusUiModel(state, currentSettings, currentDiagnostics)
        val onPrimaryAction: (PrimaryAction) -> Unit = { action ->
            when (action) {
                PrimaryAction.Start -> {
                    actions.setBackgroundReceiverEnabled(true)
                    actions.startReceiver()
                }
                PrimaryAction.Stop -> actions.stopReceiver()
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
                        selectedSegmentId = librarySegmentId,
                        onSelectSegment = { librarySegmentId = it },
                        onDeleteSegment = actions.deleteSegment,
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
                        localModel = currentLocalModel,
                        statusHeadline = status.headline,
                        actions = actions,
                    )
                }
            }
        }
    }
}
