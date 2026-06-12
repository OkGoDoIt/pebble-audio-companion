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
            settings = settings.settings,
            localModelState = bootstrap.handle.localModelManager.state,
            actions = AppActions(
                pairWatch = {
                    bootstrap.handle.connectWatch()
                    runtime.refreshDiagnostics()
                },
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
                loadSegments = runtime::listSegmentsForUi,
                loadTranscript = runtime::transcript,
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
                setTranscriptionMode = settings::setTranscriptionMode,
                setCloudTranscriptionConsent = settings::setCloudTranscriptionConsent,
                setOpenAiApiKey = settings::setOpenAiApiKey,
                setAiMode = settings::setAiMode,
                setRemoteAiConsent = settings::setRemoteAiConsent,
                refreshLocalModel = bootstrap.handle.localModelManager::refresh,
                downloadLocalModel = bootstrap.handle.localModelManager::download,
            ),
        )
    }
}
