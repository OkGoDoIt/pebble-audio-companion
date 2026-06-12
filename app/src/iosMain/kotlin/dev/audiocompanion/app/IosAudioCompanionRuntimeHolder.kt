package dev.audiocompanion.app

import dev.audiocompanion.adapter.ble.IosAudioGattLink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class IosAudioCompanionRuntimeHandle(
    val link: IosAudioGattLink = IosAudioGattLink(),
    val settingsRepository: IosAudioCompanionSettingsRepository = IosAudioCompanionSettingsRepository(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val modelProvider = IosCactusModelPathProvider(
        selectedModelId = { settingsRepository.settings.value.localTranscriptionModelId },
    )
    val runtime: AudioCompanionRuntime =
        IosAudioCompanionRuntimeFactory().create(link, settingsRepository, modelProvider)
    val localModelManager: LocalTranscriptionModelManager = LocalTranscriptionModelManager(
        models = LocalTranscriptionModels.all,
        selectedModelId = { settingsRepository.settings.value.localTranscriptionModelId },
        isDownloaded = modelProvider::isModelDownloaded,
        download = { modelId, onProgress -> modelProvider.downloadModel(modelId, onProgress) },
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
