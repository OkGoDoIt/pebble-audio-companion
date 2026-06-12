package dev.audiocompanion.app

import dev.audiocompanion.adapter.ble.IosAudioGattLink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class IosAudioCompanionRuntimeHandle(
    val link: IosAudioGattLink = IosAudioGattLink(),
    val settingsRepository: IosAudioCompanionSettingsRepository = IosAudioCompanionSettingsRepository(),
    private val modelProvider: IosCactusModelPathProvider = IosCactusModelPathProvider(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val runtime: AudioCompanionRuntime =
        IosAudioCompanionRuntimeFactory().create(link, settingsRepository, modelProvider)
    val localModelManager: LocalTranscriptionModelManager = LocalTranscriptionModelManager(
        modelName = modelProvider.modelName,
        modelVersion = modelProvider.modelVersion,
        isDownloaded = modelProvider::isModelDownloaded,
        download = { onProgress -> modelProvider.downloadModel(onProgress) },
        onModelStateChanged = { runtime.notifyTranscriptionConfigChanged() },
    ).also { it.refresh() }

    fun connectWatch() {
        link.connect()
    }

    fun startReceiver() {
        connectWatch()
        runtime.start(scope)
    }

    fun stopReceiver() {
        scope.launch {
            // Pause the watch first (best effort) so its Settings show Paused instead of
            // Streaming, then tear down and drop the connection.
            runtime.stopReceiving()
        }
    }
}
