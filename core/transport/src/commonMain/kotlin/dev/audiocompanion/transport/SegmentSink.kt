package dev.audiocompanion.transport

import dev.audiocompanion.protocol.StreamStart

/** One encoded audio frame, addressed by stream sequence and cumulative sample index. */
class SegmentFrame(
    val sequence: UInt,
    val sampleIndex: ULong,
    val payload: ByteArray,
) {
    override fun toString(): String =
        "SegmentFrame(sequence=$sequence, sampleIndex=$sampleIndex, len=${payload.size})"
}

/** Why a gap record exists in a segment. */
sealed interface GapOrigin {
    /** The watch explicitly reported the gap via STREAM_GAP. */
    data class WatchReported(val reasonRaw: Int, val watchDropCounter: UInt) : GapOrigin

    /** Synthesized by the receiver after observing a sequence discontinuity in STREAM_DATA. */
    data object SequenceSkip : GapOrigin
}

data class GapRecord(
    val firstMissingSequence: UInt,
    /** 0 = unknown / elapsed-time-only gap. */
    val missingFrameCount: UInt,
    val firstMissingSampleIndex: ULong,
    val origin: GapOrigin,
)

/** Why a segment was closed. */
sealed interface SegmentCloseReason {
    /** The watch sent STREAM_STOP. */
    data class Stopped(
        val reasonRaw: Int,
        val finalSequence: UInt,
        val finalSampleIndex: ULong,
    ) : SegmentCloseReason

    /** The BLE link dropped (or the session ended) while the stream was open. */
    data object Interrupted : SegmentCloseReason

    /** A new STREAM_START arrived while a segment was still open. */
    data object Superseded : SegmentCloseReason
}

/** Diagnostics-only provenance attached to a segment. */
data class SegmentProvenance(
    val fwVersionPacked: UInt,
    val protocolVersion: Int,
)

/**
 * Durable storage seam consumed by [AudioReceiverSession]; implemented by :core:storage.
 * All functions are suspend and must only return once the data is durable — the session
 * computes checkpoint sequences from what these calls have accepted.
 */
interface SegmentSink {
    /** Opens a segment for a newly started stream. Any previously open segment was closed. */
    suspend fun openSegment(start: StreamStart, receivedAtMs: Long, provenance: SegmentProvenance?)

    /**
     * Appends frames to the open segment; durable on return. Returns the frames actually
     * persisted — a post-RESUME spool rewind re-sends frames the sink may already hold, and
     * downstream consumers (live waveform, live transcription) must only see what was new.
     */
    suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>): List<SegmentFrame>

    /** Records a gap (watch-reported or synthesized) in the open segment. */
    suspend fun recordGap(streamId: UInt, gap: GapRecord)

    /** Closes the open segment. No-op when no segment is open. */
    suspend fun closeSegment(reason: SegmentCloseReason)
}

/** Receiver-side flags and storage hints carried in CHECKPOINT; provided by :core:storage. */
interface ReceiverPolicy {
    /** Bitmask of ProtocolConstants.RECEIVER_FLAG_*. */
    fun receiverFlags(): UInt

    fun freeStorageHintKb(): UInt
}

/** Persisted state that lets a restarted process resume a receiver session. */
data class ReceiverResumeState(
    val lastStreamId: UInt,
    /** Highest contiguous sequence persisted, or null when nothing was persisted. */
    val lastContiguousSequence: UInt?,
    val lastSampleIndex: ULong,
)

interface ReceiverResumeStore {
    suspend fun save(state: ReceiverResumeState)

    suspend fun load(): ReceiverResumeState?

    suspend fun clear() {}
}
