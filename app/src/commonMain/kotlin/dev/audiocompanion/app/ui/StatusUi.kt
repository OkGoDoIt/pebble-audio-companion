@file:OptIn(kotlin.ExperimentalUnsignedTypes::class)

package dev.audiocompanion.app.ui

import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.protocol.GapReason
import dev.audiocompanion.protocol.ServiceState
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.storage.TranscriptionState
import dev.audiocompanion.transport.ReceiverSessionState

/** Severity drives the status dot/banner color: neutral, active, attention, problem. */
enum class StatusSeverity { Neutral, Info, Active, Warning, Error }

/** What the one primary action in the status header should do. */
enum class PrimaryAction { None, Start, Stop, PairWatch, Troubleshoot, SetUpAgain, Reconnect }

data class StatusUiModel(
    val headline: String,
    val supporting: String?,
    val severity: StatusSeverity,
    val primaryAction: PrimaryAction,
)

/**
 * Maps receiver/protocol state to the plain-language copy from
 * docs/ux-visual-design-plan.md Section 13. No protocol vocabulary may appear here.
 *
 * [watchServiceStateRaw] is the watch's own reported state (Info read + state-change pushes);
 * when the watch says it is paused/disabled, that wins over the session-level view so the
 * phone always matches what the watch's Settings screen shows.
 */
fun statusUiModel(
    state: ReceiverSessionState,
    settings: AudioCompanionSettings,
    diagnostics: AudioCompanionDiagnostics,
    watchServiceStateRaw: Int? = null,
): StatusUiModel {
    if (state is ReceiverSessionState.Streaming || state is ReceiverSessionState.Authorized) {
        watchStatusOverride(watchServiceStateRaw, diagnostics)?.let { return it }
    }
    return statusForSessionState(state, settings, diagnostics)
}

