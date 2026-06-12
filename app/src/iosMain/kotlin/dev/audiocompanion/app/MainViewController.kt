package dev.audiocompanion.app

import androidx.compose.ui.window.ComposeUIViewController
import dev.audiocompanion.app.ui.AppActions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import platform.UIKit.UIViewController

object IosAudioCompanionBootstrap {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val handle: IosAudioCompanionRuntimeHandle = IosAudioCompanionRuntimeHandle()

    fun applicationDidFinishLaunching() {
        handle.runtime.recoverDurableState()
        if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
            handle.startReceiver()
        } else {
            handle.connectWatch()
        }
    }

    fun applicationWillEnterForeground() {
        handle.runtime.refreshDiagnostics()
        if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
            handle.startReceiver()
        }
    }

    fun applicationDidEnterBackground() {
        if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
            handle.startReceiver()
        }
    }

    fun startReceiver() {
        handle.settingsRepository.setBackgroundReceiverEnabled(true)
        handle.startReceiver()
    }

    fun stopReceiver() {
        handle.settingsRepository.setBackgroundReceiverEnabled(false)
        handle.stopReceiver()
    }

    fun refreshDiagnostics() {
        handle.runtime.refreshDiagnostics()
    }

    fun deleteAllLocalData() {
        scope.launch {
            handle.stopReceiver()
            handle.runtime.deleteAllLocalData()
        }
    }

    fun revokeReceiverLocally() {
        scope.launch {
            handle.stopReceiver()
            handle.runtime.revokeReceiverLocally()
        }
    }
}

fun MainViewController(): UIViewController {
    val bootstrap = IosAudioCompanionBootstrap
    val runtime = bootstrap.handle.runtime
    val settings = bootstrap.handle.settingsRepository
    return ComposeUIViewController {
        App(
            sessionState = runtime.state,
            diagnostics = runtime.diagnostics,
            watchServiceState = runtime.watchServiceState,
            settings = settings.settings,
            localModelState = bootstrap.handle.localModelManager.state,
            waveformBars = runtime.liveMonitor?.bars
                ?: kotlinx.coroutines.flow.MutableStateFlow(emptyList()),
            waveformWindowMs = runtime.liveMonitor?.windowMs ?: 60_000,
            playbackState = runtime.playback?.state
                ?: kotlinx.coroutines.flow.MutableStateFlow(PlaybackUiState()),
            actions = AppActions(
                pairWatch = {
                    bootstrap.handle.startReceiver()
                    runtime.refreshDiagnostics()
                },
                // iOS surfaces the Bluetooth permission dialog when the central first starts;
                // connecting is the permission request.
                requestPermissions = { bootstrap.handle.connectWatch() },
                setOnboardingComplete = settings::setOnboardingComplete,
                startReceiver = bootstrap::startReceiver,
                stopReceiver = bootstrap::stopReceiver,
                setBackgroundReceiverEnabled = { enabled ->
                    if (enabled) {
                        bootstrap.startReceiver()
                    } else {
                        bootstrap.stopReceiver()
                    }
                },
                refreshDiagnostics = runtime::refreshDiagnostics,
                setWaveformActive = { active -> runtime.liveMonitor?.setActive(active) },
                playSegment = { segmentId -> runtime.playback?.play(segmentId) },
                pausePlayback = { runtime.playback?.pause() },
                stopPlayback = { runtime.playback?.stop() },
                seekPlayback = { segmentId, positionMs ->
                    runtime.playback?.seekTo(segmentId, positionMs)
                },
                cyclePlaybackSpeed = { runtime.playback?.cycleSpeed() },
                loadSegments = runtime::listSegmentsForUi,
                loadTranscript = runtime::transcript,
                loadAnnotation = runtime::annotation,
                loadAiOutputs = runtime::listAiOutputs,
                deleteSegment = runtime::deleteSegmentData,
                deleteAiOutput = runtime::deleteAiOutput,
                deleteAll = bootstrap::deleteAllLocalData,
                revokeReceiver = bootstrap::revokeReceiverLocally,
                exportSupportReport = {
                    runtime.buildSupportReport(includeContent = false)
                },
                runAi = { template, segmentIds ->
                    runCatching {
                        runtime.runAi(
                            prompt = template,
                            segmentIds = segmentIds,
                            userConsentedToRemote = settings.settings.value.remoteAiConsent,
                        )
                    }
                },
                setRetentionDays = settings::setRetentionDays,
                setTranscriptionMode = {
                    settings.setTranscriptionMode(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setCloudTranscriptionConsent = {
                    settings.setCloudTranscriptionConsent(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setOpenAiApiKey = {
                    settings.setOpenAiApiKey(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setAiMode = settings::setAiMode,
                setRemoteAiConsent = settings::setRemoteAiConsent,
                refreshLocalModel = bootstrap.handle.localModelManager::refresh,
                downloadLocalModel = bootstrap.handle.localModelManager::download,
                cancelModelDownload = bootstrap.handle.localModelManager::cancelDownload,
            ),
        )
    }
}
