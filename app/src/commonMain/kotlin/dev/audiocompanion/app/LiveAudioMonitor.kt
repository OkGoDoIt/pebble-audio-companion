package dev.audiocompanion.app

import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transport.GapOrigin
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
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.pow
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

enum class WaveformBarState {
    Recorded,
    Silence,

    /** Voice-activity silence the watch skipped sending: known-quiet, rendered as a subtle tick. */
    SuppressedSilence,
    Gap,
}

/** One ~250 ms bar of the live waveform. */
data class WaveformBar(
    val timeMs: Long,
    /** 0..1 display amplitude. */
    val amplitude: Float,
    val state: WaveformBarState,
    /** Segment the audio belongs to, for transcribed-state coloring in the UI. */
    val segmentId: String?,
    /** Highest stream sample index in this bucket; compares against the live-transcribed boundary. */
    val maxSampleIndex: ULong? = null,
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
    private val maxDecodeFramesPerPass: Int = 250,
    private val maxActivationCatchUpFrames: Int = 500,
) {
    init {
        require(maxDecodeFramesPerPass > 0)
        require(maxActivationCatchUpFrames >= maxDecodeFramesPerPass)
    }

    private class Entry(
        val timeMs: Long,
        val segmentId: String?,
        val payload: ByteArray?,
        val gapDurationMs: Long,
        val sampleIndex: ULong? = null,
        /** True for voice-activity silence the watch skipped: render as quiet, not as a gap. */
        val silenceFill: Boolean = false,
    )

    private class BarAccum(val timeMs: Long, var segmentId: String?) {
        var sumSquares: Double = 0.0
        var sampleCount: Int = 0
        var hasGap: Boolean = false
        var suppressed: Boolean = false
        var maxSampleIndex: ULong? = null
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
                        sampleIndex = frame.sampleIndex,
                    ),
                )
            }
            trimPendingLocked()
        }
        wakeups.trySend(Unit)
    }

    /**
     * Records a span with no received audio. [silence] = true marks voice-activity silence the
     * watch withheld to save power: it renders as quiet (flat) bars, never as an amber gap,
     * because no audio was lost. [silence] = false marks a genuine gap (audio that should have
     * arrived but did not).
     */
    suspend fun onGap(receivedAtMs: Long, approxDurationMs: Long, silence: Boolean = false) {
        mutex.withLock {
            pending.addLast(
                Entry(
                    timeMs = receivedAtMs,
                    segmentId = null,
                    payload = null,
                    gapDurationMs = approxDurationMs.coerceIn(barMs, windowMs),
                    silenceFill = silence,
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
                mutex.withLock { trimActivationBacklogLocked() }
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
            drainPendingBatchLocked()
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
                    entry.sampleIndex?.let { sample ->
                        bucket.maxSampleIndex = maxOf(bucket.maxSampleIndex ?: sample, sample)
                    }
                } else {
                    // Gaps and skipped-silence spans are reported at their trailing edge (the
                    // moment audio resumes), so fill backward across the span that just ended.
                    // Filling forward would place the bars past "now", where the view — which
                    // skips any bar with age < 0 — never draws them, leaving the span blank.
                    var t = entry.timeMs - entry.gapDurationMs
                    while (t < entry.timeMs) {
                        val bucket = bucketLocked(t, null)
                        // Skipped silence reads as a quiet tick; only genuine gaps get amber.
                        if (entry.silenceFill) bucket.suppressed = true else bucket.hasGap = true
                        t += barMs
                    }
                }
            }
            trimBucketsLocked()
        }
        publishBars()
        val hasMore = mutex.withLock { pending.isNotEmpty() }
        if (hasMore) wakeups.trySend(Unit)
    }

    private fun drainPendingBatchLocked(): List<Entry> {
        val snapshot = mutableListOf<Entry>()
        var decodeFrames = 0
        while (pending.isNotEmpty()) {
            val entry = pending.first()
            if (snapshot.isNotEmpty()) {
                if (snapshot.size >= maxDecodeFramesPerPass * 2) break
                if (entry.payload != null && decodeFrames >= maxDecodeFramesPerPass) break
            }
            val removed = pending.removeFirst()
            snapshot += removed
            if (removed.payload != null) decodeFrames += 1
        }
        return snapshot
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

    private fun trimActivationBacklogLocked() {
        var payloadCount = pending.count { it.payload != null }
        while (payloadCount > maxActivationCatchUpFrames && pending.isNotEmpty()) {
            if (pending.removeFirst().payload != null) {
                payloadCount -= 1
            }
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
                // Skipped silence, but only if no real audio also landed in this bucket.
                accum.suppressed && accum.sampleCount == 0 -> WaveformBarState.SuppressedSilence
                rms < SILENCE_RMS -> WaveformBarState.Silence
                else -> WaveformBarState.Recorded
            }
            WaveformBar(
                timeMs = accum.timeMs,
                amplitude = displayAmplitude(rms),
                state = state,
                segmentId = accum.segmentId,
                maxSampleIndex = accum.maxSampleIndex,
            )
        }
    }

    companion object {
        /** Below this RMS (16-bit full scale 32767) a bar renders as detected silence. */
        const val SILENCE_RMS = 90.0

        /**
         * Watch speech can decode to low PCM levels after Speex. Map RMS on a dB-like curve so
         * speech just above quiet is visible without flattening quiet, normal, and loud speech
         * into nearly the same bar height.
         */
        fun displayAmplitude(rms: Double): Float {
            if (rms <= 0.0) return 0f
            val normalized = (
                ln(rms.coerceAtLeast(SILENCE_RMS) / SILENCE_RMS) /
                    ln(DISPLAY_LOUD_RMS / SILENCE_RMS)
                ).coerceIn(0.0, 1.0)
            return (DISPLAY_MIN_RECORDED_AMPLITUDE +
                (1.0 - DISPLAY_MIN_RECORDED_AMPLITUDE) *
                normalized.pow(1.5)).toFloat()
        }

        private const val DISPLAY_LOUD_RMS = 8_000.0
        private const val DISPLAY_MIN_RECORDED_AMPLITUDE = 0.08
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
    /** Optional live-audio fan-out for real-time cloud transcription; null disables it. */
    private val tap: LiveAudioTap? = null,
    /** Called when a segment becomes newly eligible for closed-segment processing. */
    private val onSegmentClosed: () -> Unit = {},
) : SegmentSink {
    override suspend fun openSegment(
        start: StreamStart,
        receivedAtMs: Long,
        provenance: SegmentProvenance?,
    ) {
        val previousId = store.openSegmentId
        store.openSegment(start, receivedAtMs, provenance)
        val segmentId = store.openSegmentId
        if (previousId != null && previousId != segmentId) {
            tap?.emit(LiveAudioEvent.SegmentClosed(previousId))
            onSegmentClosed()
        }
        segmentId?.let(::emitSegmentOpened)
    }

    override suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>) {
        val receivingSegmentId = store.openSegmentId
        store.appendFrames(streamId, frames)
        monitor.onFrames(receivingSegmentId, frames, nowMs())
        if (tap != null && receivingSegmentId != null) {
            tap.emit(LiveAudioEvent.FramesAppended(receivingSegmentId, frames))
        }

        val nextSegmentId = store.openSegmentId
        if (receivingSegmentId != null && receivingSegmentId != nextSegmentId) {
            tap?.emit(LiveAudioEvent.SegmentClosed(receivingSegmentId))
            onSegmentClosed()
            nextSegmentId?.let(::emitSegmentOpened)
        }
    }

    override suspend fun recordGap(streamId: UInt, gap: GapRecord) {
        store.recordGap(streamId, gap)
        val silence = (gap.origin as? GapOrigin.WatchReported)
            ?.let { GapReason.fromRaw(it.reasonRaw)?.isSilence } == true
        monitor.onGap(nowMs(), gap.missingFrameCount.toLong() * 20, silence = silence)
    }

    override suspend fun closeSegment(reason: SegmentCloseReason) {
        val closingId = store.openSegmentId
        store.closeSegment(reason)
        closingId?.let {
            tap?.emit(LiveAudioEvent.SegmentClosed(it))
            onSegmentClosed()
        }
    }

    private fun emitSegmentOpened(segmentId: String) {
        val meta = store.readMeta(segmentId) ?: return
        tap?.emit(
            LiveAudioEvent.SegmentOpened(
                segmentId = segmentId,
                sampleRateHz = meta.sampleRateHz.toInt(),
                bitRateBps = meta.bitRateBps.toInt(),
                frameSamples = meta.frameSamples,
            ),
        )
    }
}