/** Watch-reported states that the phone must mirror (paused, disabled, error). */
private fun watchStatusOverride(
    watchServiceStateRaw: Int?,
    diagnostics: AudioCompanionDiagnostics,
): StatusUiModel? = when (ServiceState.fromRaw(watchServiceStateRaw ?: -1)) {
    ServiceState.Disabled -> StatusUiModel(
        headline = "Background audio is off on the watch",
        supporting = "Tap Start Recording when you want to ask your watch to turn it on.",
        severity = StatusSeverity.Neutral,
        primaryAction = PrimaryAction.Start,
    )
    ServiceState.PausedConflict -> StatusUiModel(
        headline = "Paused: the watch is using its microphone",
        supporting = "Recording resumes when the watch finishes.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )
    ServiceState.PausedPolicy ->
        if (diagnostics.pauseRequested) {
            StatusUiModel(
                headline = "Paused: phone storage low",
                supporting = "Free storage or reduce retention to resume recording.",
                severity = StatusSeverity.Warning,
                primaryAction = PrimaryAction.None,
            )
        } else {
            StatusUiModel(
                headline = "Paused",
                supporting = "Recording is paused. Start again when you're ready.",
                severity = StatusSeverity.Neutral,
                primaryAction = PrimaryAction.Start,
            )
        }
    ServiceState.PausedLowBattery -> StatusUiModel(
        headline = "Paused to protect watch battery",
        supporting = "Recording resumes once the watch has charged.",
        severity = StatusSeverity.Warning,
        primaryAction = PrimaryAction.None,
    )
    ServiceState.PausedPowerSave -> StatusUiModel(
        headline = "Paused while the watch is saving power",
        supporting = "Recording resumes when the watch wakes or leaves low power mode.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )
    ServiceState.Error -> StatusUiModel(
        headline = "Watch audio needs attention",
        supporting = "Check the watch's Settings -> Audio Companion.",
        severity = StatusSeverity.Warning,
        primaryAction = PrimaryAction.Troubleshoot,
    )
    else -> null
}

private fun statusForSessionState(
    state: ReceiverSessionState,
    settings: AudioCompanionSettings,
    diagnostics: AudioCompanionDiagnostics,
): StatusUiModel = when (state) {
    ReceiverSessionState.Disconnected ->
        if (!settings.backgroundReceiverEnabled) {
            StatusUiModel(
                headline = "Background audio is off",
                supporting = "Start when you want your Pebble to record.",
                severity = StatusSeverity.Neutral,
                primaryAction = PrimaryAction.Start,
            )
        } else {
            StatusUiModel(
                headline = "Waiting for Pebble",
                supporting = "Trying to reconnect. The watch can buffer briefly.",
                severity = StatusSeverity.Info,
                primaryAction = PrimaryAction.Reconnect,
            )
        }

    is ReceiverSessionState.ConnectionFailed -> StatusUiModel(
        headline = "Connection failed",
        supporting = state.message,
        severity = StatusSeverity.Warning,
        primaryAction = PrimaryAction.Troubleshoot,
    )

    ReceiverSessionState.Connecting -> StatusUiModel(
        headline = "Connecting to your Pebble",
        supporting = "This usually takes a few seconds.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.Reconnect,
    )

    ReceiverSessionState.Authorizing -> StatusUiModel(
        headline = "Authorizing receiver",
        supporting = null,
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.Reconnect,
    )

    ReceiverSessionState.PendingConsent -> StatusUiModel(
        headline = "Confirm on your watch",
        supporting = "Your watch is asking whether this app may receive microphone audio.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )

    ReceiverSessionState.PendingEnable -> StatusUiModel(
        headline = "Turn on Background Audio on your watch",
        supporting = "Approve the prompt on your Pebble to start recording.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )

    is ReceiverSessionState.Denied -> when (state.status) {
        AuthStatus.DeniedMismatch -> StatusUiModel(
            headline = "This watch is authorized for another receiver",
            supporting = "Open watch Settings -> Audio Companion -> Forget Receiver, then try again.",
            severity = StatusSeverity.Warning,
            primaryAction = PrimaryAction.Troubleshoot,
        )
        AuthStatus.DeniedDisabled -> StatusUiModel(
            headline = "Background audio is off on the watch",
            supporting = "Tap Start Recording when you're ready, then approve the prompt on your watch.",
            severity = StatusSeverity.Warning,
            primaryAction = PrimaryAction.Start,
        )
        else -> StatusUiModel(
            headline = "Not authorized",
            supporting = "The watch declined this receiver. Try again to re-request access.",
            severity = StatusSeverity.Warning,
            primaryAction = PrimaryAction.Troubleshoot,
        )
    }

    ReceiverSessionState.Authorized -> StatusUiModel(
        headline = "Authorized and ready",
        supporting = "Waiting for the watch to start streaming.",
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )

    is ReceiverSessionState.Streaming ->
        if (diagnostics.pauseRequested) {
            StatusUiModel(
                headline = "Paused: phone storage low",
                supporting = "Free storage or reduce retention to resume receiving.",
                severity = StatusSeverity.Warning,
                primaryAction = PrimaryAction.None,
            )
        } else {
            StatusUiModel(
                headline = "Recording from Pebble",
                supporting = "Audio is being stored on this phone.",
                severity = StatusSeverity.Active,
                primaryAction = PrimaryAction.Stop,
            )
        }

    is ReceiverSessionState.Revoked -> StatusUiModel(
        headline = "Receiver access was revoked",
        supporting = "The watch no longer allows this app to receive audio.",
        severity = StatusSeverity.Error,
        primaryAction = PrimaryAction.SetUpAgain,
    )
}

/** Short plain-language label for the watch's reported state (Settings "Watch" row). */
fun watchServiceStateLabel(raw: Int?): String = when (ServiceState.fromRaw(raw ?: -1)) {
    ServiceState.Disabled -> "Background audio off"
    ServiceState.Idle -> "Waiting for this app"
    ServiceState.AuthorizedIdle -> "Authorized, not recording"
    ServiceState.Streaming -> "Recording"
    ServiceState.PausedConflict -> "Paused: microphone in use"
    ServiceState.PausedPolicy -> "Paused"
    ServiceState.PausedLowBattery -> "Paused: low battery"
    ServiceState.PausedPowerSave -> "Paused: power save"
    ServiceState.Error -> "Needs attention"
    null -> "Not connected"
}

/**
 * Plain-language reason for one gap. Calm by design (ux plan: "visible but not alarmist");
 * gaps are expected in normal use, so no "Gap:"/error framing.
 */
fun gapDescription(gap: GapMeta): String {
    val reason = gap.reasonRaw?.let { GapReason.fromRaw(it) }
    return when {
        gap.origin == GapMeta.ORIGIN_SEQUENCE_SKIP -> "phone briefly missed audio"
        reason == GapReason.SpoolOverflow -> "watch buffer filled while disconnected"
        reason == GapReason.MicConflict -> "watch dictation used the mic"
        reason == GapReason.UserDisabled -> "recording was paused"
        reason == GapReason.LowBattery -> "paused for watch battery"
        reason == GapReason.CodecError -> "watch audio hiccup"
        reason == GapReason.TransportReset -> "connection was interrupted"
        reason == GapReason.PowerSave -> "watch was saving power"
        reason == GapReason.SilenceSuppressed -> "quiet audio was skipped"
        else -> "audio missing"
    }
}

/**
 * A silence-suppressed gap is audio the watch intentionally skipped because it was below the
 * voice-activity threshold — known-quiet time it withheld to save Bluetooth/battery, not lost
 * audio. The app treats it as silence everywhere, never as a gap, interruption, or error.
 */
fun isSilenceGap(gap: GapMeta): Boolean =
    gap.reasonRaw?.let { GapReason.fromRaw(it)?.isSilence } == true

/**
 * Gaps that should be presented as genuine missing audio. A small number of field builds could
 * store a receiver-synthesized sequence skip adjacent to the watch's explicit skipped-silence
 * record for the same range. For display, the watch's silence reason wins: that time was known
 * quiet, not a phone/link failure. The raw metadata remains unchanged for diagnostics.
 */
fun visibleLossGaps(meta: SegmentMeta): List<GapMeta> {
    val visibility = GapVisibility(meta.gaps)
    return meta.gaps.filter { visibility.isVisibleLoss(it) }
}

fun quietGaps(meta: SegmentMeta): List<GapMeta> {
    val visibility = GapVisibility(meta.gaps)
    return meta.gaps.filter { !visibility.isVisibleLoss(it) }
}

/**
 * Precomputes silence-coverage for one segment's gaps so visibility is a binary search instead of
 * a per-gap rescan of the whole list. A segment can accumulate thousands of gap records (every
 * silence-suppression span, overflow, and reconnect adds one), so the old O(n²)
 * `allGaps.none { … }` froze the main thread for ~12 s while building the Today timeline once the
 * test library grew. Silence intervals are sorted by start with a running max end, which answers
 * "is this sequence-skip fully covered by some single silence gap?" in O(log n).
 */
class GapVisibility(gaps: List<GapMeta>) {
    private val silenceStarts: UIntArray
    private val silenceMaxEnd: UIntArray

    init {
        val silence = gaps.asSequence()
            .filter { isSilenceGap(it) }
            .map { it.firstMissingSequence to (it.firstMissingSequence + it.missingFrameCount) }
            .sortedBy { it.first }
            .toList()
        silenceStarts = UIntArray(silence.size) { silence[it].first }
        silenceMaxEnd = UIntArray(silence.size)
        var runningMax = 0u
        for (i in silence.indices) {
            runningMax = if (i == 0) silence[i].second else maxOf(runningMax, silence[i].second)
            silenceMaxEnd[i] = runningMax
        }
    }

    fun isVisibleLoss(gap: GapMeta): Boolean {
        if (isSilenceGap(gap)) return false
        if (gap.origin != GapMeta.ORIGIN_SEQUENCE_SKIP) return true
        val start = gap.firstMissingSequence
        return !coveredBySingleSilenceGap(start, start + gap.missingFrameCount)
    }

    private fun coveredBySingleSilenceGap(start: UInt, end: UInt): Boolean {
        // Largest index whose silence start <= `start`; its prefix max end is the widest a single
        // silence gap (with start <= start) reaches, so >= end means one fully covers [start, end).
        var lo = 0
        var hi = silenceStarts.size - 1
        var idx = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (silenceStarts[mid] <= start) {
                idx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return idx >= 0 && silenceMaxEnd[idx] >= end
    }
}

fun isVisibleLossGap(gap: GapMeta, allGaps: List<GapMeta>): Boolean {
    return GapVisibility(allGaps).isVisibleLoss(gap)
}

/** Approximate gap length from missing frame count (20 ms frames). */
fun gapDurationMs(gap: GapMeta, frameDurationMs: Int): Long =
    gap.missingFrameCount.toLong() * frameDurationMs

/** Total approximate missing time of a segment (intentionally-skipped silence excluded). */
fun totalGapMs(meta: SegmentMeta): Long =
    visibleLossGaps(meta).sumOf { gapDurationMs(it, meta.frameDurationMs) }

/** User-facing missing time, guarded against stale/impossible gap metadata. */
fun displayGapMs(meta: SegmentMeta): Long {
    val totalMs = totalGapMs(meta)
    val durationMs = segmentDurationMs(meta)
    return when {
        totalMs <= 0 -> 0
        durationMs > 0 -> totalMs.coerceAtMost(durationMs)
        else -> totalMs
    }
}

data class GapReasonBreakdown(
    val reason: String,
    val count: Int,
    val durationMs: Long,
)

/**
 * Compact interruption diagnostics for detail screens. Durations are scaled down if stale
 * metadata claims more loss than the segment can contain, matching [displayGapMs].
 */
fun gapReasonBreakdown(meta: SegmentMeta): List<GapReasonBreakdown> {
    val lost = visibleLossGaps(meta)
    if (lost.isEmpty()) return emptyList()
    val rawTotalMs = lost.sumOf { gapDurationMs(it, meta.frameDurationMs) }
    val displayTotalMs = displayGapMs(meta)
    fun displayDuration(rawMs: Long): Long {
        if (rawMs <= 0 || rawTotalMs <= 0 || displayTotalMs <= 0 || rawTotalMs <= displayTotalMs) {
            return rawMs
        }
        return (rawMs * displayTotalMs / rawTotalMs).coerceAtLeast(1)
    }
    return lost
        .groupBy { gapDescription(it) }
        .map { (reason, gaps) ->
            val rawMs = gaps.sumOf { gapDurationMs(it, meta.frameDurationMs) }
            GapReasonBreakdown(
                reason = reason,
                count = gaps.size,
                durationMs = displayDuration(rawMs),
            )
        }
        .sortedWith(compareByDescending<GapReasonBreakdown> { it.durationMs }.thenBy { it.reason })
}

/**
 * One calm summary line for a segment's gaps, or null when there are none:
 * "Missing ~1m 20s (watch dictation used the mic)".
 */
fun gapSummary(meta: SegmentMeta): String? {
    val lost = visibleLossGaps(meta)
    if (lost.isEmpty()) return null
    val totalMs = displayGapMs(meta)
    val reasons = lost.map { gapDescription(it) }.distinct()
    val reasonText = when {
        reasons.size == 1 -> reasons.single()
        else -> "several reasons"
    }
    return when {
        // Sub-second losses would render as the absurd "0 sec".
        totalMs in 1..999 -> "Audio was briefly interrupted ($reasonText)"
        totalMs > 0 -> "Audio was interrupted for about ${Formatting.duration(totalMs)} ($reasonText)"
        else -> "Audio was interrupted ($reasonText)"
    }
}

/** Plain-language transcription state for list rows (ux plan Section 18). */
fun transcriptionStateLabel(state: TranscriptionState): String = when (state) {
    TranscriptionState.Pending -> "Waiting to transcribe"
    TranscriptionState.Running -> "Transcribing"
    TranscriptionState.Uploading -> "Uploading to cloud"
    TranscriptionState.Complete -> "Transcript ready"
    TranscriptionState.NoSpeech -> "No speech"
    TranscriptionState.Failed -> "Transcription failed"
    TranscriptionState.Disabled -> "Transcription unavailable"
}

/** Duration of a segment in ms, preferring the sample counters (gaps included). */
fun segmentDurationMs(meta: SegmentMeta): Long {
    val first = meta.firstSampleIndex
    val lastExclusive = meta.lastSampleIndexExclusive
    if (first != null && lastExclusive != null && lastExclusive > first && meta.sampleRateHz > 0u) {
        return ((lastExclusive - first) * 1000uL / meta.sampleRateHz.toULong()).toLong()
    }
    return meta.frameCount * meta.frameDurationMs
}
