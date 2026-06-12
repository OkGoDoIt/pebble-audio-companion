package dev.audiocompanion.app.ui

import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.protocol.GapReason
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
 */
fun statusUiModel(
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

/** Plain-language reason for one gap (ux plan: visible but not alarmist). */
fun gapDescription(gap: GapMeta): String {
    val reason = gap.reasonRaw?.let { GapReason.fromRaw(it) }
    return when {
        gap.origin == GapMeta.ORIGIN_SEQUENCE_SKIP -> "Gap: phone missed some audio"
        reason == GapReason.SpoolOverflow -> "Some audio was skipped: the watch buffer filled while the phone was unavailable"
        reason == GapReason.MicConflict -> "Gap: watch dictation used the microphone"
        reason == GapReason.UserDisabled -> "Gap: background audio was turned off"
        reason == GapReason.LowBattery -> "Gap: paused to protect watch battery"
        reason == GapReason.CodecError -> "Gap: watch audio error"
        reason == GapReason.TransportReset -> "Gap: connection was interrupted"
        else -> "Gap: audio missing"
    }
}

/** Approximate gap length from missing frame count (20 ms frames). */
fun gapDurationMs(gap: GapMeta, frameDurationMs: Int): Long =
    gap.missingFrameCount.toLong() * frameDurationMs

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
