package dev.audiocompanion.app

import dev.audiocompanion.adapter.ble.IosAudioGattLink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class IosAudioCompanionRuntimeHandle(
    val link: IosAudioGattLink = IosAudioGattLink(),
    val settingsRepository: IosAudioCompanionSettingsRepository = IosAudioCompanionSettingsRepository(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val runtime: AudioCompanionRuntime =
        IosAudioCompanionRuntimeFactory().create(link, settingsRepository)

    fun connectWatch() {
        link.connect()
    }

    fun startReceiver() {
        connectWatch()
        runtime.start(scope)
    }

    fun stopReceiver() {
        runtime.stop()
    }
}
