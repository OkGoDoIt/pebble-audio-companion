@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package dev.audiocompanion.app

import kotlinx.coroutines.channels.Channel
import kotlinx.cinterop.get
import kotlinx.cinterop.set
import platform.AVFAudio.AVAudioEngine
import platform.AVFAudio.AVAudioFormat
import platform.AVFAudio.AVAudioPCMBuffer
import platform.AVFAudio.AVAudioPlayerNode
import platform.AVFAudio.AVAudioSession
import platform.AVFAudio.AVAudioSessionCategoryPlayback
import platform.AVFAudio.AVAudioUnitTimePitch
import platform.AVFAudio.setActive

/**
 * AVAudioEngine-backed PCM sink: player node -> time pitch (speed control) -> main mixer.
 * Pacing comes from a bounded in-flight buffer count: [write] suspends until a previously
 * scheduled buffer completes, which bounds decode-ahead memory per the controller contract.
 */
class IosPcmAudioPlayer : PcmAudioPlayer {
    private var engine: AVAudioEngine? = null
    private var player: AVAudioPlayerNode? = null
    private var timePitch: AVAudioUnitTimePitch? = null
    private var format: AVAudioFormat? = null
    private val permits = Channel<Unit>(MAX_IN_FLIGHT)
    private var speed: Float = 1f

    override fun start(sampleRateHz: Int) {
        val session = AVAudioSession.sharedInstance()
        session.setCategory(AVAudioSessionCategoryPlayback, error = null)
        session.setActive(true, error = null)

        val newEngine = AVAudioEngine()
        val newPlayer = AVAudioPlayerNode()
        val newTimePitch = AVAudioUnitTimePitch()
        val newFormat = AVAudioFormat(standardFormatWithSampleRate = sampleRateHz.toDouble(), channels = 1u)

        newEngine.attachNode(newPlayer)
        newEngine.attachNode(newTimePitch)
        newEngine.connect(newPlayer, to = newTimePitch, format = newFormat)
        newEngine.connect(newTimePitch, to = newEngine.mainMixerNode, format = newFormat)
        newTimePitch.rate = speed

        newEngine.prepare()
        newEngine.startAndReturnError(null)
        newPlayer.play()

        engine = newEngine
        player = newPlayer
        timePitch = newTimePitch
        format = newFormat
        // Fill the permit pool.
        repeat(MAX_IN_FLIGHT) { permits.trySend(Unit) }
    }

    override suspend fun write(pcm: ShortArray) {
        val currentPlayer = player ?: return
        val currentFormat = format ?: return
        if (pcm.isEmpty()) return

        permits.receive() // wait until fewer than MAX_IN_FLIGHT buffers are queued

        val buffer = AVAudioPCMBuffer(pCMFormat = currentFormat, frameCapacity = pcm.size.toUInt())
        val channel = buffer.floatChannelData!![0]!!
        for (i in pcm.indices) {
            channel[i] = pcm[i] / 32768f
        }
        buffer.frameLength = pcm.size.toUInt()
        currentPlayer.scheduleBuffer(buffer) {
            permits.trySend(Unit)
        }
    }

    override fun setSpeed(speed: Float) {
        this.speed = speed
        timePitch?.rate = speed
    }

    override fun stop() {
        player?.stop()
        engine?.stop()
        player = null
        timePitch = null
        engine = null
        format = null
        // Drain stale permits so a restarted player begins from a full pool.
        while (permits.tryReceive().isSuccess) Unit
    }

    companion object {
        /** 3 x 500 ms batches in flight keeps memory bounded and audio gap-free. */
        private const val MAX_IN_FLIGHT = 3
    }
}
