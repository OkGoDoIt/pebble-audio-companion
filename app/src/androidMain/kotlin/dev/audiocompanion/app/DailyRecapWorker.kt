package dev.audiocompanion.app

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException

/**
 * Periodic daily digest generation aligned to slow background maintenance windows.
 */
class DailyRecapPeriodicWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        try {
            val runtime = AndroidAudioCompanionRuntimeHolder.get(applicationContext).runtime
            runtime.generateDailyDigests()
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            Result.retry()
        }

    companion object {
        private const val WORK_NAME = "daily-recap"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<DailyRecapPeriodicWorker>(6, TimeUnit.HOURS)
                .setInitialDelay(15, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }
}
