package dev.audiocompanion.app

import android.bluetooth.BluetoothManager
import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Companion Device Manager presence hook for the app-owned receiver runtime.
 *
 * CDM association is initiated from [MainActivity], but Android delivers watch presence here
 * after association. Starting [AudioCompanionReceiverService] from this callback is the
 * supported background entry point for keeping the dedicated Audio Companion GATT link alive.
 */
@RequiresApi(Build.VERSION_CODES.S)
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
class AudioCompanionDeviceService : CompanionDeviceService() {

    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        val address = associationInfo.deviceAddressOrNull()
        if (address != null) {
            PairedWatchStore.save(this, address)
        }
        maybeStartReceiver(address)
    }

    override fun onDeviceAppeared(address: String) {
        PairedWatchStore.save(this, address)
        maybeStartReceiver(address)
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        // Keep the foreground service running while the watch is out of range so reconnect can
        // resume from durable receiver state when the link returns.
    }

    override fun onDeviceDisappeared(address: String) {
        // Same as [onDeviceDisappeared] for [AssociationInfo].
    }

    private fun maybeStartReceiver(deviceAddress: String?) {
        val handle = AndroidAudioCompanionRuntimeHolder.get(this)
        if (!handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
            return
        }

        val address = deviceAddress ?: PairedWatchStore.load(this) ?: return
        val device = getSystemService(BluetoothManager::class.java)?.adapter?.getRemoteDevice(address)
            ?: return

        startForegroundService(AudioCompanionReceiverService.connectIntent(this, device.address))
    }

    private fun AssociationInfo.deviceAddressOrNull(): String? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            deviceMacAddress?.toString()
        } else {
            null
        }
    }
}
