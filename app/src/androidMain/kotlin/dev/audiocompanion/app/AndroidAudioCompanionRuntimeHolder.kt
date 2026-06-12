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
                val modelProvider = AndroidCactusModelPathProvider(context.applicationContext)
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
                        modelName = modelProvider.modelName,
                        modelVersion = modelProvider.modelVersion,
                        isDownloaded = modelProvider::isModelDownloaded,
                        download = { onProgress -> modelProvider.downloadModel(onProgress) },
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
