package dev.audiocompanion.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import dev.audiocompanion.app.ui.statusUiModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

class AudioCompanionReceiverService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var notificationJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val handle = AndroidAudioCompanionRuntimeHolder.get(this)
        when (intent?.action) {
            ACTION_STOP -> {
                // Record the intent (the notification's Stop action bypasses the UI toggle) so a
                // sticky restart does not auto-resume against the user's wish, then pause the
                // watch (best effort) so its Settings show Paused, tear down, and disconnect.
                handle.settingsRepository.setBackgroundReceiverEnabled(false)
                serviceScope.launch {
                    handle.runtime.stopReceiving()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf(startId)
                }
                return START_NOT_STICKY
            }
            ACTION_CONNECT -> {
                startForeground(NOTIFICATION_ID, buildNotification("Waiting for Pebble"))
                handle.runtime.start(serviceScope)
                observeStateForNotification(handle)
                connectFromIntent(intent)
                return START_STICKY
            }
            else -> {
                startForeground(NOTIFICATION_ID, buildNotification("Waiting for Pebble"))
                handle.runtime.start(serviceScope)
                observeStateForNotification(handle)
                PairedWatchStore.load(this)?.let { address ->
                    connectFromIntent(
                        AudioCompanionReceiverService.connectIntent(this, address),
                    )
                }
                return START_STICKY
            }
        }
    }

    private fun connectFromIntent(intent: Intent) {
        val address = intent.getStringExtra(EXTRA_DEVICE_ADDRESS) ?: return
        PairedWatchStore.save(this, address)
        val device = getSystemService(BluetoothManager::class.java)?.adapter?.getRemoteDevice(address)
        if (device != null) {
            AndroidAudioCompanionRuntimeHolder.get(this).link.connect(device)
        }
    }

    override fun onDestroy() {
        AndroidAudioCompanionRuntimeHolder.get(this).runtime.stop()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Keeps the foreground notification honest (ux plan Section 15): the content text is the
     * same plain-language headline the Today screen shows for the current receiver state.
     */
    private fun observeStateForNotification(handle: AndroidAudioCompanionRuntimeHandle) {
        if (notificationJob != null) return
        notificationJob = serviceScope.launch {
            combine(
                handle.runtime.state,
                handle.runtime.diagnostics,
                handle.settingsRepository.settings,
                handle.runtime.watchServiceState,
            ) { state, diagnostics, settings, watchState ->
                statusUiModel(state, settings, diagnostics, watchState).headline
            }
                .distinctUntilChanged()
                .collect { headline ->
                    getSystemService(NotificationManager::class.java)
                        ?.notify(NOTIFICATION_ID, buildNotification(headline))
                }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Audio Companion",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Maintains the Pebble background audio receiver"
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(contentText: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            stopIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Pebble Audio Companion")
            .setContentText(contentText)
            .setContentIntent(openIntent)
            .addAction(
                Notification.Action.Builder(null, "Stop", stopIntent).build(),
            )
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val ACTION_START = "dev.audiocompanion.app.action.START_RECEIVER"
        private const val ACTION_CONNECT = "dev.audiocompanion.app.action.CONNECT_RECEIVER"
        private const val ACTION_STOP = "dev.audiocompanion.app.action.STOP_RECEIVER"
        private const val EXTRA_DEVICE_ADDRESS = "device_address"
        private const val CHANNEL_ID = "audio_companion_receiver"
        private const val NOTIFICATION_ID = 0x7c2c

        fun startIntent(context: Context): Intent =
            Intent(context, AudioCompanionReceiverService::class.java).setAction(ACTION_START)

        fun connectIntent(context: Context, deviceAddress: String): Intent =
            Intent(context, AudioCompanionReceiverService::class.java)
                .setAction(ACTION_CONNECT)
                .putExtra(EXTRA_DEVICE_ADDRESS, deviceAddress)

        fun stopIntent(context: Context): Intent =
            Intent(context, AudioCompanionReceiverService::class.java).setAction(ACTION_STOP)
    }
}
