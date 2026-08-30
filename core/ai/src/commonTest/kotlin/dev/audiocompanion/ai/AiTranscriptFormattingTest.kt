package dev.audiocompanion.ai

import kotlin.test.Test
import kotlin.test.assertTrue

class AiTranscriptFormattingTest {
    private fun request(excerpt: TranscriptExcerpt) = AiRunRequest(
        requestId = "req-1",
        prompt = AiPromptTemplates.DailySummary,
        transcripts = listOf(excerpt),
    )

    @Test
    fun prefersHumanReadableTimeLabelOverEpochMs() {
        val content = AiTranscriptFormatting.buildUserContent(
            request(
                TranscriptExcerpt(
                    segmentId = "seg-1",
                    text = "Hello.",
                    startTimeMs = 1_756_500_000_000,
                    timeLabel = "2026-08-29 21:35",
                ),
            ),
            maxInputChars = 10_000,
        )
        assertTrue("--- Transcript segment seg-1 (starts 2026-08-29 21:35) ---" in content)
    }

    @Test
    fun fallsBackToEpochMsWithoutTimeLabel() {
        val content = AiTranscriptFormatting.buildUserContent(
            request(
                TranscriptExcerpt(
                    segmentId = "seg-1",
                    text = "Hello.",
                    startTimeMs = 42,
                ),
            ),
            maxInputChars = 10_000,
        )
        assertTrue("--- Transcript segment seg-1 (starts at epoch ms 42) ---" in content)
    }
}
