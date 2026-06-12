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
                AndroidAudioCompanionRuntimeHandle(
                    link = link,
                    runtime = AndroidAudioCompanionRuntimeFactory(context).create(
                        link,
                        settingsRepository,
                    ),
                    settingsRepository = settingsRepository,
                ).also { handle = it }
            }
        }
}

class AndroidAudioCompanionRuntimeHandle(
    val link: AndroidAudioGattLink,
    val runtime: AudioCompanionRuntime,
    val settingsRepository: AndroidAudioCompanionSettingsRepository,
)
