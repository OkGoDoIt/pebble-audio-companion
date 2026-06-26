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
 * Android's in-process transcription catch-up, scheduled via WorkManager — the analog of the iOS
 * BGProcessing burst. While the user is actively receiving, the foreground service keeps the
 * process alive and the synchronous pipeline transcribes in real time; this worker covers the gap
 * where the app is otherwise idle (no foreground service), waking periodically to transcribe any
 * pending closed segments (local or cloud) and then releasing the model.
 *
 * It reuses the process-singleton runtime and [AudioCompanionRuntime.runCatchUpNow], which is
 * serialized against the foreground loop, so it never double-processes.
 */
class CloudCatchUpWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        try {
            AndroidAudioCompanionRuntimeHolder.get(applicationContext).runtime.runCatchUpNow()
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            Result.retry()
        }

    companion object {
        private const val WORK_NAME = "cloud-transcription-catch-up"

        /** Schedules the periodic catch-up (idempotent; keeps any existing schedule). */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<CloudCatchUpWorker>(1, TimeUnit.HOURS).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }
}
