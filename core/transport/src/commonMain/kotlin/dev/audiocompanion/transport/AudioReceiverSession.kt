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
import dev.audiocompanion.protocol.EnableRequest
import dev.audiocompanion.protocol.ErrorMessage
import dev.audiocompanion.protocol.InfoSnapshot
import dev.audiocompanion.protocol.PauseReason
import dev.audiocompanion.protocol.PauseRequest
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.ReceiverHealth
import dev.audiocompanion.protocol.ResumeRequest
import dev.audiocompanion.protocol.Revoked
import dev.audiocompanion.protocol.ServiceState
import dev.audiocompanion.protocol.StateChanged
import dev.audiocompanion.protocol.StreamData
import dev.audiocompanion.protocol.StreamGap
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.protocol.StreamStop
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.cancellation.CancellationException

/** Receiver/session state exposed to the UI layer. */
sealed interface ReceiverSessionState {
    data object Disconnected : ReceiverSessionState
    data object Connecting : ReceiverSessionState

    data class ConnectionFailed(val message: String) : ReceiverSessionState

    /** Link ready; reading Info and sending AUTH_REQUEST. */
    data object Authorizing : ReceiverSessionState

    /** Watch returned pending-user-consent; waiting for the user to accept on the watch. */
    data object PendingConsent : ReceiverSessionState

    /** Watch has Background Audio off; waiting for the user to allow enabling it on-watch. */
    data object PendingEnable : ReceiverSessionState

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
    /**
     * While authorized but not actively receiving, ping the watch this often (RECEIVER_HEALTH)
     * to keep its liveness watchdog armed and to revive a watch that already presumed us gone.
     * Also doubles as a stale-link probe: repeated unanswered pings force a full reconnect.
     */
    val keepaliveIntervalMs: Long = 5_000,
    /** Force a link resync after this many consecutive unanswered keepalive pings. */
    val keepaliveMaxFailures: Int = 2,
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
    /**
     * The user's current intent: true when they want the watch recording. Drives the
     * declarative reconcile after every (re)authorization, so restart is reliable regardless
     * of what state the watch happened to be in (defaults to "wants audio" for bare tests).
     */
    private val desiredEnabled: () -> Boolean = { true },
    /**
     * One-shot permission for asking the watch to enable Background Audio. Lifecycle reconnects
     * may still want recording, but they must not surprise the user with a watch prompt.
     */
    private val consumeEnableRequestPermission: () -> Boolean = { desiredEnabled() },
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
    private var ackWaiter: CompletableDeferred<Boolean>? = null

    private fun takeToken(): Int? {
        if (inFlightToken != null) return null
        tokenCounter = (tokenCounter + 1) and 0xFF
        inFlightToken = tokenCounter
        return tokenCounter
    }

    /**
     * Asks the watch to pause capture (maps to the watch's PausedPolicy state, visible in its
     * Settings). Returns true when the watch acknowledged. Safe to call from any scope; waits
     * briefly for an in-flight checkpoint to clear.
     */
    suspend fun requestPause(reasonRaw: Int = PauseReason.User.raw): Boolean =
        sendControlAwaitAck { token -> PauseRequest(token, reasonRaw).encode() }

    /** Asks the watch to resume capture after [requestPause]. True when acknowledged. */
    suspend fun requestResume(): Boolean =
        sendControlAwaitAck { token -> ResumeRequest(token).encode() }

    private suspend fun sendControlAwaitAck(
        requireAuthorized: Boolean = true,
        ackWaitMs: Long = REQUEST_ACK_WAIT_MS,
        build: (Int) -> ByteArray,
    ): Boolean {
        if (requireAuthorized && !authorized) return false
        val token = withTimeoutOrNull(REQUEST_TOKEN_WAIT_MS) {
            var taken = takeToken()
            while (taken == null) {
                delay(50)
                taken = takeToken()
            }
            taken
        } ?: return false
        val waiter = CompletableDeferred<Boolean>()
        ackWaiter = waiter
        return try {
            link.writeControl(build(token))
            withTimeoutOrNull(ackWaitMs) { waiter.await() } ?: false
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        } finally {
            if (ackWaiter === waiter) ackWaiter = null
            // Free the slot on timeout/failure so checkpoints are not blocked forever.
            if (!waiter.isCompleted && inFlightToken == token) inFlightToken = null
        }
    }

