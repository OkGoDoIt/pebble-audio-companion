package dev.audiocompanion.app

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
}
