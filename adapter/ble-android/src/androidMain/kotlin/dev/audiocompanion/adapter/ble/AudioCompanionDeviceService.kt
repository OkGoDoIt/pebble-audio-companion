package dev.audiocompanion.adapter.ble

import android.annotation.TargetApi
import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.content.Intent
import android.os.Build

/**
 * Companion Device Manager presence hook.
 *
 * CDM association belongs to the onboarding UI, but Android delivers watch presence here after
 * association. Starting the foreground connected-device service from this callback is the allowed
 * background entry point for keeping the dedicated Audio Companion GATT link alive.
 */
@TargetApi(Build.VERSION_CODES.S)
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
class AudioCompanionDeviceService : CompanionDeviceService() {

    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        startReceiverService()
    }

    override fun onDeviceAppeared(address: String) {
        startReceiverService()
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        stopReceiverService()
    }

    override fun onDeviceDisappeared(address: String) {
        stopReceiverService()
    }

    private fun startReceiverService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(AudioCompanionBleService.startIntent(this))
        } else {
            startService(AudioCompanionBleService.startIntent(this))
        }
    }

    private fun stopReceiverService() {
        startService(AudioCompanionBleService.stopIntent(this))
    }
}