    // --- per-connection state ------------------------------------------------------------------
    private var authorized = false
    private var dataJob: Job? = null
    private var stream: StreamContext? = null

    /** Wall time of the last inbound control/data notification; drives the keepalive idle check. */
    private var lastInboundMs = 0L

    /**
     * Sends a RECEIVER_HEALTH ping and waits for the watch's ACK. Used as an idle keepalive: the
     * watch treats any control message as proof the receiver is alive, which re-arms its liveness
     * watchdog and revives a session it had already presumed gone. Returns true on ACK.
     */
    private suspend fun sendReceiverHealth(): Boolean =
        sendControlAwaitAck { token ->
            ReceiverHealth(
                requestToken = token,
                batteryPct = 0,
                appStateRaw = 0,
                queueDepthFrames = 0u,
            ).encode()
        }

    /**
     * Per-connection keepalive. While authorized but not actively receiving (the watch is not
     * streaming to us, or the link has stalled), ping RECEIVER_HEALTH every interval. This:
     *  - re-arms the watch's 15 s liveness watchdog so it does not stop capturing, and
     *  - revives a watch that already presumed us gone — its control handler re-evaluates on the
     *    next message and resumes streaming, re-announcing STREAM_START to us.
     * Active streaming keeps [lastInboundMs] fresh (data + our checkpoints), so no ping fires then.
     * If the watch stops answering entirely the link is stale even though the platform still
     * reports it connected, so force a fresh GATT connection via [AudioGattLink.resync].
     */
    private suspend fun runKeepalive() {
        var failures = 0
        while (true) {
            delay(config.keepaliveIntervalMs)
            if (!authorized) {
                failures = 0
                continue
            }
            if (nowMs() - lastInboundMs < config.keepaliveIntervalMs) {
                failures = 0 // active traffic; no ping needed
                continue
            }
            if (sendReceiverHealth()) {
                failures = 0
            } else if (++failures >= config.keepaliveMaxFailures) {
                link.resync()
                return
            }
        }
    }

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
        val pendingWatchGaps = mutableListOf<KnownGapRange>()

        /**
         * False until the first STREAM_DATA/STREAM_GAP fixes the contiguity base. A fresh stream
         * is known to begin at sequence 0; a RESUME re-announcement (sent by the watch when it
         * re-attaches a receiver mid-stream after a reconnect) continues at the watch's current
         * sequence, so we adopt the first message's sequence as the base instead of assuming 0 —
         * otherwise we would synthesize a bogus multi-thousand-frame leading gap and never
         * checkpoint, stranding the resumed buffered audio.
         */
        var baseInitialized: Boolean =
            (start.flags and ProtocolConstants.STREAM_START_FLAG_RESUME) == 0u

        fun ensureBase(firstSequence: UInt, firstSampleIndex: ULong) {
            if (baseInitialized) return
            contiguousNext = firstSequence
            contiguousSampleIndex = firstSampleIndex
            baseInitialized = true
        }

        /** First missing sequence of a watch-reported gap whose extent is still unknown. */
        var openWatchGapFrom: UInt? = null

        var samplesSinceCheckpoint: ULong = 0u
        var lastCheckpointAtMs: Long = nowMs
        var checkpointedSinceLastChange = true

        class PersistedRange(val first: UInt, val endExclusive: UInt, val endSampleIndex: ULong)
        class KnownGapRange(val first: UInt, val endExclusive: UInt)

        fun rememberKnownGap(first: UInt, missingCount: UInt) {
            if (missingCount == 0u) return
            val endExclusive = first + missingCount
            if (endExclusive <= contiguousNext) return
            pendingWatchGaps += KnownGapRange(first, endExclusive)
        }

