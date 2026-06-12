package dev.audiocompanion.app

import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transport.GapRecord
import dev.audiocompanion.transport.SegmentCloseReason
import dev.audiocompanion.transport.SegmentFrame
import dev.audiocompanion.transport.SegmentProvenance
import dev.audiocompanion.transport.SegmentSink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.min
import kotlin.math.sqrt

/** Decodes encoded Speex frames to one concatenated PCM16 sample array, in order. */
fun interface LiveFrameDecoder {
    suspend fun decode(frames: List<ByteArray>): ShortArray
}

/** Default decoder over the platform Speex codec (Android/iOS native; not used in JVM tests). */
class SpeexLiveFrameDecoder(
    private val frameSamples: Int = 320,
) : LiveFrameDecoder {
    override suspend fun decode(frames: List<ByteArray>): ShortArray {
        if (frames.isEmpty()) return ShortArray(0)
        val out = ShortArray(frames.size * frameSamples)
        var offset = 0
        SpeexFrameDecoder(frameSamples = frameSamples)
            .decode(frames.asFlow(), pcmChunkBytes = frameSamples * 2)
            .collect { bytes ->
                var i = 0
                while (i + 1 < bytes.size && offset < out.size) {
                    out[offset++] =
                        ((bytes[i].toInt() and 0xFF) or (bytes[i + 1].toInt() shl 8)).toShort()
                    i += 2
                }
            }
        return if (offset == out.size) out else out.copyOf(offset)
    }
}

enum class WaveformBarState { Recorded, Silence, Gap }

/** One ~250 ms bar of the live waveform. */
data class WaveformBar(
    val timeMs: Long,
    /** 0..1 display amplitude. */
    val amplitude: Float,
    val state: WaveformBarState,
    /** Segment the audio belongs to, for transcribed-state coloring in the UI. */
    val segmentId: String?,
)

/**
 * Live waveform source (MVP requirement; ux plan Section 8 "Visual Waveform"): keeps a bounded
 * ring of the last [windowMs] of *encoded* frames and decodes them to RMS bars only while the
 * UI is visible ([setActive]). Nothing is decoded on the BLE receive path; when the view is
 * hidden, frames just accumulate (bounded by the window) and are decoded in one catch-up batch
 * on the next activation.
 */
