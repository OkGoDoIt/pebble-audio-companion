package dev.audiocompanion.app

import dev.audiocompanion.storage.CloseReasonMeta
import dev.audiocompanion.storage.FrameRecord
import dev.audiocompanion.storage.SegmentMeta
import dev.audiocompanion.transcription.ProviderStatus
import dev.audiocompanion.transcription.TranscriptionException
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProvider
import dev.audiocompanion.transcription.TranscriptionResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class FakeProvider : TranscriptionProvider {
    override val id = "fake-local"
    override val status = MutableStateFlow(ProviderStatus.Ready)
    var available = true
    var nextError: Exception? = null
    val texts = ArrayDeque<String>()
    var transcribeCalls = 0

    override suspend fun isAvailable(): Boolean = available

    override suspend fun transcribe(
        pcmChunks: Flow<ByteArray>,
        sampleRateHz: Int,
    ): TranscriptionResult {
        transcribeCalls += 1
        pcmChunks.collect { } // drain like a real provider
        nextError?.let { nextError = null; throw it }
        return TranscriptionResult(
            text = texts.removeFirstOrNull() ?: "words",
            providerId = id,
            modelUsed = "fake-model",
        )
    }
}

private fun testMeta(segmentId: String, frameCount: Long, open: Boolean = true) = SegmentMeta(
    segmentId = segmentId,
    streamId = 7u,
    protocolVersion = 1,
    codecIdRaw = 1,
    channels = 1,
    frameSamples = 320,
    sampleRateHz = 16_000u,
    bitRateBps = 9_800u,
    frameDurationMs = 20,
    startTimeMs = 0u,
    startMonotonicMs = 0u,
    receivedAtMs = 1_000,
    frameCount = frameCount,
    closeReason = if (open) null else CloseReasonMeta.Interrupted,
)

private fun testFrames(count: Int): List<FrameRecord> = List(count) { index ->
    FrameRecord(
        sequence = index.toUInt(),
        sampleIndex = (index * 320).toULong(),
        payload = ByteArray(25),
    )
}

private class Harness(
    minChunkFrames: Int = 100,
    maxChunkFrames: Int = 500,
    failureBackoffMs: Long = 30_000,
) {
    val provider = FakeProvider()
    var openId: String? = "seg-1"
    var frameCount = 0L
    var nowMs = 1_000_000L
    var metaOpen = true

    val transcriber = LiveTranscriber(
        openSegmentId = { openId },
        readMeta = { id ->
            if (id == "seg-1" || id == "seg-2") testMeta(id, frameCount, metaOpen) else null
        },
        readFrames = { testFrames(frameCount.toInt()) },
        router = TranscriptionModeRouter(
            local = provider,
            remote = null,
            mode = { TranscriptionMode.LocalOnly },
        ),
        nowMs = { nowMs },
        decodePcm = { _, frames -> flowOf(ByteArray(frames.size * 2)) },
        minChunkFrames = minChunkFrames,
        maxChunkFrames = maxChunkFrames,
        failureBackoffMs = failureBackoffMs,
    )
}

class LiveTranscriberTest {

    @Test
    fun waitsForMinimumChunkBeforeTranscribing() = runTest {
        val h = Harness()
        h.frameCount = 99
        assertFalse(h.transcriber.processOnce())
        assertFalse(h.transcriber.hasPendingWork())
        assertNull(h.transcriber.textFor("seg-1"))
        assertEquals(0, h.provider.transcribeCalls)
    }

    @Test
    fun transcribesChunkAndAppendsAcrossPasses() = runTest {
        val h = Harness()
        h.provider.texts.addAll(listOf("hello there", "general kenobi"))

        h.frameCount = 150
        assertTrue(h.transcriber.hasPendingWork())
        assertTrue(h.transcriber.processOnce())
        assertEquals("hello there", h.transcriber.textFor("seg-1"))

        // Not enough new audio yet.
        assertFalse(h.transcriber.processOnce())

        h.frameCount = 260
        assertTrue(h.transcriber.processOnce())
        assertEquals("hello there general kenobi", h.transcriber.textFor("seg-1"))
        assertEquals(2, h.provider.transcribeCalls)
    }

    @Test
    fun boundsOnePassToMaxChunkFrames() = runTest {
        val h = Harness(minChunkFrames = 100, maxChunkFrames = 200)
        h.provider.texts.addAll(listOf("first", "second"))
        h.frameCount = 500

        assertTrue(h.transcriber.processOnce())
        assertEquals(200, h.transcriber.previews.value["seg-1"]?.transcribedFrameCount)
        // Backlog continues on the next pass.
        assertTrue(h.transcriber.processOnce())
        assertEquals("first second", h.transcriber.textFor("seg-1"))
    }

    @Test
    fun noSpeechAdvancesWithoutText() = runTest {
        val h = Harness()
        h.frameCount = 150
        h.provider.nextError = TranscriptionException.NoSpeechDetected("quiet")

        assertTrue(h.transcriber.processOnce())
        assertNull(h.transcriber.textFor("seg-1"))
        assertEquals(150, h.transcriber.previews.value["seg-1"]?.transcribedFrameCount)
    }

    @Test
    fun failureBacksOffThenRetries() = runTest {
        val h = Harness()
        h.frameCount = 150
        h.provider.nextError = TranscriptionException.TranscriptionFailed("boom")

        assertFalse(h.transcriber.processOnce())
        assertEquals(0, h.transcriber.previews.value["seg-1"]?.transcribedFrameCount ?: 0)

        // Still inside the backoff window: no provider call.
        h.nowMs += 1_000
        assertFalse(h.transcriber.processOnce())
        assertEquals(1, h.provider.transcribeCalls)

        h.nowMs += 60_000
        h.provider.texts.add("recovered")
        assertTrue(h.transcriber.processOnce())
        assertEquals("recovered", h.transcriber.textFor("seg-1"))
    }

    @Test
    fun unavailableRouterDoesNothing() = runTest {
        val h = Harness()
        h.frameCount = 150
        h.provider.available = false
        assertFalse(h.transcriber.processOnce())
        assertEquals(0, h.provider.transcribeCalls)
    }

    @Test
    fun pruneDropsFinalizedAndMissingSegments() = runTest {
        val h = Harness()
        h.provider.texts.add("preview")
        h.frameCount = 150
        assertTrue(h.transcriber.processOnce())

        // Final transcript exists now: the preview is superseded.
        h.transcriber.prune(hasFinalTranscript = { true })
        assertNull(h.transcriber.textFor("seg-1"))
    }

    @Test
    fun keepsPreviewOfJustClosedSegmentUntilFinalTranscript() = runTest {
        val h = Harness()
        h.provider.texts.add("ongoing words")
        h.frameCount = 150
        assertTrue(h.transcriber.processOnce())

        // Segment closed (rotation/stop); preview should survive pruning until the durable
        // transcript lands.
        h.openId = null
        h.metaOpen = false
        h.transcriber.prune(hasFinalTranscript = { false })
        assertEquals("ongoing words", h.transcriber.textFor("seg-1"))

        h.transcriber.prune(hasFinalTranscript = { true })
        assertNull(h.transcriber.textFor("seg-1"))
    }
}
