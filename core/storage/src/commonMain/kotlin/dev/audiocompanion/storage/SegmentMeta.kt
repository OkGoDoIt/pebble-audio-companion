package dev.audiocompanion.storage

import dev.audiocompanion.transport.GapOrigin
import dev.audiocompanion.transport.GapRecord
import dev.audiocompanion.transport.SegmentCloseReason
import kotlinx.serialization.Serializable

/**
 * Sidecar metadata for one segment, persisted as `segments/<segment_id>.meta.json` via
 * temp-file + atomic rename. The frame log (`.spxlog`) is the durable source of truth for
 * frames; recovery reconciles this meta against it.
 *
 * The app uses this file-backed index as the durable segment database: each update is written by
 * temp-file + atomic rename, and startup recovery scans these sidecars plus the frame logs.
 */
@Serializable
data class SegmentMeta(
    val segmentId: String,
    val streamId: UInt,
    val protocolVersion: Int,
    val codecIdRaw: Int,
    val channels: Int,
    val frameSamples: Int,
    val sampleRateHz: UInt,
    val bitRateBps: UInt,
    val frameDurationMs: Int,
    /** Watch wall clock at stream start (UTC ms). */
    val startTimeMs: ULong,
    /** Watch monotonic clock at stream start (ms). */
    val startMonotonicMs: ULong,
    /** Phone wall clock when the segment was opened (ms). */
    val receivedAtMs: Long,
    val firstSequence: UInt? = null,
    val lastSequence: UInt? = null,
    val firstSampleIndex: ULong? = null,
    val lastSampleIndexExclusive: ULong? = null,
    val frameCount: Long = 0,
    /** Bytes of the segment's frame log on disk (as of the last meta flush). */
    val logBytes: Long = 0,
    val gaps: List<GapMeta> = emptyList(),
    /** Null while the segment is open. */
    val closeReason: CloseReasonMeta? = null,
    val transcriptionState: TranscriptionState = TranscriptionState.Pending,
    val provenance: ProvenanceMeta? = null,
) {
    val isOpen: Boolean get() = closeReason == null

    /**
     * Terminal-success transcription states only. Disabled is deliberately NOT terminal: a
     * segment that could not be transcribed because no provider was usable becomes eligible
     * again once one is (model downloaded, key added, mode changed).
     */
    val isFullyTranscribed: Boolean
        get() = transcriptionState == TranscriptionState.Complete ||
            transcriptionState == TranscriptionState.NoSpeech
}

@Serializable
data class GapMeta(
    val firstMissingSequence: UInt,
    val missingFrameCount: UInt,
    val firstMissingSampleIndex: ULong,
    /** "watch" (STREAM_GAP) or "sequence_skip" (synthesized by the receiver). */
    val origin: String,
    val reasonRaw: Int? = null,
    val watchDropCounter: UInt? = null,
) {
    companion object {
        const val ORIGIN_WATCH = "watch"
        const val ORIGIN_SEQUENCE_SKIP = "sequence_skip"

        fun from(gap: GapRecord): GapMeta = when (val origin = gap.origin) {
            is GapOrigin.WatchReported -> GapMeta(
                firstMissingSequence = gap.firstMissingSequence,
                missingFrameCount = gap.missingFrameCount,
                firstMissingSampleIndex = gap.firstMissingSampleIndex,
                origin = ORIGIN_WATCH,
                reasonRaw = origin.reasonRaw,
                watchDropCounter = origin.watchDropCounter,
            )
            is GapOrigin.SequenceSkip -> GapMeta(
                firstMissingSequence = gap.firstMissingSequence,
                missingFrameCount = gap.missingFrameCount,
                firstMissingSampleIndex = gap.firstMissingSampleIndex,
                origin = ORIGIN_SEQUENCE_SKIP,
            )
        }
    }
}

@Serializable
data class CloseReasonMeta(
    /** "stopped", "interrupted", "superseded", or "rotated". */
    val kind: String,
    val stopReasonRaw: Int? = null,
    val finalSequence: UInt? = null,
    val finalSampleIndex: ULong? = null,
) {
    companion object {
        const val KIND_STOPPED = "stopped"
        const val KIND_INTERRUPTED = "interrupted"
        const val KIND_SUPERSEDED = "superseded"
        const val KIND_ROTATED = "rotated"

        val Rotated = CloseReasonMeta(KIND_ROTATED)
        val Interrupted = CloseReasonMeta(KIND_INTERRUPTED)

        fun from(reason: SegmentCloseReason): CloseReasonMeta = when (reason) {
            is SegmentCloseReason.Stopped -> CloseReasonMeta(
                kind = KIND_STOPPED,
                stopReasonRaw = reason.reasonRaw,
                finalSequence = reason.finalSequence,
                finalSampleIndex = reason.finalSampleIndex,
            )
            is SegmentCloseReason.Interrupted -> Interrupted
            is SegmentCloseReason.Superseded -> CloseReasonMeta(KIND_SUPERSEDED)
        }
    }
}

@Serializable
enum class TranscriptionState {
    Pending,
    Running,
    Complete,
    NoSpeech,
    Failed,
    Disabled,
}

@Serializable
data class ProvenanceMeta(
    val fwVersionPacked: UInt,
    val protocolVersion: Int,
)
