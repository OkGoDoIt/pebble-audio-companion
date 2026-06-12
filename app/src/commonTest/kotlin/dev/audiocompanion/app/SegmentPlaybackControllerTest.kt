package dev.audiocompanion.app

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SegmentPlaybackControllerTest {
    @Test
    fun playDecodesAndWritesInBoundedBatches() = runTest {
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val player = FakePlayer(
            onWrite = { index ->
                if (index == 0) {
                    firstWriteStarted.complete(Unit)
                    releaseFirstWrite.await()
                }
            },
        )
        val decoder = FakeDecoder()
        val controller = SegmentPlaybackController(
            playerFactory = { player },
            decoder = decoder,
            frameSource = { segmentId ->
                check(segmentId == "seg-1")
                List(30) { byteArrayOf(it.toByte()) }
            },
        )

        controller.play("seg-1")
        firstWriteStarted.await()

        assertTrue(controller.state.value.playing)
        assertEquals("seg-1", controller.state.value.segmentId)
        assertEquals(600, controller.state.value.durationMs)
        assertEquals(listOf(25), decoder.batchSizes)

        releaseFirstWrite.complete(Unit)
        eventually { assertFalse(controller.state.value.playing) }

        assertEquals(listOf(25, 5), decoder.batchSizes)
        assertEquals(listOf(25, 5), player.writeSizes)
        assertEquals(0, controller.state.value.positionMs)
        assertTrue(player.stopped)
    }

    @Test
    fun seekAndSpeedUpdateStateAndPlayer() = runTest {
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val player = FakePlayer(
            onWrite = { index ->
                if (index == 0) {
                    firstWriteStarted.complete(Unit)
                    releaseFirstWrite.await()
                }
            },
        )
        val controller = SegmentPlaybackController(
            playerFactory = { player },
            decoder = FakeDecoder(),
            frameSource = { List(50) { byteArrayOf(1) } },
        )

        controller.seekTo("seg-2", 260)
        assertEquals(260, controller.state.value.positionMs)

        controller.play("seg-2")
        firstWriteStarted.await()
        controller.seekTo("seg-2", 800)
        controller.cycleSpeed()

        assertEquals(1.5f, controller.state.value.speed)
        assertEquals(1.5f, player.playbackSpeed)

        releaseFirstWrite.complete(Unit)
        eventually { assertFalse(controller.state.value.playing) }
    }

    private class FakeDecoder : LiveFrameDecoder {
        val batchSizes = mutableListOf<Int>()

        override suspend fun decode(frames: List<ByteArray>): ShortArray {
            batchSizes += frames.size
            return ShortArray(frames.size) { frames[it][0].toInt().toShort() }
        }
    }

    private class FakePlayer(
        private val onWrite: suspend (Int) -> Unit = {},
    ) : PcmAudioPlayer {
        val writeSizes = mutableListOf<Int>()
        var playbackSpeed = 1f
        var stopped = false

        override fun start(sampleRateHz: Int) {
            stopped = false
        }

        override suspend fun write(pcm: ShortArray) {
            val index = writeSizes.size
            writeSizes += pcm.size
            onWrite(index)
        }

        override fun setSpeed(speed: Float) {
            this.playbackSpeed = speed
        }

        override fun stop() {
            stopped = true
        }
    }

    private suspend fun eventually(assertion: () -> Unit) {
        repeat(50) {
            runCatching {
                assertion()
                return
            }
            delay(20)
        }
        assertion()
    }
}
