package dev.audiocompanion.adapter.ble

import android.annotation.SuppressLint
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.IntentSender
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid

/**
 * Companion Device Manager onboarding for the separate third-party audio app.
 *
 * The filter targets the custom Audio Companion service UUID hosted by the watch firmware, not the
 * official Pebble mobile app integration. UI code launches the returned [IntentSender] and then
 * uses the selected/associated Bluetooth device with [AndroidAudioGattLink].
 */
class AndroidAudioCompanionAssociator(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val manager: CompanionDeviceManager =
        appContext.getSystemService(CompanionDeviceManager::class.java)

    interface Callback {
        fun onAssociationPending(intentSender: IntentSender)
        fun onAssociated(association: AssociationInfo)
        fun onFailure(message: CharSequence?)
    }

    @SuppressLint("MissingPermission")
    fun associate(callback: Callback, handler: Handler = Handler(Looper.getMainLooper())) {
        val request = AssociationRequest.Builder()
            .addDeviceFilter(
                BluetoothLeDeviceFilter.Builder()
                    .setScanFilter(
                        ScanFilter.Builder()
                            .setServiceUuid(ParcelUuid(AndroidAudioGattLink.SERVICE_UUID))
                            .build(),
                    )
                    .build(),
            )
            .setDisplayName("Pebble Audio Companion")
            .setSingleDevice(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setDeviceProfile(AssociationRequest.DEVICE_PROFILE_WATCH)
                }
            }
            .build()

        manager.associate(
            request,
            object : CompanionDeviceManager.Callback() {
                override fun onAssociationPending(intentSender: IntentSender) {
                    callback.onAssociationPending(intentSender)
                }

                @Suppress("OVERRIDE_DEPRECATION")
                override fun onDeviceFound(chooserLauncher: IntentSender) {
                    callback.onAssociationPending(chooserLauncher)
                }

                override fun onAssociationCreated(associationInfo: AssociationInfo) {
                    callback.onAssociated(associationInfo)
                }

                override fun onFailure(error: CharSequence?) {
                    callback.onFailure(error)
                }

                override fun onFailure(errorCode: Int, error: CharSequence?) {
                    callback.onFailure(error ?: "Association failed with code $errorCode")
                }
            },
            handler,
        )
    }
}
