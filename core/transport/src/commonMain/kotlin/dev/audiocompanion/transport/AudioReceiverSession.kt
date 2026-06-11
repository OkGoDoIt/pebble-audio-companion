package dev.audiocompanion.transport

import dev.audiocompanion.protocol.Ack
import dev.audiocompanion.protocol.AudioCompanionProtocol
import dev.audiocompanion.protocol.AuthRequest
import dev.audiocompanion.protocol.AuthResult
import dev.audiocompanion.protocol.AuthStatus
import dev.audiocompanion.protocol.Checkpoint
import dev.audiocompanion.protocol.ControlOutMessage
import dev.audiocompanion.protocol.DataMessage
import dev.audiocompanion.protocol.DecodeResult
import dev.audiocompanion.protocol.ErrorMessage
import dev.audiocompanion.protocol.InfoSnapshot
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.Revoked
import dev.audiocompanion.protocol.StateChanged
import dev.audiocompanion.protocol.StreamData
import dev.audiocompanion.protocol.StreamGap
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.protocol.StreamStop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Receiver/session state exposed to the UI layer. */
sealed interface ReceiverSessionState {
    data object Disconnected : ReceiverSessionState
    data object Connecting : ReceiverSessionState

    /** Link ready; reading Info and sending AUTH_REQUEST. */
    data object Authorizing : ReceiverSessionState

    /** Watch returned pending-user-consent; waiting for the user to accept on the watch. */
    data object PendingConsent : ReceiverSessionState

    data class Denied(val statusRaw: Int) : ReceiverSessionState {
        val status: AuthStatus? get() = AuthStatus.fromRaw(statusRaw)
    }

    /** Authorized on this connection, no stream currently open. */
    data object Authorized : ReceiverSessionState

    data class Streaming(val streamId: UInt) : ReceiverSessionState

    data class Revoked(val reasonRaw: Int) : ReceiverSessionState
}

/** Static configuration for a receiver install. */
class ReceiverConfig(
    /** 32 random bytes generated once per app install (spec Section 6). */
    val receiverId: ByteArray,
    val receiverName: String,
    val protoVersion: Int = ProtocolConstants.PROTOCOL_VERSION,
    /** Send a checkpoint once this much appended audio has accumulated. */
    val checkpointAudioMs: Long = 2_000,
    /** ... or once this much wall time has passed since the last send (and new data exists). */
    val checkpointMinIntervalMs: Long = 500,
) {
    init {
        require(receiverId.size == ProtocolConstants.RECEIVER_ID_BYTES)
    }
}

/**
 * One receiver session per BLE connection (implementation plan Section 6.2).
 *
 * On link Ready: read Info, send AUTH_REQUEST; on AUTH_RESULT(ok) consume data notifications,
 * appending frames durably via [SegmentSink] before any bookkeeping, synthesizing gap records
 * on sequence discontinuities, and checkpointing the highest *contiguous* persisted sequence.
 * On disconnect: close the open segment as interrupted and persist resume state.
 *
 * Pure KMP: no platform imports; time is injected via [nowMs] so tests can run on virtual time.
 */
