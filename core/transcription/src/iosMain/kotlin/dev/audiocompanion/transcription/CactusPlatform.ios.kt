@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package dev.audiocompanion.transcription

import osmemory.audiocompanion_available_memory_bytes

actual suspend fun withHighPriorityTranscriptionThread(block: suspend () -> String): String =
    block()

/**
 * The memory this *process* can still allocate before iOS terminates it for memory pressure
 * (jetsam), via os_proc_available_memory(). This is the right signal for gating heavy local
 * transcription: device-wide free memory (host_statistics64) says nothing about this app's own
 * per-process budget, which iOS enforces independently.
 */
actual suspend fun getFreeTranscriptionMemoryMb(): Long {
    val bytes = audiocompanion_available_memory_bytes().toLong()
    // 0 means the budget is unavailable in this context (e.g. the simulator or an app extension).
    // Treat that as "plenty" so we never wrongly block transcription where we cannot measure.
    if (bytes <= 0L) return Long.MAX_VALUE
    return bytes / (1024L * 1024L)
}

/** Conservative: require this much process budget remaining before a native transcription call. */
actual val minTranscriptionMemoryMb: Long = 96

/** Higher bar to *load* a model (loading needs headroom the steady-state inference does not). */
actual val minModelInitMemoryMb: Long = 150