        fun advanceAccountedPrefix(): ULong {
            var advancedGapSamples = 0uL
            while (true) {
                val nextGap = pendingWatchGaps.firstOrNull {
                    it.first <= contiguousNext && it.endExclusive > contiguousNext
                }
                if (nextGap != null) {
                    val missingFrames = nextGap.endExclusive - contiguousNext
                    advancedGapSamples += missingFrames.toULong() * frameSamples
                    contiguousSampleIndex += missingFrames.toULong() * frameSamples
                    contiguousNext = nextGap.endExclusive
                    pendingWatchGaps.remove(nextGap)
                    continue
                }

                val nextRange = pendingRanges.firstOrNull { it.first == contiguousNext }
                    ?: return advancedGapSamples
                contiguousNext = nextRange.endExclusive
                contiguousSampleIndex = nextRange.endSampleIndex
                pendingRanges.remove(nextRange)
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
                        _state.value = link.lastError.value
                            ?.let { ReceiverSessionState.ConnectionFailed(it) }
                            ?: ReceiverSessionState.Disconnected
                        _watchServiceState.value = null
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
            // Session torn down (runtime stop / revoke / scope cancelled): the flow must not
            // keep claiming the last live state.
            _state.value = ReceiverSessionState.Disconnected
            _watchServiceState.value = null
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
                lastInboundMs = nowMs()
                launch {
                    link.controlNotifications.collect { bytes ->
                        lastInboundMs = nowMs()
                        when (val result = AudioCompanionProtocol.decodeControlOut(bytes)) {
                            is DecodeResult.Decoded ->
                                handleControl(result.message as ControlOutMessage, connectionScope)
                            else -> {} // unknown ids ignored per spec; malformed logged at most
                        }
                    }
                }
                launch { runKeepalive() }

                if (desiredEnabled() && _watchInfo.value?.enabled == false) {
                    if (!consumeEnableRequestPermission()) {
                        _state.value = ReceiverSessionState.Denied(AuthStatus.DeniedDisabled.raw)
                        return@coroutineScope
                    }
                    _state.value = ReceiverSessionState.PendingEnable
                    val enabled = sendControlAwaitAck(
                        requireAuthorized = false,
                        ackWaitMs = ENABLE_REQUEST_ACK_WAIT_MS,
                    ) { token ->
                        EnableRequest(token).encode()
                    }
                    if (!enabled) {
                        _state.value = ReceiverSessionState.Denied(AuthStatus.DeniedDisabled.raw)
                        return@coroutineScope
                    }
                    refreshInfoSnapshot()
                    _state.value = ReceiverSessionState.Authorizing
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
                        // Declarative reconcile: drive the watch to the user's intent now that
                        // we are authorized. This does not depend on the (pre-auth) Info state,
                        // so restart works whether the watch stayed paused on a shared link or
                        // fell back to Idle after a real disconnect.
                        connectionScope.launch { reconcileWatchState() }
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
                if (message.requestToken == inFlightToken) {
                    inFlightToken = null
                    ackWaiter?.complete(message.statusRaw == 0)
                    ackWaiter = null
                }
            }
            is Revoked -> {
                closeOpenSegment(SegmentCloseReason.Interrupted)
                authorized = false
                dataJob?.cancel()
                dataJob = null
                _state.value = ReceiverSessionState.Revoked(message.reasonRaw)
            }
            is StateChanged -> {
                _watchServiceState.value = message.serviceStateRaw
                // Safety net for a watch that pauses (policy) after we authorized: if the user
                // wants audio and we have no storage reason to hold the pause, resume.
                if (authorized &&
                    message.serviceStateRaw == ServiceState.PausedPolicy.raw &&
                    desiredEnabled() &&
                    policy.receiverFlags() == 0u
                ) {
                    connectionScope.launch { requestResume() }
                }
            }
            is ErrorMessage -> _lastProtocolError.value = message
        }
    }

    private suspend fun refreshInfoSnapshot() {
        when (val info = AudioCompanionProtocol.decodeInfo(link.readInfo())) {
            is DecodeResult.Decoded -> {
                val snapshot = info.message as InfoSnapshot
                _watchInfo.value = snapshot
                _watchServiceState.value = snapshot.serviceStateRaw
            }
            else -> {} // Keep the previous diagnostic snapshot; auth will report real failure.
        }
    }

