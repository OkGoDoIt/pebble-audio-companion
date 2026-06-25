package dev.audiocompanion.app

import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.StreamingTranscriptionProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/** Events teed off the receive path so a live cloud transcriber can stream the open segment. */
sealed interface LiveAudioEvent {
    data class SegmentOpened(
        val segmentId: String,
        val sampleRateHz: Int,
        val bitRateBps: Int,
        val frameSamples: Int,
    ) : LiveAudioEvent

    data class FramesAppended(val segmentId: String, val payloads: List<ByteArray>) : LiveAudioEvent
    data class SegmentClosed(val segmentId: String) : LiveAudioEvent
}

/** Cheap fan-out of live audio events from the receive path (no decode on the receive path). */
class LiveAudioTap {
    private val _events = MutableSharedFlow<LiveAudioEvent>(
        extraBufferCapacity = 512,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val events: SharedFlow<LiveAudioEvent> = _events.asSharedFlow()
    fun emit(event: LiveAudioEvent) {
        _events.tryEmit(event)
    }
}

/**
 * Real-time cloud transcription of the currently-open segment (plan: "real-time streaming of live
 * audio"). It decodes the live frame tap into PCM, streams it to a [StreamingTranscriptionProvider]
 * (e.g. Soniox realtime), and publishes a rolling [LiveTranscriptPreview] — the same preview surface
 * the local chunk-based transcriber uses, so the UI need not care which produced it.
 *
 * Foreground-only and opt-in: a live socket cannot survive iOS suspension, so [setForeground] stops
 * sessions in the background, and nothing runs unless [enabled] is true. The local live preview is
 * untouched when this is off.
 */
class CloudLiveTranscriber(
    private val tap: LiveAudioTap,
    private val provider: StreamingTranscriptionProvider,
    private val enabled: () -> Boolean,
    private val nowMs: () -> Long,
) {
    private val _previews = MutableStateFlow<Map<String, LiveTranscriptPreview>>(emptyMap())
    val previews: StateFlow<Map<String, LiveTranscriptPreview>> = _previews.asStateFlow()

    private var foreground = true
    private var sessionScope: CoroutineScope? = null
    private var activeSegmentId: String? = null
    private var frameChannel: Channel<ByteArray>? = null
    private var sessionJob: Job? = null

    fun start(scope: CoroutineScope): Job {
        sessionScope = scope
        return scope.launch {
            tap.events.collect { handle(it) }
        }
    }

    /** Receiving keeps going in the background, but streaming cannot — stop live sessions there. */
    fun setForeground(value: Boolean) {
        foreground = value
        if (!value) stopSession()
    }

    private suspend fun handle(event: LiveAudioEvent) {
        when (event) {
            is LiveAudioEvent.SegmentOpened -> onOpened(event)
            is LiveAudioEvent.FramesAppended ->
                if (event.segmentId == activeSegmentId) {
                    event.payloads.forEach { frameChannel?.trySend(it) }
                }
            is LiveAudioEvent.SegmentClosed ->
                if (event.segmentId == activeSegmentId) stopSession()
        }
    }

    private fun onOpened(event: LiveAudioEvent.SegmentOpened) {
        if (!foreground || !enabled()) return
        val scope = sessionScope ?: return
        stopSession()
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        activeSegmentId = event.segmentId
        frameChannel = channel
        sessionJob = scope.launch {
            try {
                streamSession(event, channel)
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                logBackgroundFailure("cloud live transcription", t)
            }
        }
    }

    private suspend fun streamSession(
        event: LiveAudioEvent.SegmentOpened,
        channel: Channel<ByteArray>,
    ) {
        if (!provider.isAvailable()) return
        val decoder = SpeexFrameDecoder(
            sampleRateHz = event.sampleRateHz,
            bitRateBps = event.bitRateBps,
            frameSamples = event.frameSamples,
        )
        val pcm = decoder.decode(channel.receiveAsFlow())
        provider.transcribeStream(pcm, event.sampleRateHz).collect { update ->
            _previews.value = _previews.value + (
                event.segmentId to LiveTranscriptPreview(
                    segmentId = event.segmentId,
                    text = update.displayText,
                    segments = update.segments,
                    transcribedFrameCount = 0,
                    lastSampleIndexExclusive = 0u,
                    updatedAtMs = nowMs(),
                )
                )
        }
    }

    private fun stopSession() {
        frameChannel?.close()
        frameChannel = null
        sessionJob?.cancel()
        sessionJob = null
        activeSegmentId = null
    }

    /** Drops a segment's live preview once its durable transcript supersedes it. */
    fun prune(hasDurableTranscript: (String) -> Boolean) {
        _previews.value = _previews.value.filterKeys { it == activeSegmentId || !hasDurableTranscript(it) }
    }
}
