package dev.audiocompanion.transcription

import android.os.Process
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

actual suspend fun withHighPriorityTranscriptionThread(block: suspend () -> String): String =
    withContext(Dispatchers.Default.limitedParallelism(1)) {
        val originalPriority = Process.getThreadPriority(Process.myTid())
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        try {
            block()
        } finally {
            Process.setThreadPriority(originalPriority)
        }
    }

actual suspend fun getFreeTranscriptionMemoryMb(): Long {
    val runtime = Runtime.getRuntime()
    val usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
    val maxMemory = runtime.maxMemory() / (1024 * 1024)
    return maxMemory - usedMemory
}

actual val minTranscriptionMemoryMb: Long = 20