    /**
     * Brings the watch's capture state in line with the local intent after (re)authorization.
     * Gated on the watch's reported state so the common reconnect (watch already streaming/idle)
     * sends nothing; we only act when the watch diverges from intent. RESUME/PAUSE are also
     * idempotent on the watch, so a redundant send is harmless.
     */
    private suspend fun reconcileWatchState() {
        if (!authorized) return
        val pausedOnWatch = _watchServiceState.value == ServiceState.PausedPolicy.raw
        val wantPaused = !desiredEnabled() || policy.receiverFlags() != 0u
        when {
            // We want it paused but the watch is not holding a policy pause: assert one.
            wantPaused && !pausedOnWatch ->
                requestPause(if (!desiredEnabled()) PauseReason.User.raw else PauseReason.Policy.raw)
            // We want audio and the watch is holding a policy pause: release it.
            !wantPaused && pausedOnWatch -> requestResume()
        }
    }

    private suspend fun consumeData() {
        link.dataNotifications.collect { bytes ->
            lastInboundMs = nowMs()
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
        }
    }

    private suspend fun handleStreamData(message: StreamData) {
        val ctx = stream ?: return // STREAM_DATA before STREAM_START: nothing to attach it to
        if (message.streamId != ctx.streamId) return
        ctx.ensureBase(message.firstSequence, message.firstSampleIndex)

        val first = message.firstSequence
        val count = message.frameCount.toUInt()
        val endExclusive = first + count

        val advancedKnownGapSamples = ctx.advanceAccountedPrefix()
        if (advancedKnownGapSamples > 0uL) {
            ctx.samplesSinceCheckpoint += advancedKnownGapSamples
            ctx.checkpointedSinceLastChange = false
        }

        if (endExclusive <= ctx.contiguousNext) {
            maybeSendCheckpoint(ctx)
            return // stale duplicate, already accounted
        }

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
            val advancedSamples = ctx.advanceAccountedPrefix()
            if (advancedSamples > 0uL) {
                ctx.samplesSinceCheckpoint += advancedSamples
                ctx.checkpointedSinceLastChange = false
            }
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
        ctx.ensureBase(message.firstMissingSequence, message.firstMissingSampleIndex)

        sink.recordGap(
            ctx.streamId,
            GapRecord(
                firstMissingSequence = message.firstMissingSequence,
                missingFrameCount = message.missingFrameCount,
                firstMissingSampleIndex = message.firstMissingSampleIndex,
                origin = GapOrigin.WatchReported(message.reasonRaw, message.watchDropCounter),
            ),
        )

        var advancedSamples = 0uL
        if (message.missingFrameCount == 0u) {
            // Unknown extent: account for it when the next STREAM_DATA shows where it ends.
            ctx.openWatchGapFrom = message.firstMissingSequence
        } else {
            ctx.rememberKnownGap(message.firstMissingSequence, message.missingFrameCount)
            if (message.firstMissingSequence <= ctx.contiguousNext) {
                // Known-lost range adjoining the contiguous prefix: those frames will never arrive,
                // so contiguity (and the checkpoint) advances past them.
                advancedSamples = ctx.advanceAccountedPrefix()
                if (advancedSamples > 0uL) {
                    ctx.checkpointedSinceLastChange = false
                }
            }
        }
        if (advancedSamples > 0uL) {
            ctx.samplesSinceCheckpoint += advancedSamples
            maybeSendCheckpoint(ctx)
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
        try {
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
            ctx.samplesSinceCheckpoint = 0u
            ctx.checkpointedSinceLastChange = true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // A checkpoint is recovery metadata, not the audio itself. If Core Bluetooth
            // temporarily refuses a write, keep the stream alive and retry on the next cadence.
            if (inFlightToken == token) inFlightToken = null
        } finally {
            ctx.lastCheckpointAtMs = nowMs()
        }
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
        ackWaiter?.complete(false)
        ackWaiter = null
        _grantedProtoVersion.value = null
    }

    companion object {
        /** How long pause/resume waits for an in-flight checkpoint to release the token slot. */
        private const val REQUEST_TOKEN_WAIT_MS = 2_000L

        /** How long pause/resume waits for the watch's ACK. */
        private const val REQUEST_ACK_WAIT_MS = 2_000L

        /** Enable waits on a human watch dialog; match the watch's consent-sized interaction. */
        private const val ENABLE_REQUEST_ACK_WAIT_MS = 35_000L
    }
}
