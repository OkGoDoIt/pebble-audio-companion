package dev.audiocompanion.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.concurrent.Volatile
import kotlin.math.min

/**
 * Platform PCM playback sink: 16 kHz mono signed 16-bit. [write] provides pacing — it must not
 * return until the device can accept more audio, which is what bounds decode-ahead memory.
 */
interface PcmAudioPlayer {
    fun start(sampleRateHz: Int)
    suspend fun write(pcm: ShortArray)
    fun setSpeed(speed: Float)
    fun stop()
}

data class PlaybackUiState(
    val segmentId: String? = null,
    val playing: Boolean = false,
    /** Media position within the stored audio (gaps excluded), not wall time. */
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val speed: Float = 1f,
)

/**
 * Segment playback with scrubbing and speed control (MVP requirement; ux plan Section 9).
 *
 * Decode is chunked — [BATCH_FRAMES] encoded frames at a time — never the whole segment in
 * memory. Seeking is frame-accurate because the firmware resets the Speex bitstream per frame,
 * so any frame is independently decodable.
 */
class SegmentPlaybackController(
    private val playerFactory: () -> PcmAudioPlayer,
    private val decoder: LiveFrameDecoder?,
    /** Encoded frame payloads of a segment, in order (from the durable frame log). */
    private val frameSource: (segmentId: String) -> List<ByteArray>,
    private val frameDurationMs: Long = 20,
    private val sampleRateHz: Int = 16_000,
) {
    private val _state = MutableStateFlow(PlaybackUiState())
    val state: StateFlow<PlaybackUiState> = _state.asStateFlow()

    private var scope: CoroutineScope? = null

    @Volatile
    private var seekFrameRequest: Int = -1

    /** Starts (or resumes) playback of [segmentId] from the current position. */
    fun play(segmentId: String) {
        val current = _state.value
        val startMs = if (current.segmentId == segmentId) current.positionMs else 0L
        startLoop(segmentId, startMs)
    }

    fun pause() {
        stopLoop()
        _state.value = _state.value.copy(playing = false)
    }

    fun stop() {
        stopLoop()
        _state.value = PlaybackUiState(speed = _state.value.speed)
    }

    fun seekTo(segmentId: String, positionMs: Long) {
        val frame = (positionMs / frameDurationMs).toInt().coerceAtLeast(0)
        if (_state.value.playing && _state.value.segmentId == segmentId) {
            seekFrameRequest = frame
        } else {
            _state.value = _state.value.copy(
                segmentId = segmentId,
                positionMs = frame * frameDurationMs,
            )
        }
    }

    fun cycleSpeed() {
        val next = when (_state.value.speed) {
            1f -> 1.5f
            1.5f -> 2f
            else -> 1f
        }
        _state.value = _state.value.copy(speed = next)
        currentPlayer?.setSpeed(next)
    }

    @Volatile
    private var currentPlayer: PcmAudioPlayer? = null

    private fun startLoop(segmentId: String, startMs: Long) {
        stopLoop()
        val frames = frameSource(segmentId)
        val durationMs = frames.size * frameDurationMs
        if (frames.isEmpty() || decoder == null) {
            _state.value = _state.value.copy(
                segmentId = segmentId,
                playing = false,
                durationMs = durationMs,
            )
            return
        }
        val startFrame = (startMs / frameDurationMs).toInt().coerceIn(0, frames.size - 1)
        _state.value = _state.value.copy(
            segmentId = segmentId,
            playing = true,
            positionMs = startFrame * frameDurationMs,
            durationMs = durationMs,
        )
        seekFrameRequest = -1
        val loopScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = loopScope
        loopScope.launch {
            val player = playerFactory()
            currentPlayer = player
            player.start(sampleRateHz)
            player.setSpeed(_state.value.speed)
            var completed = false
            try {
                var index = startFrame
                while (index < frames.size) {
                    val requested = seekFrameRequest
                    if (requested >= 0) {
                        seekFrameRequest = -1
                        index = requested.coerceIn(0, frames.size - 1)
                    }
                    val end = min(index + BATCH_FRAMES, frames.size)
                    val pcm = decoder.decode(frames.subList(index, end))
                    player.write(pcm)
                    index = end
                    _state.value = _state.value.copy(positionMs = index * frameDurationMs)
                }
                completed = true
            } finally {
                currentPlayer = null
                player.stop()
                _state.value = _state.value.copy(
                    playing = false,
                    positionMs = if (completed) 0 else _state.value.positionMs,
                )
            }
        }
    }

    private fun stopLoop() {
        scope?.cancel()
        scope = null
        currentPlayer?.stop()
        currentPlayer = null
    }

    companion object {
        /** 25 frames = 500 ms of audio decoded per batch. */
        const val BATCH_FRAMES = 25
    }
}
