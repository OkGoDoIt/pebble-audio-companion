package dev.audiocompanion.app

import androidx.compose.ui.window.ComposeUIViewController
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
            onPairWatch = {
                bootstrap.handle.connectWatch()
                runtime.refreshDiagnostics()
            },
            onStartReceiver = bootstrap::startReceiver,
            onStopReceiver = bootstrap::stopReceiver,
            onRefreshDiagnostics = runtime::refreshDiagnostics,
            onBackgroundReceiverChanged = { enabled ->
                if (enabled) {
                    bootstrap.startReceiver()
                } else {
                    bootstrap.stopReceiver()
                }
            },
            onCloudTranscriptionConsentChanged = settings::setCloudTranscriptionConsent,
            onOpenAiApiKeyChanged = settings::setOpenAiApiKey,
            onRemoteAiConsentChanged = settings::setRemoteAiConsent,
            onDiagnosticsContentChanged = settings::setDiagnosticsIncludeContent,
            onCycleTranscriptionMode = {
                settings.setTranscriptionMode(settings.settings.value.transcriptionMode.next())
            },
            onCycleAiMode = {
                settings.setAiMode(settings.settings.value.aiMode.next())
            },
            onRetentionDaysChanged = settings::setRetentionDays,
            onDeleteAll = bootstrap::deleteAllLocalData,
            onExportDiagnostics = {
                runtime.buildSupportReport(includeContent = settings.settings.value.diagnosticsIncludeContent)
            },
            onRevokeReceiver = bootstrap::revokeReceiverLocally,
        )
    }
}
