package dev.audiocompanion.app

import android.content.Context
import dev.audiocompanion.adapter.ble.AndroidAudioGattLink

object AndroidAudioCompanionRuntimeHolder {
    @Volatile
    private var handle: AndroidAudioCompanionRuntimeHandle? = null

    fun get(context: Context): AndroidAudioCompanionRuntimeHandle =
        handle ?: synchronized(this) {
            handle ?: run {
                val link = AndroidAudioGattLink(context.applicationContext)
                val settingsRepository = AndroidAudioCompanionSettingsRepository(context)
                val modelProvider = AndroidCactusModelPathProvider(
                    context.applicationContext,
                    selectedModelId = {
                        settingsRepository.settings.value.localTranscriptionModelId
                    },
                )
                val runtime = AndroidAudioCompanionRuntimeFactory(context).create(
                    link,
                    settingsRepository,
                    modelProvider,
                )
                AndroidAudioCompanionRuntimeHandle(
                    link = link,
                    runtime = runtime,
                    settingsRepository = settingsRepository,
                    localModelManager = LocalTranscriptionModelManager(
                        models = LocalTranscriptionModels.all,
                        selectedModelId = {
                            settingsRepository.settings.value.localTranscriptionModelId
                        },
                        isDownloaded = modelProvider::isModelDownloaded,
                        download = { modelId, onProgress ->
                            modelProvider.downloadModel(modelId, onProgress)
                        },
                        onModelStateChanged = { runtime.notifyTranscriptionConfigChanged() },
                    ).also { it.refresh() },
                ).also { handle = it }
            }
        }
}

class AndroidAudioCompanionRuntimeHandle(
    val link: AndroidAudioGattLink,
    val runtime: AudioCompanionRuntime,
    val settingsRepository: AndroidAudioCompanionSettingsRepository,
    val localModelManager: LocalTranscriptionModelManager,
)