class LiveAudioMonitor(
    private val decoder: LiveFrameDecoder?,
    private val nowMs: () -> Long,
    private val frameSamples: Int = 320,
    private val frameDurationMs: Long = 20,
    val barMs: Long = 250,
    val windowMs: Long = 60_000,
) {
    private class Entry(
        val timeMs: Long,
        val segmentId: String?,
        val payload: ByteArray?,
        val gapDurationMs: Long,
    )

    private class BarAccum(val timeMs: Long, var segmentId: String?) {
        var sumSquares: Double = 0.0
        var sampleCount: Int = 0
        var hasGap: Boolean = false
    }

    private val mutex = Mutex()
    private val pending = ArrayDeque<Entry>()
    private val buckets = LinkedHashMap<Long, BarAccum>()
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    private var scope: CoroutineScope? = null

    private val _bars = MutableStateFlow<List<WaveformBar>>(emptyList())
    val bars: StateFlow<List<WaveformBar>> = _bars.asStateFlow()

    /** Called from the receive path; cheap (no decode). */
    suspend fun onFrames(segmentId: String?, frames: List<SegmentFrame>, receivedAtMs: Long) {
        mutex.withLock {
            frames.forEachIndexed { index, frame ->
                pending.addLast(
                    Entry(
                        timeMs = receivedAtMs + index * frameDurationMs,
                        segmentId = segmentId,
                        payload = frame.payload,
                        gapDurationMs = 0,
                    ),
                )
            }
            trimPendingLocked()
        }
        wakeups.trySend(Unit)
    }

    suspend fun onGap(receivedAtMs: Long, approxDurationMs: Long) {
        mutex.withLock {
            pending.addLast(
                Entry(
                    timeMs = receivedAtMs,
                    segmentId = null,
                    payload = null,
                    gapDurationMs = approxDurationMs.coerceIn(barMs, windowMs),
                ),
            )
            trimPendingLocked()
        }
        wakeups.trySend(Unit)
    }

    /** The Today screen activates the monitor while the waveform is visible. */
    fun setActive(active: Boolean) {
        if (active) {
            if (scope != null) return
            val newScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            scope = newScope
            newScope.launch {
                processPending()
                for (unused in wakeups) {
                    processPending()
                }
            }
            wakeups.trySend(Unit)
        } else {
            scope?.cancel()
            scope = null
        }
    }

    suspend fun processPending() {
        val batch = mutex.withLock {
            val snapshot = pending.toList()
            pending.clear()
            snapshot
        }
        if (batch.isEmpty()) {
            publishBars()
            return
        }

        val framePayloads = batch.mapNotNull { it.payload }
        val pcm = if (framePayloads.isEmpty()) {
            ShortArray(0)
        } else {
            decoder?.decode(framePayloads) ?: ShortArray(0)
        }

        mutex.withLock {
            var sampleOffset = 0
            for (entry in batch) {
                if (entry.payload != null) {
                    val available = min(frameSamples, (pcm.size - sampleOffset).coerceAtLeast(0))
                    var sumSquares = 0.0
                    for (i in sampleOffset until sampleOffset + available) {
                        val sample = pcm[i].toDouble()
                        sumSquares += sample * sample
                    }
                    sampleOffset += available
                    val bucket = bucketLocked(entry.timeMs, entry.segmentId)
                    bucket.sumSquares += sumSquares
                    // When no decoder exists, count the frame anyway so presence still renders.
                    bucket.sampleCount += if (available > 0) available else frameSamples
                } else {
                    var t = entry.timeMs
                    val end = entry.timeMs + entry.gapDurationMs
                    while (t < end) {
                        bucketLocked(t, null).hasGap = true
                        t += barMs
                    }
                }
            }
            trimBucketsLocked()
        }
        publishBars()
    }

    private fun bucketLocked(timeMs: Long, segmentId: String?): BarAccum {
        val key = timeMs / barMs
        return buckets.getOrPut(key) { BarAccum(timeMs = key * barMs, segmentId = segmentId) }
            .also { if (segmentId != null) it.segmentId = segmentId }
    }

    private fun trimPendingLocked() {
        val newest = pending.lastOrNull()?.timeMs ?: return
        while (pending.isNotEmpty() && pending.first().timeMs < newest - windowMs) {
            pending.removeFirst()
        }
    }

    private fun trimBucketsLocked() {
        val newest = buckets.values.maxOfOrNull { it.timeMs } ?: return
        buckets.values.removeAll { it.timeMs < newest - windowMs }
    }

    private suspend fun publishBars() {
        val snapshot = mutex.withLock { buckets.values.sortedBy { it.timeMs }.toList() }
        _bars.value = snapshot.map { accum ->
            val rms = if (accum.sampleCount > 0) sqrt(accum.sumSquares / accum.sampleCount) else 0.0
            val state = when {
                accum.hasGap -> WaveformBarState.Gap
                rms < SILENCE_RMS -> WaveformBarState.Silence
                else -> WaveformBarState.Recorded
            }
            WaveformBar(
                timeMs = accum.timeMs,
                amplitude = sqrt((rms / Short.MAX_VALUE).coerceIn(0.0, 1.0)).toFloat(),
                state = state,
                segmentId = accum.segmentId,
            )
        }
    }

    companion object {
        /** Below this RMS (16-bit full scale 32767) a bar renders as detected silence. */
        const val SILENCE_RMS = 330.0
    }
}

/**
 * Forwards everything to the durable [SegmentStore] first (durability is what checkpoints are
 * computed from), then feeds the live monitor.
 */
class TeeSegmentSink(
    private val store: SegmentStore,
    private val monitor: LiveAudioMonitor,
    private val nowMs: () -> Long,
) : SegmentSink {
    override suspend fun openSegment(
        start: StreamStart,
        receivedAtMs: Long,
        provenance: SegmentProvenance?,
    ) {
        store.openSegment(start, receivedAtMs, provenance)
    }

    override suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>) {
        store.appendFrames(streamId, frames)
        monitor.onFrames(store.openSegmentId, frames, nowMs())
    }

    override suspend fun recordGap(streamId: UInt, gap: GapRecord) {
        store.recordGap(streamId, gap)
        monitor.onGap(nowMs(), gap.missingFrameCount.toLong() * 20)
    }

    override suspend fun closeSegment(reason: SegmentCloseReason) {
        store.closeSegment(reason)
    }
}
