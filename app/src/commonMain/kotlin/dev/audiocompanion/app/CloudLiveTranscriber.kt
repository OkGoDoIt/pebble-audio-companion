package dev.audiocompanion.app

import dev.audiocompanion.transcription.CloudConnectivityResult
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.StreamingTranscriptionProvider
import dev.audiocompanion.transport.SegmentFrame
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
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

    data class FramesAppended(val segmentId: String, val frames: List<SegmentFrame>) : LiveAudioEvent
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
 * Opt-in and lightweight enough to keep running when the app backgrounds. Local transcription still
 * pauses there to avoid resident-model memory pressure, but this path only decodes live frames and
 * streams them to the selected cloud provider.
 */
class CloudLiveTranscriber(
    private val tap: LiveAudioTap,
    private val provider: StreamingTranscriptionProvider,
    private val enabled: () -> Boolean,
    private val nowMs: () -> Long,
    /**
     * Reports live-streaming outcomes so cloud health is visible: [CloudConnectivityResult.Ok] once a
     * session produces an update, [CloudConnectivityResult.Failed] when the socket errors. Without
     * this, a failing live socket silently falls back to the local preview (as it did before the
     * Soniox audio_format fix).
     */
    private val onOutcome: (CloudConnectivityResult) -> Unit = {},
    private val decodePcm: (
        LiveAudioEvent.SegmentOpened,
        Flow<ByteArray>,
    ) -> Flow<ByteArray> = { event, encoded ->
        SpeexFrameDecoder(
            sampleRateHz = event.sampleRateHz,
            bitRateBps = event.bitRateBps,
            frameSamples = event.frameSamples,
        ).decode(encoded)
    },
) {
    private val _previews = MutableStateFlow<Map<String, LiveTranscriptPreview>>(emptyMap())
    val previews: StateFlow<Map<String, LiveTranscriptPreview>> = _previews.asStateFlow()

    private var sessionScope: CoroutineScope? = null
    private var currentOpenSegment: LiveAudioEvent.SegmentOpened? = null
    private var activeSegmentId: String? = null
    private var frameChannel: Channel<ByteArray>? = null
    private var sessionJob: Job? = null
    private var activeFrameSamples: Int = 320
    private var streamedFrameCount: Int = 0
    private var lastSampleIndexExclusive: ULong = 0u

    fun start(scope: CoroutineScope): Job {
        sessionScope = scope
        return scope.launch {
            tap.events.collect { handle(it) }
        }
    }

    /** Local transcription pauses in the background; cloud live streaming intentionally continues. */
    fun setForeground(value: Boolean) = Unit

    private suspend fun handle(event: LiveAudioEvent) {
        when (event) {
            is LiveAudioEvent.SegmentOpened -> onOpened(event)
            is LiveAudioEvent.FramesAppended -> {
                if (event.segmentId == currentOpenSegment?.segmentId && activeSegmentId != event.segmentId) {
                    currentOpenSegment?.let { maybeStartSession(it) }
                }
                if (event.segmentId == activeSegmentId) {
                    streamedFrameCount += event.frames.size
                    event.frames.lastOrNull()?.let { frame ->
                        lastSampleIndexExclusive =
                            frame.sampleIndex + activeFrameSamples.toULong()
                    }
                    event.frames.forEach { frameChannel?.trySend(it.payload) }
                }
            }
            is LiveAudioEvent.SegmentClosed -> {
                if (event.segmentId == currentOpenSegment?.segmentId) currentOpenSegment = null
                if (event.segmentId == activeSegmentId) stopSession()
            }
        }
    }

    private fun onOpened(event: LiveAudioEvent.SegmentOpened) {
        currentOpenSegment = event
        maybeStartSession(event)
    }

    private fun maybeStartSession(event: LiveAudioEvent.SegmentOpened) {
        if (!enabled()) return
        if (activeSegmentId == event.segmentId && frameChannel != null) return
        val scope = sessionScope ?: return
        stopSession()
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        activeSegmentId = event.segmentId
        activeFrameSamples = event.frameSamples
        streamedFrameCount = 0
        lastSampleIndexExclusive = 0u
        frameChannel = channel
        sessionJob = scope.launch {
            try {
                streamSession(event, channel)
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                onOutcome(
                    CloudConnectivityResult.Failed(
                        t.message ?: "Live cloud transcription failed.",
                    ),
                )
                logBackgroundFailure("cloud live transcription", t)
            }
        }
    }

    private suspend fun streamSession(
        event: LiveAudioEvent.SegmentOpened,
        channel: Channel<ByteArray>,
    ) {
        if (!provider.isAvailable()) return
        val pcm = decodePcm(event, channel.receiveAsFlow())
        var reportedOk = false
        provider.transcribeStream(pcm, event.sampleRateHz).collect { update ->
            if (!reportedOk) {
                onOutcome(CloudConnectivityResult.Ok())
                reportedOk = true
            }
            _previews.value = _previews.value + (
                event.segmentId to LiveTranscriptPreview(
                    segmentId = event.segmentId,
                    text = update.displayText,
                    segments = update.segments,
                    transcribedFrameCount = streamedFrameCount,
                    lastSampleIndexExclusive = lastSampleIndexExclusive,
                    updatedAtMs = nowMs(),
                    providerId = provider.id,
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
