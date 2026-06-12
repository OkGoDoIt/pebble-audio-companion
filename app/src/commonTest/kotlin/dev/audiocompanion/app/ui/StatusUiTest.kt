package dev.audiocompanion.app.ui

import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.GapMeta
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.SegmentTranscript
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transport.ReceiverSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private fun meta(
    segmentId: String,
    receivedAtMs: Long,
    open: Boolean = false,
    gaps: List<GapMeta> = emptyList(),
) = SegmentMeta(
    segmentId = segmentId,
    streamId = 7u,
    protocolVersion = 1,
    codecIdRaw = 1,
    channels = 1,
    frameSamples = 320,
    sampleRateHz = 16_000u,
    bitRateBps = 9_800u,
    frameDurationMs = 20,
    startTimeMs = receivedAtMs.toULong(),
    startMonotonicMs = 1_000uL,
    receivedAtMs = receivedAtMs,
    firstSampleIndex = 0uL,
    lastSampleIndexExclusive = 160_000uL, // 10 s
    frameCount = 500,
    gaps = gaps,
    closeReason = if (open) null else CloseReasonMeta.Rotated,
)

private fun transcript(segmentId: String, text: String) = SegmentTranscript(
    segmentId = segmentId,
    text = text,
    modeUsed = TranscriptionMode.LocalOnly,
    providerId = "local",
    modelUsed = null,
    createdAtMs = 0,
)

class StatusUiTest {

    @Test
    fun disconnectedAndDisabledIsOffWithStartAction() {
        val status = statusUiModel(
            ReceiverSessionState.Disconnected,
            AudioCompanionSettings(backgroundReceiverEnabled = false),
            AudioCompanionDiagnostics(),
        )
        assertEquals("Background audio is off", status.headline)
        assertEquals(PrimaryAction.Start, status.primaryAction)
        assertEquals(StatusSeverity.Neutral, status.severity)
    }

    @Test
    fun disconnectedWhileEnabledIsWaitingForPebble() {
        val status = statusUiModel(
            ReceiverSessionState.Disconnected,
            AudioCompanionSettings(backgroundReceiverEnabled = true),
            AudioCompanionDiagnostics(),
        )
        assertEquals("Waiting for Pebble", status.headline)
    }

    @Test
    fun streamingIsRecordingWithStopAction() {
        val status = statusUiModel(
            ReceiverSessionState.Streaming(streamId = 9u),
            AudioCompanionSettings(backgroundReceiverEnabled = true),
            AudioCompanionDiagnostics(),
        )
        assertEquals("Recording from Pebble", status.headline)
        assertEquals(PrimaryAction.Stop, status.primaryAction)
        assertEquals(StatusSeverity.Active, status.severity)
    }

    @Test
    fun streamingUnderStoragePressureIsPaused() {
        val status = statusUiModel(
            ReceiverSessionState.Streaming(streamId = 9u),
            AudioCompanionSettings(backgroundReceiverEnabled = true),
            AudioCompanionDiagnostics(pauseRequested = true),
        )
        assertEquals("Paused: phone storage low", status.headline)
        assertEquals(StatusSeverity.Warning, status.severity)
    }

    @Test
    fun deniedMismatchExplainsForeignReceiver() {
        val status = statusUiModel(
            ReceiverSessionState.Denied(AuthStatus.DeniedMismatch.raw),
            AudioCompanionSettings(backgroundReceiverEnabled = true),
            AudioCompanionDiagnostics(),
        )
        assertEquals("This watch is authorized for another receiver", status.headline)
    }

    @Test
    fun noProtocolVocabularyInHeadlines() {
        val states = listOf(
            ReceiverSessionState.Disconnected,
            ReceiverSessionState.ConnectionFailed("Peripheral disconnected"),
            ReceiverSessionState.Connecting,
            ReceiverSessionState.Authorizing,
            ReceiverSessionState.PendingConsent,
            ReceiverSessionState.Denied(AuthStatus.DeniedDisabled.raw),
            ReceiverSessionState.Authorized,
            ReceiverSessionState.Streaming(1u),
            ReceiverSessionState.Revoked(1),
        )
        val banned = listOf("GATT", "AUTH", "checkpoint", "spool", "sequence", "stream id", "NimBLE")
        for (state in states) {
            val status = statusUiModel(
                state,
                AudioCompanionSettings(backgroundReceiverEnabled = true),
                AudioCompanionDiagnostics(),
            )
            val text = status.headline + " " + status.supporting.orEmpty()
            banned.forEach { word ->
                assertTrue(
                    !text.contains(word, ignoreCase = false),
                    "state $state copy must not mention '$word': $text",
                )
            }
        }
    }
}

class TimelineTest {
    private val dayMs = 24 * 3_600_000L
    private val nowMs = 1_750_000_000_000L // fixed reference time

    @Test
    fun timelineShowsOnlyTodayNewestFirstWithInlineGaps() {
        val today1 = meta("seg-1", nowMs - 3_600_000)
        val today2 = meta(
            "seg-2",
            nowMs - 600_000,
            gaps = listOf(
                GapMeta(
                    firstMissingSequence = 10u,
                    missingFrameCount = 100u,
                    firstMissingSampleIndex = 3_200uL,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = 2, // mic conflict
                ),
            ),
        )
        val lastWeek = meta("seg-old", nowMs - 7 * dayMs)

        val timeline = buildTimeline(
            segments = listOf(today1, lastWeek, today2),
            transcriptOf = { null },
            nowMs = nowMs,
        )

        val keys = timeline.map { it.key }
        assertEquals(listOf("seg-seg-2", "gap-seg-2-0", "seg-seg-1"), keys)
        val gap = timeline[1] as TimelineItem.Gap
        assertTrue(gap.description.contains("dictation"), gap.description)
        assertEquals(2_000, gap.approxDurationMs) // 100 frames * 20 ms
    }

    @Test
    fun segmentTitlePrefersTranscriptSnippet() {
        val meta = meta("seg-1", nowMs)
        assertEquals("Conversation", segmentTitle(meta, null))
        assertEquals("Hello there", segmentTitle(meta, transcript("seg-1", "Hello there")))
        val long = "word ".repeat(40).trim()
        assertTrue(segmentTitle(meta, transcript("seg-1", long)).endsWith("…"))
        assertEquals("Recording now", segmentTitle(meta("seg-2", nowMs, open = true), null))
    }

    @Test
    fun segmentDurationPrefersSampleCounters() {
        assertEquals(10_000, segmentDurationMs(meta("seg-1", nowMs)))
    }
}

class FormattingTest {
    @Test
    fun durationsReadNaturally() {
        assertEquals("38 sec", Formatting.duration(38_000))
        assertEquals("5 min", Formatting.duration(5 * 60_000))
        assertEquals("1 hr 12 min", Formatting.duration(72 * 60_000))
    }

    @Test
    fun storageSizesReadNaturally() {
        assertEquals("1.5 GB", Formatting.storageSize(1_610_612_736))
        assertEquals("320 MB", Formatting.storageSize(320L * 1024 * 1024))
        assertEquals("12 KB", Formatting.storageSize(12_288))
    }
}