class AudioReceiverSession(
    private val link: AudioGattLink,
    private val sink: SegmentSink,
    private val policy: ReceiverPolicy,
    private val resumeStore: ReceiverResumeStore,
    private val config: ReceiverConfig,
    private val nowMs: () -> Long,
) {
    private val _state = MutableStateFlow<ReceiverSessionState>(ReceiverSessionState.Disconnected)
    val state: StateFlow<ReceiverSessionState> = _state.asStateFlow()

    private val _watchInfo = MutableStateFlow<InfoSnapshot?>(null)
    val watchInfo: StateFlow<InfoSnapshot?> = _watchInfo.asStateFlow()

    private val _watchServiceState = MutableStateFlow<Int?>(null)
    val watchServiceState: StateFlow<Int?> = _watchServiceState.asStateFlow()

    private val _lastProtocolError = MutableStateFlow<ErrorMessage?>(null)
    val lastProtocolError: StateFlow<ErrorMessage?> = _lastProtocolError.asStateFlow()

    private val _grantedProtoVersion = MutableStateFlow<Int?>(null)
    val grantedProtoVersion: StateFlow<Int?> = _grantedProtoVersion.asStateFlow()

    // --- one-in-flight control request bookkeeping -------------------------------------------
    private var tokenCounter = 0
    private var inFlightToken: Int? = null

    private fun takeToken(): Int? {
        if (inFlightToken != null) return null
        tokenCounter = (tokenCounter + 1) and 0xFF
        inFlightToken = tokenCounter
        return tokenCounter
    }

    // --- per-connection state ------------------------------------------------------------------
    private var authorized = false
    private var dataJob: Job? = null
    private var stream: StreamContext? = null

    /**
     * Sequence/contiguity tracker for the open stream.
     *
     * [contiguousNext] is the lowest sequence not yet accounted for; everything below it is
     * either durably persisted or covered by a watch-reported gap (known-lost). Frames persisted
     * beyond an unaccounted hole sit in [pendingRanges] and do not advance the checkpoint:
     * CHECKPOINT carries the highest *contiguous* persisted sequence, not the highest seen.
     */
    private class StreamContext(val start: StreamStart, nowMs: Long) {
        val streamId: UInt get() = start.streamId
        val frameSamples: ULong = start.frameSamples.toULong()
        val sampleRateHz: ULong = start.sampleRateHz.toULong()

        var contiguousNext: UInt = 0u
        var contiguousSampleIndex: ULong = 0u
        val pendingRanges = mutableListOf<PersistedRange>()

        /** First missing sequence of a watch-reported gap whose extent is still unknown. */
        var openWatchGapFrom: UInt? = null

        var samplesSinceCheckpoint: ULong = 0u
        var lastCheckpointAtMs: Long = nowMs
        var checkpointedSinceLastChange = true

        class PersistedRange(val first: UInt, val endExclusive: UInt, val endSampleIndex: ULong)

        fun mergePendingRanges() {
            while (true) {
                val next = pendingRanges.firstOrNull { it.first == contiguousNext } ?: return
                contiguousNext = next.endExclusive
                contiguousSampleIndex = next.endSampleIndex
                pendingRanges.remove(next)
            }
        }
    }

    fun start(scope: CoroutineScope): Job = scope.launch { run() }

    suspend fun run() {
        try {
            link.connectionState.collectLatest { linkState ->
                when (linkState) {
                    LinkState.Disconnected -> {
                        onLinkDown()
                        _state.value = ReceiverSessionState.Disconnected
                    }
                    LinkState.Connecting -> {
                        onLinkDown()
                        _state.value = ReceiverSessionState.Connecting
                    }
                    LinkState.Ready -> runConnection()
                }
            }
        } finally {
            withContext(NonCancellable) { onLinkDown() }
        }
    }

    private suspend fun runConnection() {
        try {
            coroutineScope {
                _state.value = ReceiverSessionState.Authorizing

                when (val info = AudioCompanionProtocol.decodeInfo(link.readInfo())) {
                    is DecodeResult.Decoded -> {
                        val snapshot = info.message as InfoSnapshot
                        _watchInfo.value = snapshot
                        _watchServiceState.value = snapshot.serviceStateRaw
                    }
                    else -> {} // diagnostics only; auth decides whether we can proceed
                }

                val connectionScope = this
                launch {
                    link.controlNotifications.collect { bytes ->
                        when (val result = AudioCompanionProtocol.decodeControlOut(bytes)) {
                            is DecodeResult.Decoded ->
                                handleControl(result.message as ControlOutMessage, connectionScope)
                            else -> {} // unknown ids ignored per spec; malformed logged at most
                        }
                    }
                }

                val token = takeToken() ?: error("fresh connection must have no in-flight request")
                link.writeControl(
                    AuthRequest(
                        protoVersion = config.protoVersion,
                        requestToken = token,
                        receiverId = config.receiverId,
                        name = config.receiverName,
                    ).encode()
                )
            }
        } finally {
            // Link dropped (collectLatest cancelled us) or the connection scope failed.
            withContext(NonCancellable) { onLinkDown() }
        }
    }

    private suspend fun handleControl(message: ControlOutMessage, connectionScope: CoroutineScope) {
        when (message) {
            is AuthResult -> {
                if (message.requestToken != inFlightToken) return
                when (message.status) {
                    AuthStatus.Ok -> {
                        inFlightToken = null
                        authorized = true
                        _grantedProtoVersion.value = message.grantedProtoVersion
                        _state.value = ReceiverSessionState.Authorized
                        if (dataJob == null) {
                            dataJob = connectionScope.launch { consumeData() }
                        }
                    }
                    AuthStatus.PendingUserConsent -> {
                        // Token stays in flight: the watch pushes a second AUTH_RESULT with the
                        // same token once the consent prompt resolves.
                        _state.value = ReceiverSessionState.PendingConsent
                    }
                    else -> {
                        inFlightToken = null
                        authorized = false
                        _state.value = ReceiverSessionState.Denied(message.statusRaw)
                    }
                }
            }
            is Ack -> {
                if (message.requestToken == inFlightToken) inFlightToken = null
            }
            is Revoked -> {
                closeOpenSegment(SegmentCloseReason.Interrupted)
                authorized = false
                dataJob?.cancel()
                dataJob = null
                _state.value = ReceiverSessionState.Revoked(message.reasonRaw)
            }
            is StateChanged -> _watchServiceState.value = message.serviceStateRaw
            is ErrorMessage -> _lastProtocolError.value = message
            else -> {}
        }
    }

    private suspend fun consumeData() {
        link.dataNotifications.collect { bytes ->
            when (val result = AudioCompanionProtocol.decodeData(bytes)) {
                is DecodeResult.Decoded -> handleData(result.message as DataMessage)
                else -> {} // unknown ids ignored per spec
            }
        }
    }

    private suspend fun handleData(message: DataMessage) {
        if (!authorized) return
        when (message) {
            is StreamStart -> {
                closeOpenSegment(SegmentCloseReason.Superseded)
                sink.openSegment(
                    start = message,
                    receivedAtMs = nowMs(),
                    provenance = _watchInfo.value?.let {
                        SegmentProvenance(it.fwVersionPacked, message.protocolVersion)
                    },
                )
                stream = StreamContext(message, nowMs())
                _state.value = ReceiverSessionState.Streaming(message.streamId)
            }
            is StreamData -> handleStreamData(message)
            is StreamGap -> handleStreamGap(message)
            is StreamStop -> {
                val ctx = stream ?: return
                if (message.streamId != ctx.streamId) return
                closeOpenSegment(
                    SegmentCloseReason.Stopped(
                        reasonRaw = message.reasonRaw,
                        finalSequence = message.finalSequence,
                        finalSampleIndex = message.finalSampleIndex,
                    )
                )
                _state.value = ReceiverSessionState.Authorized
            }
            else -> {}
        }
    }

    private suspend fun handleStreamData(message: StreamData) {
        val ctx = stream ?: return // STREAM_DATA before STREAM_START: nothing to attach it to
        if (message.streamId != ctx.streamId) return

        val first = message.firstSequence
        val count = message.frameCount.toUInt()
        val endExclusive = first + count

        if (endExclusive <= ctx.contiguousNext) return // stale duplicate, already accounted

        // Durability first: frames hit the frame log before any bookkeeping or checkpointing.
        val frames = message.frames.mapIndexed { i, payload ->
            SegmentFrame(
                sequence = message.sequenceOf(i),
                sampleIndex = message.sampleIndexOf(i, ctx.start.frameSamples),
                payload = payload,
            )
        }
        sink.appendFrames(ctx.streamId, frames)

        if (first > ctx.contiguousNext) {
            val accountedByWatchGap =
                ctx.openWatchGapFrom?.let { it <= ctx.contiguousNext } == true
            if (accountedByWatchGap) {
                // The watch already reported this hole (unknown extent); now we know where it
                // ends. The lost range is accounted: contiguity resumes at this batch.
                ctx.openWatchGapFrom = null
                ctx.contiguousNext = first
                ctx.contiguousSampleIndex = message.firstSampleIndex
            } else {
                // Silent discontinuity: synthesize a gap record. Contiguity does NOT advance;
                // checkpoints keep reporting the last sequence before the hole.
                sink.recordGap(
                    ctx.streamId,
                    GapRecord(
                        firstMissingSequence = ctx.contiguousNext,
                        missingFrameCount = first - ctx.contiguousNext,
                        firstMissingSampleIndex = ctx.contiguousSampleIndex,
                        origin = GapOrigin.SequenceSkip,
                    ),
                )
            }
        }

        val endSampleIndex = message.firstSampleIndex + count.toULong() * ctx.frameSamples
        if (first <= ctx.contiguousNext) {
            ctx.contiguousNext = endExclusive
            ctx.contiguousSampleIndex = endSampleIndex
            ctx.mergePendingRanges()
        } else {
            ctx.pendingRanges.add(StreamContext.PersistedRange(first, endExclusive, endSampleIndex))
        }

        ctx.samplesSinceCheckpoint += count.toULong() * ctx.frameSamples
        ctx.checkpointedSinceLastChange = false
        maybeSendCheckpoint(ctx)
    }

    private suspend fun handleStreamGap(message: StreamGap) {
        val ctx = stream ?: return
        if (message.streamId != ctx.streamId) return

        sink.recordGap(
            ctx.streamId,
            GapRecord(
                firstMissingSequence = message.firstMissingSequence,
                missingFrameCount = message.missingFrameCount,
                firstMissingSampleIndex = message.firstMissingSampleIndex,
                origin = GapOrigin.WatchReported(message.reasonRaw, message.watchDropCounter),
            ),
        )

        if (message.missingFrameCount == 0u) {
            // Unknown extent: account for it when the next STREAM_DATA shows where it ends.
            ctx.openWatchGapFrom = message.firstMissingSequence
        } else if (message.firstMissingSequence <= ctx.contiguousNext) {
            // Known-lost range adjoining the contiguous prefix: those frames will never arrive,
            // so contiguity (and the checkpoint) advances past them.
            val gapEnd = message.firstMissingSequence + message.missingFrameCount
            if (gapEnd > ctx.contiguousNext) {
                ctx.contiguousSampleIndex +=
                    (gapEnd - ctx.contiguousNext).toULong() * ctx.frameSamples
                ctx.contiguousNext = gapEnd
                ctx.mergePendingRanges()
                ctx.checkpointedSinceLastChange = false
            }
        }
    }

    private suspend fun maybeSendCheckpoint(ctx: StreamContext) {
        if (ctx.contiguousNext == 0u) return // nothing contiguous persisted yet
        if (ctx.checkpointedSinceLastChange) return
        val audioMs = ctx.samplesSinceCheckpoint * 1000u / ctx.sampleRateHz
        val due = audioMs >= config.checkpointAudioMs.toULong() ||
            (nowMs() - ctx.lastCheckpointAtMs) >= config.checkpointMinIntervalMs
        if (!due) return
        val token = takeToken() ?: return // a request is in flight; retry on the next append
        link.writeControl(
            Checkpoint(
                requestToken = token,
                streamId = ctx.streamId,
                highestContiguousSequencePersisted = ctx.contiguousNext - 1u,
                persistedSampleIndex = ctx.contiguousSampleIndex,
                receiverFlags = policy.receiverFlags(),
                freeStorageHintKb = policy.freeStorageHintKb(),
            ).encode()
        )
        ctx.lastCheckpointAtMs = nowMs()
        ctx.samplesSinceCheckpoint = 0u
        ctx.checkpointedSinceLastChange = true
    }

    private suspend fun closeOpenSegment(reason: SegmentCloseReason) {
        val ctx = stream ?: return
        stream = null
        sink.closeSegment(reason)
        resumeStore.save(
            ReceiverResumeState(
                lastStreamId = ctx.streamId,
                lastContiguousSequence = if (ctx.contiguousNext > 0u) ctx.contiguousNext - 1u else null,
                lastSampleIndex = ctx.contiguousSampleIndex,
            )
        )
    }

    /** Connection teardown: close any open segment as interrupted and reset per-link state. */
    private suspend fun onLinkDown() {
        closeOpenSegment(SegmentCloseReason.Interrupted)
        authorized = false
        dataJob = null
        inFlightToken = null
        _grantedProtoVersion.value = null
    }
}
