package dev.audiocompanion.app

import android.content.Context

/**
 * Persists the CDM-associated watch Bluetooth address so [AudioCompanionDeviceService] and
 * process restarts can reconnect without reopening the onboarding UI.
 */
object PairedWatchStore {
    private const val PREFS_NAME = "audio_companion_runtime"
    private const val KEY_PAIRED_DEVICE_ADDRESS = "paired_device_address_v1"

    fun save(context: Context, deviceAddress: String) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PAIRED_DEVICE_ADDRESS, deviceAddress)
            .apply()
    }

    fun load(context: Context): String? =
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PAIRED_DEVICE_ADDRESS, null)
            ?.takeIf { it.isNotBlank() }

    fun clear(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_PAIRED_DEVICE_ADDRESS)
            .apply()
    }
}
