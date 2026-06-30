package dev.audiocompanion.app

import dev.audiocompanion.transcription.CloudConnectivityResult
import dev.audiocompanion.transcription.StreamingTranscriptUpdate
import dev.audiocompanion.transcription.StreamingTranscriptionProvider
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private class FakeStreamingProvider : StreamingTranscriptionProvider {
    override val id = "fake-cloud"
    var available = true
    val updates = MutableSharedFlow<StreamingTranscriptUpdate>(extraBufferCapacity = 1)

    override suspend fun isAvailable(): Boolean = available

    override fun transcribeStream(
        pcm: Flow<ByteArray>,
        sampleRateHz: Int,
    ): Flow<StreamingTranscriptUpdate> = flow {
        updates.collect {
            emit(it)
        }
    }
}

/** Fails its first [failuresBeforeSuccess] streams (simulating transient Soniox socket errors). */
private class FlakyStreamingProvider(private val failuresBeforeSuccess: Int) : StreamingTranscriptionProvider {
    override val id = "flaky-cloud"
    var streamStarts = 0
        private set
    val updates = MutableSharedFlow<StreamingTranscriptUpdate>(extraBufferCapacity = 1)

    override suspend fun isAvailable(): Boolean = true

    override fun transcribeStream(
        pcm: Flow<ByteArray>,
        sampleRateHz: Int,
    ): Flow<StreamingTranscriptUpdate> = flow {
        val attempt = streamStarts++
        if (attempt < failuresBeforeSuccess) throw RuntimeException("Soniox realtime error: Request timeout")
        updates.collect { emit(it) }
    }
}

private fun cloudFrames(count: Int, firstSequence: UInt = 0u): List<SegmentFrame> =
    List(count) { index ->
        val sequence = firstSequence + index.toUInt()
        SegmentFrame(
            sequence = sequence,
            sampleIndex = sequence.toULong() * 320u,
            payload = ByteArray(25) { 1 },
        )
    }

class CloudLiveTranscriberTest {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun streamingPreviewCarriesTranscribedFrameAndSampleBoundary() = runTest {
        val tap = LiveAudioTap()
        val provider = FakeStreamingProvider()
        val transcriber = CloudLiveTranscriber(
            tap = tap,
            provider = provider,
            enabled = { true },
            nowMs = { 123_000 },
            decodePcm = { _, encoded -> encoded },
        )
        val tapJob = transcriber.start(this)
        advanceUntilIdle()

        tap.emit(
            LiveAudioEvent.SegmentOpened(
                segmentId = "seg-1",
                sampleRateHz = 16_000,
                bitRateBps = 9_800,
                frameSamples = 320,
            ),
        )
        advanceUntilIdle()
        tap.emit(LiveAudioEvent.FramesAppended("seg-1", cloudFrames(3, firstSequence = 10u)))
        assertTrue(provider.updates.tryEmit(StreamingTranscriptUpdate(finalText = "streaming words")))
        advanceUntilIdle()

        val preview = transcriber.previews.value["seg-1"]
        assertEquals("streaming words", preview?.text)
        assertEquals(3, preview?.transcribedFrameCount)
        assertEquals(13uL * 320uL, preview?.lastSampleIndexExclusive)
        assertEquals("fake-cloud", preview?.providerId)

