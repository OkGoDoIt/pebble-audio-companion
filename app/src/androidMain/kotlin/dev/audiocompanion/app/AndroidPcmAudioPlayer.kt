package dev.audiocompanion.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.PlaybackParams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * AudioTrack-backed PCM sink in streaming mode. The blocking [AudioTrack.write] provides the
 * pacing contract of [PcmAudioPlayer.write].
 */
class AndroidPcmAudioPlayer : PcmAudioPlayer {
    private var track: AudioTrack? = null
    private var speed: Float = 1f

    override fun start(sampleRateHz: Int) {
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRateHz,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val newTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRateHz)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBuffer, sampleRateHz / 2 * 2)) // >= 500 ms
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        newTrack.playbackParams = PlaybackParams().setSpeed(speed)
        newTrack.play()
        track = newTrack
    }

    override suspend fun write(pcm: ShortArray) {
        val current = track ?: return
        withContext(Dispatchers.IO) {
            var offset = 0
            while (offset < pcm.size) {
                val written = current.write(pcm, offset, pcm.size - offset)
                if (written <= 0) break
                offset += written
            }
        }
    }

    override fun setSpeed(speed: Float) {
        this.speed = speed
        runCatching { track?.playbackParams = PlaybackParams().setSpeed(speed) }
    }

    override fun stop() {
        track?.let { current ->
            runCatching {
                current.pause()
                current.flush()
                current.release()
            }
        }
        track = null
    }
}
