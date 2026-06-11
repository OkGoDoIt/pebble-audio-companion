package dev.audiocompanion.adapter.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Android foreground-service lifetime for the BLE receiver.
 *
 * The receiver session and durable storage runtime are hosted here so Android keeps the companion
 * GATT link alive while background capture is active. The current implementation establishes the
 * OS-visible connected-device service shell; session injection is layered on top by the app
 * runtime milestone.
 */
class AudioCompanionBleService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Audio Companion",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Maintains the Pebble background audio BLE connection"
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Pebble audio companion")
            .setContentText("Listening for encrypted background audio from your watch")
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "dev.audiocompanion.adapter.ble.action.START"
        const val ACTION_STOP = "dev.audiocompanion.adapter.ble.action.STOP"
        const val CHANNEL_ID = "audio_companion_ble"
        const val NOTIFICATION_ID = 0x7c2b

        fun startIntent(context: Context): Intent =
            Intent(context, AudioCompanionBleService::class.java).setAction(ACTION_START)

        fun stopIntent(context: Context): Intent =
            Intent(context, AudioCompanionBleService::class.java).setAction(ACTION_STOP)
    }
}