        tap.emit(LiveAudioEvent.SegmentClosed("seg-1"))
        transcriber.setForeground(false)
        advanceUntilIdle()
        tapJob.cancelAndJoin()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun backgroundingDoesNotStopCloudStreamingProgress() = runTest {
        val tap = LiveAudioTap()
        val provider = FakeStreamingProvider()
        val transcriber = CloudLiveTranscriber(
            tap = tap,
            provider = provider,
            enabled = { true },
            nowMs = { 123_000 },
            decodePcm = { _, encoded -> encoded },
        )
        val tapJob = transcriber.start(this)
        advanceUntilIdle()

        tap.emit(
            LiveAudioEvent.SegmentOpened(
                segmentId = "seg-1",
                sampleRateHz = 16_000,
                bitRateBps = 9_800,
                frameSamples = 320,
            ),
        )
        advanceUntilIdle()
        tap.emit(LiveAudioEvent.FramesAppended("seg-1", cloudFrames(3, firstSequence = 10u)))
        assertTrue(provider.updates.tryEmit(StreamingTranscriptUpdate(finalText = "before background")))
        advanceUntilIdle()

        transcriber.setForeground(false)
        tap.emit(LiveAudioEvent.FramesAppended("seg-1", cloudFrames(2, firstSequence = 13u)))
        assertTrue(provider.updates.tryEmit(StreamingTranscriptUpdate(finalText = "after background")))
        advanceUntilIdle()

        val preview = transcriber.previews.value["seg-1"]
        assertEquals("after background", preview?.text)
        assertEquals(5, preview?.transcribedFrameCount)
        assertEquals(15uL * 320uL, preview?.lastSampleIndexExclusive)

        tap.emit(LiveAudioEvent.SegmentClosed("seg-1"))
        advanceUntilIdle()
        tapJob.cancelAndJoin()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun transientSocketFailureReconnectsAndKeepsTranscribing() = runTest {
        val tap = LiveAudioTap()
        val provider = FlakyStreamingProvider(failuresBeforeSuccess = 2)
        val outcomes = mutableListOf<CloudConnectivityResult>()
        val transcriber = CloudLiveTranscriber(
            tap = tap,
            provider = provider,
            enabled = { true },
            nowMs = { 123_000 },
            onOutcome = { outcomes += it },
            logFailure = { _, _ -> },
            decodePcm = { _, encoded -> encoded },
        )
        val tapJob = transcriber.start(this)
        advanceUntilIdle()

        tap.emit(
            LiveAudioEvent.SegmentOpened(
                segmentId = "seg-1",
                sampleRateHz = 16_000,
                bitRateBps = 9_800,
                frameSamples = 320,
            ),
        )
        advanceUntilIdle() // first two stream attempts fail; backoff elapses; third connects
        tap.emit(LiveAudioEvent.FramesAppended("seg-1", cloudFrames(3, firstSequence = 10u)))
        assertTrue(provider.updates.tryEmit(StreamingTranscriptUpdate(finalText = "recovered words")))
        advanceUntilIdle()

        assertEquals(3, provider.streamStarts) // 2 failures + 1 success
        assertEquals(2, outcomes.count { it is CloudConnectivityResult.Failed })
        assertTrue(outcomes.last() is CloudConnectivityResult.Ok)
        assertEquals("recovered words", transcriber.previews.value["seg-1"]?.text)

        tap.emit(LiveAudioEvent.SegmentClosed("seg-1"))
        advanceUntilIdle()
        tapJob.cancelAndJoin()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun givesUpAfterMaxReconnects() = runTest {
        val tap = LiveAudioTap()
        val provider = FlakyStreamingProvider(failuresBeforeSuccess = Int.MAX_VALUE)
        val outcomes = mutableListOf<CloudConnectivityResult>()
        val transcriber = CloudLiveTranscriber(
            tap = tap,
            provider = provider,
            enabled = { true },
            nowMs = { 123_000 },
            onOutcome = { outcomes += it },
            maxReconnects = 4,
            logFailure = { _, _ -> },
            decodePcm = { _, encoded -> encoded },
        )
        val tapJob = transcriber.start(this)
        advanceUntilIdle()

        tap.emit(
            LiveAudioEvent.SegmentOpened(
                segmentId = "seg-1",
                sampleRateHz = 16_000,
                bitRateBps = 9_800,
                frameSamples = 320,
            ),
        )
        advanceUntilIdle()

        assertEquals(5, provider.streamStarts) // initial attempt + 4 reconnects
        assertEquals(5, outcomes.count { it is CloudConnectivityResult.Failed })

        tap.emit(LiveAudioEvent.SegmentClosed("seg-1"))
        advanceUntilIdle()
        tapJob.cancelAndJoin()
    }
}
