package dev.audiocompanion.app

import android.app.Application
import android.content.Context

/**
 * Application entry for Android deep OS hooks (M6 App Functions, shortcuts). Runtime singleton
 * remains in [AndroidAudioCompanionRuntimeHolder] for now.
 */
class AudioCompanionApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DailyRecapPeriodicWorker.schedule(this)
    }

    companion object {
        fun from(context: Context): AudioCompanionApplication =
            context.applicationContext as AudioCompanionApplication
    }
}
