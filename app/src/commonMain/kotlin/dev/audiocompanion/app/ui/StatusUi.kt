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
enum class PrimaryAction { None, Start, Stop, PairWatch, Troubleshoot, SetUpAgain }

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
        supporting = "Turn it on in the watch's Settings -> Audio Companion.",
        severity = StatusSeverity.Neutral,
        primaryAction = PrimaryAction.None,
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
                primaryAction = PrimaryAction.Troubleshoot,
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
        supporting = null,
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )

    ReceiverSessionState.Authorizing -> StatusUiModel(
        headline = "Authorizing receiver",
        supporting = null,
        severity = StatusSeverity.Info,
        primaryAction = PrimaryAction.None,
    )

    ReceiverSessionState.PendingConsent -> StatusUiModel(
        headline = "Confirm on your watch",
        supporting = "Your watch is asking whether this app may receive microphone audio.",
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
            headline = "Turn on Background Audio on your watch",
            supporting = "Open watch Settings -> Audio Companion and turn Background Audio on.",
            severity = StatusSeverity.Warning,
            primaryAction = PrimaryAction.None,
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

/** Approximate gap length from missing frame count (20 ms frames). */
fun gapDurationMs(gap: GapMeta, frameDurationMs: Int): Long =
    gap.missingFrameCount.toLong() * frameDurationMs

/** Total approximate missing time of a segment (intentionally-skipped silence excluded). */
fun totalGapMs(meta: SegmentMeta): Long =
    meta.gaps.filterNot(::isSilenceGap).sumOf { gapDurationMs(it, meta.frameDurationMs) }

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

/**
 * One calm summary line for a segment's gaps, or null when there are none:
 * "Missing ~1m 20s (watch dictation used the mic)".
 */
fun gapSummary(meta: SegmentMeta): String? {
    val lost = meta.gaps.filterNot(::isSilenceGap)
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
