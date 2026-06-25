package dev.audiocompanion.app.ui

import dev.audiocompanion.app.AudioCompanionDiagnostics
import dev.audiocompanion.app.AudioCompanionSettings
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.protocol.GapReason
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
    fun watchReportedStateOverridesSessionView() {
        val settings = AudioCompanionSettings(backgroundReceiverEnabled = true)
        val diagnostics = AudioCompanionDiagnostics()

        // The watch paused for dictation mid-stream: the phone must not claim Recording.
        val conflict = statusUiModel(
            ReceiverSessionState.Streaming(7u), settings, diagnostics, watchServiceStateRaw = 4,
        )
        assertTrue(conflict.headline.contains("microphone"), conflict.headline)

        // Watch-side toggle off while connected.
        val disabled = statusUiModel(
            ReceiverSessionState.Authorized, settings, diagnostics, watchServiceStateRaw = 0,
        )
        assertTrue(disabled.headline.contains("off on the watch"), disabled.headline)
        assertEquals(PrimaryAction.Start, disabled.primaryAction)

        // Phone-requested pause offers Start to resume.
        val paused = statusUiModel(
            ReceiverSessionState.Authorized, settings, diagnostics, watchServiceStateRaw = 5,
        )
        assertEquals(PrimaryAction.Start, paused.primaryAction)

        // Storage-policy pause keeps the storage copy.
        val storagePaused = statusUiModel(
            ReceiverSessionState.Streaming(7u),
            settings,
            AudioCompanionDiagnostics(pauseRequested = true),
            watchServiceStateRaw = 5,
        )
        assertTrue(storagePaused.headline.contains("storage"), storagePaused.headline)

        // Watch-side power policy is held by the watch and should not offer app resume.
        val powerSave = statusUiModel(
            ReceiverSessionState.Streaming(7u), settings, diagnostics, watchServiceStateRaw = 8,
        )
        assertTrue(powerSave.headline.contains("saving power"), powerSave.headline)
        assertEquals(PrimaryAction.None, powerSave.primaryAction)

        // Unknown/streaming watch state defers to the session view.
        val streaming = statusUiModel(
            ReceiverSessionState.Streaming(7u), settings, diagnostics, watchServiceStateRaw = 3,
        )
        assertEquals("Recording from Pebble", streaming.headline)
    }

    @Test
    fun watchServiceStateLabelsCoverAllStates() {
        for (raw in 0..8) {
            assertTrue(watchServiceStateLabel(raw).isNotBlank())
        }
        assertEquals("Not connected", watchServiceStateLabel(null))
    }

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
    fun powerSaveGapIsExplainedCalmly() {
        val text = gapDescription(
            GapMeta(
                firstMissingSequence = 1u,
                missingFrameCount = 50u,
                firstMissingSampleIndex = 320uL,
                origin = GapMeta.ORIGIN_WATCH,
                reasonRaw = GapReason.PowerSave.raw,
            ),
        )
        assertEquals("watch was saving power", text)
    }

    @Test
    fun silenceSuppressedGapIsExplainedAsQuietAudio() {
        val text = gapDescription(
            GapMeta(
                firstMissingSequence = 1u,
                missingFrameCount = 50u,
                firstMissingSampleIndex = 320uL,
                origin = GapMeta.ORIGIN_WATCH,
                reasonRaw = GapReason.SilenceSuppressed.raw,
            ),
        )
        assertEquals("quiet audio was skipped", text)
    }

    @Test
    fun gapSummaryIgnoresSuppressedSilence() {
        // A segment whose only "gaps" are voice-activity silence has nothing wrong: no
        // "interrupted" summary, and no time counted as missing.
        val quiet = meta(
            "seg-quiet",
            0L,
            gaps = List(3) { index ->
                GapMeta(
                    firstMissingSequence = (index * 100 + 1).toUInt(),
                    missingFrameCount = 5_000u,
                    firstMissingSampleIndex = (index * 100 + 1).toULong() * 320u,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.SilenceSuppressed.raw,
                )
            },
        )
        assertEquals(0L, totalGapMs(quiet))
        assertEquals(null, gapSummary(quiet))
    }

    @Test
    fun gapSummaryReportsOnlyGenuineLossAlongsideSilence() {
        // Mixed: one real loss (mic conflict) plus skipped silence. The summary speaks only to
        // the loss; the silence adds neither time nor a second reason.
        val mixed = meta(
            "seg-mixed",
            0L,
            gaps = listOf(
                GapMeta(
                    firstMissingSequence = 1u,
                    missingFrameCount = 100u, // 2 s
                    firstMissingSampleIndex = 320uL,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.MicConflict.raw,
                ),
                GapMeta(
                    firstMissingSequence = 200u,
                    missingFrameCount = 5_000u,
                    firstMissingSampleIndex = 200uL * 320u,
                    origin = GapMeta.ORIGIN_WATCH,
                    reasonRaw = GapReason.SilenceSuppressed.raw,
                ),
            ),
        )
        assertEquals(2_000L, totalGapMs(mixed))
        val summary = gapSummary(mixed)
        assertTrue(summary != null && summary.contains("dictation"), "summary: $summary")
        assertTrue(summary.contains("2 sec"), "summary: $summary")
    }

    @Test
    fun duplicateSequenceSkipCoveredBySuppressedSilenceIsQuiet() {
        val quiet = GapMeta(
            firstMissingSequence = 100u,
            missingFrameCount = 5_000u,
            firstMissingSampleIndex = 100uL * 320u,
            origin = GapMeta.ORIGIN_WATCH,
            reasonRaw = GapReason.SilenceSuppressed.raw,
        )
        val duplicateSkip = GapMeta(
            firstMissingSequence = 100u,
            missingFrameCount = 5_000u,
            firstMissingSampleIndex = 100uL * 320u,
            origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
        )
        val segment = meta("seg-duplicate-quiet", 0L, gaps = listOf(quiet, duplicateSkip))

        assertEquals(0L, totalGapMs(segment))
        assertEquals(null, gapSummary(segment))
        assertEquals(2, quietGaps(segment).size)
        assertTrue(visibleLossGaps(segment).isEmpty())
    }

    @Test
    fun visibleLossGapsMatchesBruteForceOnLargeInput() {
        // visibleLossGaps used to be O(gaps^2) (every gap rescanned the whole list), which froze
        // the Today timeline for ~12 s once segments accumulated thousands of gap records. The
        // O(n log n) rewrite must stay semantically identical to the old per-gap rescan. Build a
        // big, varied gap set and compare against a brute-force reference of the original rule.
        val rng = kotlin.random.Random(42)
        val gaps = List(2_000) {
            val start = rng.nextInt(0, 5_000).toUInt()
            val count = rng.nextInt(1, 500).toUInt()
            val roll = rng.nextInt(3)
            GapMeta(
                firstMissingSequence = start,
                missingFrameCount = count,
                firstMissingSampleIndex = start.toULong() * 320u,
                origin = if (roll == 0) GapMeta.ORIGIN_SEQUENCE_SKIP else GapMeta.ORIGIN_WATCH,
                reasonRaw = if (roll == 1) GapReason.SilenceSuppressed.raw else GapReason.MicConflict.raw,
            )
        }
        fun bruteForceVisible(all: List<GapMeta>): List<GapMeta> = all.filter { gap ->
            when {
                isSilenceGap(gap) -> false
                gap.origin != GapMeta.ORIGIN_SEQUENCE_SKIP -> true
                else -> {
                    val start = gap.firstMissingSequence
                    val end = start + gap.missingFrameCount
                    all.none { c ->
                        isSilenceGap(c) &&
                            c.firstMissingSequence <= start &&
                            c.firstMissingSequence + c.missingFrameCount >= end
                    }
                }
            }
        }
        val segment = meta("seg-large", 0L, gaps = gaps)
        assertEquals(bruteForceVisible(gaps), visibleLossGaps(segment))
    }

    @Test
    fun unrelatedSequenceSkipStillCountsAsMissing() {
        val quiet = GapMeta(
            firstMissingSequence = 100u,
            missingFrameCount = 5_000u,
            firstMissingSampleIndex = 100uL * 320u,
            origin = GapMeta.ORIGIN_WATCH,
            reasonRaw = GapReason.SilenceSuppressed.raw,
        )
        val realSkip = GapMeta(
            firstMissingSequence = 6_000u,
            missingFrameCount = 50u,
            firstMissingSampleIndex = 6_000uL * 320u,
            origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
        )
        val segment = meta("seg-real-skip", 0L, gaps = listOf(quiet, realSkip))

        assertEquals(1_000L, totalGapMs(segment))
        assertEquals(listOf(realSkip), visibleLossGaps(segment))
        assertTrue(gapSummary(segment)?.contains("phone briefly missed audio") == true)
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
    fun deniedDisabledOffersDeliberateRestart() {
        val status = statusUiModel(
            ReceiverSessionState.Denied(AuthStatus.DeniedDisabled.raw),
            AudioCompanionSettings(backgroundReceiverEnabled = true),
            AudioCompanionDiagnostics(),
        )
        assertEquals("Background audio is off on the watch", status.headline)
        assertEquals(PrimaryAction.Start, status.primaryAction)
    }

    @Test
    fun noProtocolVocabularyInHeadlines() {
        val states = listOf(
            ReceiverSessionState.Disconnected,
            ReceiverSessionState.ConnectionFailed("Peripheral disconnected"),
            ReceiverSessionState.Connecting,
            ReceiverSessionState.Authorizing,
            ReceiverSessionState.PendingConsent,
            ReceiverSessionState.PendingEnable,
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
    fun timelineShowsLast24HoursNewestFirstWithQuietGapSummariesAndOpenSegment() {
        val recent1 = meta("seg-1", nowMs - 3_600_000)
        val recent2 = meta(
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
        val almost24HoursOld = meta("seg-near-cutoff", nowMs - dayMs + 1_000)
        val staleOpen = meta("seg-open", nowMs - 2 * dayMs, open = true)
        val lastWeek = meta("seg-old", nowMs - 7 * dayMs)

        val timeline = buildTimeline(
            segments = listOf(recent1, lastWeek, recent2, almost24HoursOld, staleOpen),
            transcriptOf = { null },
            nowMs = nowMs,
        )

        val keys = timeline.map { it.key }
        assertEquals(listOf("seg-seg-2", "seg-seg-1", "seg-seg-near-cutoff", "seg-seg-open"), keys)
        // Gaps render inside the row as one calm summary line, not as separate warning rows.
        val withGap = timeline[0] as TimelineItem.Segment
        val summary = withGap.gapSummary
        assertTrue(summary != null && summary.contains("dictation"), "summary: $summary")
        assertTrue(summary.contains("2 sec"), "summary should carry ~duration: $summary")
        assertEquals(null, (timeline[1] as TimelineItem.Segment).gapSummary)
        assertEquals("Recording", (timeline[3] as TimelineItem.Segment).stateLabel)
    }

    @Test
    fun gapSummaryCapsImpossibleTotalsToSegmentDuration() {
        val withHugeGap = meta(
            "seg-gap",
            nowMs,
            gaps = listOf(
                GapMeta(
                    firstMissingSequence = 10u,
                    missingFrameCount = 10_000_000u,
                    firstMissingSampleIndex = 3_200uL,
                    origin = GapMeta.ORIGIN_SEQUENCE_SKIP,
                ),
            ),
        )

        assertEquals(10_000, displayGapMs(withHugeGap))
        assertEquals(
            "Audio was interrupted for about 10 sec (phone briefly missed audio)",
            gapSummary(withHugeGap),
        )
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
    fun segmentTitleUsesLivePreviewForOpenRecordingUntilFinalTranscriptExists() {
        val open = meta("seg-1", nowMs, open = true)

        assertEquals(
            "Please tell me if it's working",
            segmentTitle(open, null, liveText = "Please tell me if it's working"),
        )
        assertEquals(
            "Final transcript wins",
            segmentTitle(
                open,
                transcript("seg-1", "Final transcript wins"),
                liveText = "newer preview",
            ),
        )
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
