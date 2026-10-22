package dev.audiocompanion.protocol

/**
 * Wire messages, spec Sections 3-5. All multi-byte integers are little-endian; structs are
 * packed. Enum-typed fields are stored as the raw wire integer (`*Raw`) with a nullable
 * decoded accessor so unknown future values survive a decode/encode round trip.
 */
sealed interface AudioCompanionMessage {
    /** Encodes the version-1 wire representation (exact bytes, no trailing data). */
    fun encode(): ByteArray
}

/** Phone -> watch control write (ids 0x01-0x3F). */
sealed interface ControlInMessage : AudioCompanionMessage

/** Watch -> phone control notification (ids 0x41-0x7F). */
sealed interface ControlOutMessage : AudioCompanionMessage

/** Watch -> phone data notification (ids 0x80-0x9F). */
sealed interface DataMessage : AudioCompanionMessage

// ---------------------------------------------------------------------------------------------
// Info characteristic (Section 3) — fixed 20-byte snapshot, no msg id.
// ---------------------------------------------------------------------------------------------

data class InfoSnapshot(
    val infoVersion: Int,
    val protocolMin: Int,
    val protocolMax: Int,
    val serviceStateRaw: Int,
    val codecBitmap: Int,
    val flags: Int,
    val reserved0: Int = 0,
    val watchCapabilities: UInt = 0u,
    val fwVersionPacked: UInt = 0u,
    /**
     * Wire bytes 16-19 (was `reserved1`): notifications the watch's transport refused since
     * service init. Raw because it is only a count when `flags` bit3 says so — read
     * [sendBackpressureEvents], never this.
     */
    val sendBackpressureEventsRaw: UInt = 0u,
    /** Info v2: why the watch last restarted. Null on a v1 snapshot. */
    val restart: WatchRestart? = null,
) : AudioCompanionMessage {
    /** Info v2 bytes 20-31: the watch's last restart and its fault-loop guard. */
    data class WatchRestart(
        val reasonRaw: Int,
        val faultBoots: Int,
        val errorReboots: Int,
        val stoodDown: Boolean,
        val faultPc: UInt,
        val faultLr: UInt,
    )

    val serviceState: ServiceState? get() = ServiceState.fromRaw(serviceStateRaw)
    val receiverAuthorized: Boolean get() = flags and ProtocolConstants.INFO_FLAG_RECEIVER_AUTHORIZED != 0
    val enabled: Boolean get() = flags and ProtocolConstants.INFO_FLAG_ENABLED != 0
    val consentPending: Boolean get() = flags and ProtocolConstants.INFO_FLAG_CONSENT_PENDING != 0

    /** Whether this firmware reports the backpressure counter at all (`flags` bit3). */
    val reportsSendBackpressure: Boolean
        get() = flags and ProtocolConstants.INFO_FLAG_BACKPRESSURE_COUNTER != 0

    /**
     * Notifications the watch's transport refused since service init, or null when this firmware
     * does not report it. The null is the point: firmware that predates the field leaves the word
     * zero, and a zero read as a count says "the radio never refused anything" — the opposite of
     * "we cannot tell".
     */
    val sendBackpressureEvents: UInt?
        get() = if (reportsSendBackpressure) sendBackpressureEventsRaw else null

    override fun encode(): ByteArray {
        val w = WireWriter(ProtocolConstants.INFO_SNAPSHOT_V2_BYTES)
            .u8(infoVersion)
            .u8(protocolMin)
            .u8(protocolMax)
            .u8(serviceStateRaw)
            .u8(codecBitmap)
            .u8(flags)
            .u16(reserved0)
            .u32(watchCapabilities)
            .u32(fwVersionPacked)
            .u32(sendBackpressureEventsRaw)
        if (infoVersion >= 2 && restart != null) {
            w.u8(restart.reasonRaw)
                .u8(restart.faultBoots)
                .u8(restart.errorReboots)
                .u8(if (restart.stoodDown) 1 else 0)
                .u32(restart.faultPc)
                .u32(restart.faultLr)
        }
        return w.toByteArray()
    }
}

// ---------------------------------------------------------------------------------------------
// Control: phone -> watch (Section 4.1)
// ---------------------------------------------------------------------------------------------

class AuthRequest(
    val protoVersion: Int,
    val requestToken: Int,
    val receiverId: ByteArray,
    val name: String,
) : ControlInMessage {
    init {
        require(receiverId.size == ProtocolConstants.RECEIVER_ID_BYTES) {
            "receiver_id must be ${ProtocolConstants.RECEIVER_ID_BYTES} bytes, got ${receiverId.size}"
        }
        require(name.encodeToByteArray().size <= ProtocolConstants.MAX_RECEIVER_NAME_BYTES) {
            "name must encode to <= ${ProtocolConstants.MAX_RECEIVER_NAME_BYTES} UTF-8 bytes"
        }
    }

    override fun encode(): ByteArray {
        val nameBytes = name.encodeToByteArray()
        return WireWriter(36 + nameBytes.size)
            .u8(MessageId.AUTH_REQUEST)
            .u8(protoVersion)
            .u8(requestToken)
            .bytes(receiverId)
            .u8(nameBytes.size)
            .bytes(nameBytes)
            .toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is AuthRequest &&
        protoVersion == other.protoVersion && requestToken == other.requestToken &&
        receiverId.contentEquals(other.receiverId) && name == other.name

    override fun hashCode(): Int =
        ((protoVersion * 31 + requestToken) * 31 + receiverId.contentHashCode()) * 31 + name.hashCode()

    override fun toString(): String =
        "AuthRequest(protoVersion=$protoVersion, requestToken=$requestToken, name=$name)"
}

class AuthRevoke(
    val requestToken: Int,
    val receiverId: ByteArray,
) : ControlInMessage {
    init {
        require(receiverId.size == ProtocolConstants.RECEIVER_ID_BYTES) {
            "receiver_id must be ${ProtocolConstants.RECEIVER_ID_BYTES} bytes, got ${receiverId.size}"
        }
    }

    override fun encode(): ByteArray = WireWriter(34)
        .u8(MessageId.AUTH_REVOKE)
        .u8(requestToken)
        .bytes(receiverId)
        .toByteArray()

    override fun equals(other: Any?): Boolean = other is AuthRevoke &&
        requestToken == other.requestToken && receiverId.contentEquals(other.receiverId)

    override fun hashCode(): Int = requestToken * 31 + receiverId.contentHashCode()

    override fun toString(): String = "AuthRevoke(requestToken=$requestToken)"
}

data class Checkpoint(
    val requestToken: Int,
    val streamId: UInt,
    val highestContiguousSequencePersisted: UInt,
    val persistedSampleIndex: ULong,
    val receiverFlags: UInt,
    val freeStorageHintKb: UInt,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(26)
        .u8(MessageId.CHECKPOINT)
        .u8(requestToken)
        .u32(streamId)
        .u32(highestContiguousSequencePersisted)
        .u64(persistedSampleIndex)
        .u32(receiverFlags)
        .u32(freeStorageHintKb)
        .toByteArray()
}

data class PauseRequest(
    val requestToken: Int,
    val reasonRaw: Int,
) : ControlInMessage {
    val reason: PauseReason? get() = PauseReason.fromRaw(reasonRaw)

    override fun encode(): ByteArray = WireWriter(3)
        .u8(MessageId.PAUSE_REQUEST)
        .u8(requestToken)
        .u8(reasonRaw)
        .toByteArray()
}

data class ResumeRequest(
    val requestToken: Int,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(2)
        .u8(MessageId.RESUME_REQUEST)
        .u8(requestToken)
        .toByteArray()
}

data class EnableRequest(
    val requestToken: Int,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(2)
        .u8(MessageId.ENABLE_REQUEST)
        .u8(requestToken)
        .toByteArray()
}

/**
 * What the phone's own audio system says about playback, as opposed to its media service: a
 * player can publish "playing" while paused. Answers [PhoneMediaQuery].
 */
data class PhoneMediaState(
    val requestToken: Int,
    val flags: Int,
) : ControlInMessage {
    val checked: Boolean get() = flags and FLAG_CHECKED != 0
    val otherAudioPlaying: Boolean get() = flags and FLAG_OTHER_AUDIO != 0
    val primaryAudioPlaying: Boolean get() = flags and FLAG_PRIMARY_AUDIO != 0

    override fun encode(): ByteArray = WireWriter(3)
        .u8(MessageId.PHONE_MEDIA_STATE)
        .u8(requestToken)
        .u8(flags)
        .toByteArray()

    companion object {
        const val FLAG_CHECKED: Int = 1 shl 0
        const val FLAG_OTHER_AUDIO: Int = 1 shl 1
        const val FLAG_PRIMARY_AUDIO: Int = 1 shl 2
    }
}

// Muse gadget setup relay (Section 4.3): the watch hosts Muse's setup service for a window and
// relays its characteristic values to this app, which runs the pairing protocol.

/**
 * Asks the watch to open a pairing window, advertising as `MuseGadget` + [suffix]. The watch asks
 * the user first; the outcome arrives as a [MuseSetupEvent] (opened or closed).
 */
data class MuseSetupOpen(
    val requestToken: Int,
    val windowSeconds: Int,
    /** Six uppercase hex digits: the gadget identity's suffix. */
    val suffix: String,
    val flags: Int = 0,
) : ControlInMessage {
    override fun encode(): ByteArray {
        val ascii = ByteArray(ProtocolConstants.MUSE_SUFFIX_BYTES) { '0'.code.toByte() }
        val given = suffix.encodeToByteArray()
        given.copyInto(ascii, endIndex = minOf(given.size, ascii.size))
        return WireWriter(11)
            .u8(MessageId.MUSE_SETUP_OPEN)
            .u8(requestToken)
            .u16(windowSeconds)
            .bytes(ascii)
            .u8(flags)
            .toByteArray()
    }
}

enum class MuseSetupAppCloseReason(val raw: Int) {
    PAIRED(1),
    CANCELLED(2),
    FAILED(3);

    companion object {
        fun fromRaw(raw: Int): MuseSetupAppCloseReason? = entries.firstOrNull { it.raw == raw }
    }
}

/** Ends the window; the watch shows the matching ending. */
data class MuseSetupClose(
    val requestToken: Int,
    val reasonRaw: Int,
) : ControlInMessage {
    constructor(requestToken: Int, reason: MuseSetupAppCloseReason) : this(requestToken, reason.raw)

    val reason: MuseSetupAppCloseReason? get() = MuseSetupAppCloseReason.fromRaw(reasonRaw)

    override fun encode(): ByteArray = WireWriter(3)
        .u8(MessageId.MUSE_SETUP_CLOSE)
        .u8(requestToken)
        .u8(reasonRaw)
        .toByteArray()
}

/** One value for the watch to notify on the setup TX characteristic, verbatim (1–240 bytes). */
class MuseSetupTx(
    val requestToken: Int,
    val data: ByteArray,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(3 + data.size)
        .u8(MessageId.MUSE_SETUP_TX)
        .u8(requestToken)
        .u8(data.size)
        .bytes(data)
        .toByteArray()

    override fun equals(other: Any?): Boolean =
        other is MuseSetupTx && other.requestToken == requestToken && other.data.contentEquals(data)

    override fun hashCode(): Int = 31 * requestToken + data.contentHashCode()

    override fun toString(): String = "MuseSetupTx(requestToken=$requestToken, ${data.size} bytes)"
}

/** Ends the Muse app's link, leaving the window open for it to connect again. */
data class MuseSetupDisconnect(
    val requestToken: Int,
    val delayMs: Int,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(4)
        .u8(MessageId.MUSE_SETUP_DISCONNECT)
        .u8(requestToken)
        .u16(delayMs)
        .toByteArray()
}

data class ReceiverHealth(
    val requestToken: Int,
    val batteryPct: Int,
    val appStateRaw: Int,
    val queueDepthFrames: UInt,
) : ControlInMessage {
    val appState: ReceiverAppState? get() = ReceiverAppState.fromRaw(appStateRaw)

    override fun encode(): ByteArray = WireWriter(8)
        .u8(MessageId.RECEIVER_HEALTH)
        .u8(requestToken)
        .u8(batteryPct)
        .u8(appStateRaw)
        .u32(queueDepthFrames)
        .toByteArray()
}

// ---------------------------------------------------------------------------------------------
// Control: watch -> phone (Section 4.2)
// ---------------------------------------------------------------------------------------------

/**
 * One value the Muse app wrote to the watch's setup RX characteristic. A long value arrives as
 * several of these sharing [seq], with [more] set on all but the last.
 */
class MuseSetupRx(
    val seq: Int,
    val flags: Int,
    val data: ByteArray,
) : ControlOutMessage {
    val more: Boolean get() = flags and ProtocolConstants.MUSE_SETUP_RX_FLAG_MORE != 0

    override fun encode(): ByteArray = WireWriter(4 + data.size)
        .u8(MessageId.MUSE_SETUP_RX)
        .u8(seq)
        .u8(flags)
        .u8(data.size)
        .bytes(data)
        .toByteArray()

    override fun equals(other: Any?): Boolean =
        other is MuseSetupRx && other.seq == seq && other.flags == flags && other.data.contentEquals(data)

    override fun hashCode(): Int = (31 * seq + flags) * 31 + data.contentHashCode()

    override fun toString(): String = "MuseSetupRx(seq=$seq, flags=$flags, ${data.size} bytes)"
}

enum class MuseSetupEventKind(val raw: Int) {
    OPENED(1),
    CLIENT_CONNECTED(2),
    SUBSCRIBED(3),
    CLIENT_DISCONNECTED(4),
    CLOSED(5),
    RX_OVERFLOW(6),
    MTU(7);

    companion object {
        fun fromRaw(raw: Int): MuseSetupEventKind? = entries.firstOrNull { it.raw == raw }
    }
}

enum class MuseSetupCloseReason(val raw: Int) {
    APP_PAIRED(1),
    APP_CANCELLED(2),
    APP_FAILED(3),
    TIMEOUT(4),
    CANCELLED_ON_WATCH(5),
    DECLINED_ON_WATCH(6),
    PHONE_LINK_LOST(7),
    COULD_NOT_START(8),
    RECEIVER_GONE(9);

    companion object {
        fun fromRaw(raw: Int): MuseSetupCloseReason? = entries.firstOrNull { it.raw == raw }
    }
}

/** What happened on the pairing window. */
data class MuseSetupEvent(
    val eventRaw: Int,
    val detail: Int,
    /** The Muse link's ATT MTU, 0 when there is none. */
    val mtu: Int,
    val secondsLeft: Int,
) : ControlOutMessage {
    val event: MuseSetupEventKind? get() = MuseSetupEventKind.fromRaw(eventRaw)

    /** For a [MuseSetupEventKind.CLOSED] event, why. */
    val closeReason: MuseSetupCloseReason?
        get() = if (event == MuseSetupEventKind.CLOSED) MuseSetupCloseReason.fromRaw(detail) else null

    override fun encode(): ByteArray = WireWriter(7)
        .u8(MessageId.MUSE_SETUP_EVENT)
        .u8(eventRaw)
        .u8(detail)
        .u16(mtu)
        .u16(secondsLeft)
        .toByteArray()
}

data class AuthResult(
    val requestToken: Int,
    val statusRaw: Int,
    val grantedProtoVersion: Int,
) : ControlOutMessage {
    val status: AuthStatus? get() = AuthStatus.fromRaw(statusRaw)

    override fun encode(): ByteArray = WireWriter(4)
        .u8(MessageId.AUTH_RESULT)
        .u8(requestToken)
        .u8(statusRaw)
        .u8(grantedProtoVersion)
        .toByteArray()
}

data class Revoked(
    val reasonRaw: Int,
) : ControlOutMessage {
    val reason: RevokeReason? get() = RevokeReason.fromRaw(reasonRaw)

    override fun encode(): ByteArray = WireWriter(2)
        .u8(MessageId.REVOKED)
        .u8(reasonRaw)
        .toByteArray()
}

data class Ack(
    val requestToken: Int,
    val statusRaw: Int,
) : ControlOutMessage {
    val status: AckStatus? get() = AckStatus.fromRaw(statusRaw)

    override fun encode(): ByteArray = WireWriter(3)
        .u8(MessageId.ACK)
        .u8(requestToken)
        .u8(statusRaw)
        .toByteArray()
}

data class StateChanged(
    val serviceStateRaw: Int,
) : ControlOutMessage {
    val serviceState: ServiceState? get() = ServiceState.fromRaw(serviceStateRaw)

    override fun encode(): ByteArray = WireWriter(2)
        .u8(MessageId.STATE_CHANGED)
        .u8(serviceStateRaw)
        .toByteArray()
}

/** The watch asks whether the phone is actually playing audio; answer with [PhoneMediaState]. */
data object PhoneMediaQuery : ControlOutMessage {
    override fun encode(): ByteArray = WireWriter(1)
        .u8(MessageId.PHONE_MEDIA_QUERY)
        .toByteArray()
}

data class ErrorMessage(
    val errorCodeRaw: Int,
    val detail: UInt,
) : ControlOutMessage {
    val errorCode: ProtocolErrorCode? get() = ProtocolErrorCode.fromRaw(errorCodeRaw)

    override fun encode(): ByteArray = WireWriter(6)
        .u8(MessageId.ERROR)
        .u8(errorCodeRaw)
        .u32(detail)
        .toByteArray()
}

// ---------------------------------------------------------------------------------------------
// Data channel (Section 5)
// ---------------------------------------------------------------------------------------------

data class StreamStart(
    val protocolVersion: Int,
    val streamId: UInt,
    val codecIdRaw: Int,
    val channels: Int,
    val frameSamples: Int,
    val sampleRateHz: UInt,
    val bitRateBps: UInt,
    val frameDurationMs: Int,
    val startTimeMs: ULong,
    val startMonotonicMs: ULong,
    val flags: UInt,
) : DataMessage {
    val codecId: CodecId? get() = CodecId.fromRaw(codecIdRaw)

    override fun encode(): ByteArray = WireWriter(40)
        .u8(MessageId.STREAM_START)
        .u8(protocolVersion)
        .u32(streamId)
        .u8(codecIdRaw)
        .u8(channels)
        .u16(frameSamples)
        .u32(sampleRateHz)
        .u32(bitRateBps)
        .u16(frameDurationMs)
        .u64(startTimeMs)
        .u64(startMonotonicMs)
        .u32(flags)
        .toByteArray()
}

class StreamData(
    val streamId: UInt,
    val firstSequence: UInt,
    val firstSampleIndex: ULong,
    val flags: Int,
    val frames: List<ByteArray>,
) : DataMessage {
    init {
        require(frames.size in 1..ProtocolConstants.MAX_FRAMES_PER_DATA_MSG) {
            "frame_count must be 1..${ProtocolConstants.MAX_FRAMES_PER_DATA_MSG}, got ${frames.size}"
        }
        frames.forEach {
            require(it.size <= ProtocolConstants.MAX_ENCODED_FRAME_BYTES) {
                "frame length ${it.size} exceeds MAX_ENCODED_FRAME_BYTES"
            }
        }
    }

    val frameCount: Int get() = frames.size

    /** Sequence of frame *i* (spec: frames are consecutive). */
    fun sequenceOf(index: Int): UInt = firstSequence + index.toUInt()

    /** Sample index of frame *i* given the stream's frame_samples. */
    fun sampleIndexOf(index: Int, frameSamples: Int): ULong =
        firstSampleIndex + (index.toULong() * frameSamples.toULong())

    override fun encode(): ByteArray {
        val writer = WireWriter(20 + frames.sumOf { it.size + 2 })
            .u8(MessageId.STREAM_DATA)
            .u32(streamId)
            .u32(firstSequence)
            .u64(firstSampleIndex)
            .u8(frames.size)
            .u16(flags)
        frames.forEach { frame ->
            writer.u16(frame.size)
            writer.bytes(frame)
        }
        return writer.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is StreamData &&
        streamId == other.streamId && firstSequence == other.firstSequence &&
        firstSampleIndex == other.firstSampleIndex && flags == other.flags &&
        frames.size == other.frames.size &&
        frames.zip(other.frames).all { (a, b) -> a.contentEquals(b) }

    override fun hashCode(): Int {
        var h = streamId.hashCode()
        h = h * 31 + firstSequence.hashCode()
        h = h * 31 + firstSampleIndex.hashCode()
        h = h * 31 + flags
        frames.forEach { h = h * 31 + it.contentHashCode() }
        return h
    }

    override fun toString(): String =
        "StreamData(streamId=$streamId, firstSequence=$firstSequence, " +
            "firstSampleIndex=$firstSampleIndex, frameCount=${frames.size})"
}

data class StreamGap(
    val streamId: UInt,
    val firstMissingSequence: UInt,
    /** 0 = unknown / elapsed-time-only gap. */
    val missingFrameCount: UInt,
    val firstMissingSampleIndex: ULong,
    val reasonRaw: Int,
    val watchDropCounter: UInt,
) : DataMessage {
    val reason: GapReason? get() = GapReason.fromRaw(reasonRaw)

    override fun encode(): ByteArray = WireWriter(26)
        .u8(MessageId.STREAM_GAP)
        .u32(streamId)
        .u32(firstMissingSequence)
        .u32(missingFrameCount)
        .u64(firstMissingSampleIndex)
        .u8(reasonRaw)
        .u32(watchDropCounter)
        .toByteArray()
}

data class StreamStop(
    val streamId: UInt,
    val reasonRaw: Int,
    val finalSequence: UInt,
    val finalSampleIndex: ULong,
    val countersCrcOrZero: UInt,
) : DataMessage {
    val reason: StopReason? get() = StopReason.fromRaw(reasonRaw)

    override fun encode(): ByteArray = WireWriter(22)
        .u8(MessageId.STREAM_STOP)
        .u32(streamId)
        .u8(reasonRaw)
        .u32(finalSequence)
        .u64(finalSampleIndex)
        .u32(countersCrcOrZero)
        .toByteArray()
}

// ---------------------------------------------------------------------------------------------
// Push-to-talk (Section 4.4) and watch actions (Section 4.5). The Android app does not run
// either; these keep the shared wire contract complete.
// ---------------------------------------------------------------------------------------------

/** A question begins (1), ends (2) or is called off (3) on the watch. */
data class PttEvent(
    val turn: Int,
    val eventRaw: Int,
    val detail: Int,
    val frameCount: Int = 0,
    val maxSeconds: Int = 0,
) : ControlOutMessage {
    override fun encode(): ByteArray = WireWriter(8)
        .u8(MessageId.PTT_EVENT)
        .u8(turn)
        .u8(eventRaw)
        .u8(detail)
        .u16(frameCount)
        .u16(maxSeconds)
        .toByteArray()
}

/** The question's audio: Speex frames numbered from 0 at the press. */
class PttAudio(
    val turn: Int,
    val firstFrame: Int,
    val frames: List<ByteArray>,
) : DataMessage {
    override fun encode(): ByteArray {
        val w = WireWriter(5 + frames.sumOf { 2 + it.size })
            .u8(MessageId.PTT_AUDIO)
            .u8(turn)
            .u16(firstFrame)
            .u8(frames.size)
        for (frame in frames) w.u16(frame.size).bytes(frame)
        return w.toByteArray()
    }

    override fun equals(other: Any?): Boolean =
        other is PttAudio && other.turn == turn && other.firstFrame == firstFrame &&
            other.frames.size == frames.size && other.frames.indices.all { other.frames[it].contentEquals(frames[it]) }

    override fun hashCode(): Int = (turn * 31 + firstFrame) * 31 + frames.size

    override fun toString(): String = "PttAudio(turn=$turn, firstFrame=$firstFrame, ${frames.size} frames)"
}

/** What the assistant heard (1), is doing (2), answered (3), done (4), or why it failed (5). */
class AssistantUpdate(
    val requestToken: Int,
    val turn: Int,
    val kindRaw: Int,
    val detail: Int,
    val text: ByteArray,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(6 + text.size)
        .u8(MessageId.ASSISTANT_UPDATE)
        .u8(requestToken)
        .u8(turn)
        .u8(kindRaw)
        .u8(detail)
        .u8(text.size)
        .bytes(text)
        .toByteArray()

    override fun equals(other: Any?): Boolean =
        other is AssistantUpdate && other.requestToken == requestToken && other.turn == turn &&
            other.kindRaw == kindRaw && other.detail == detail && other.text.contentEquals(text)

    override fun hashCode(): Int = ((requestToken * 31 + turn) * 31 + kindRaw) * 31 + text.contentHashCode()

    override fun toString(): String = "AssistantUpdate(turn=$turn, kind=$kindRaw, ${text.size} bytes)"
}

/** One write of a watch action; a long payload spans writes with the same actionId. */
class WatchAction(
    val requestToken: Int,
    val actionId: Int,
    val flags: Int,
    val payload: ByteArray,
) : ControlInMessage {
    override fun encode(): ByteArray = WireWriter(5 + payload.size)
        .u8(MessageId.WATCH_ACTION)
        .u8(requestToken)
        .u8(actionId)
        .u8(flags)
        .u8(payload.size)
        .bytes(payload)
        .toByteArray()

    override fun equals(other: Any?): Boolean =
        other is WatchAction && other.requestToken == requestToken && other.actionId == actionId &&
            other.flags == flags && other.payload.contentEquals(payload)

    override fun hashCode(): Int = (requestToken * 31 + actionId) * 31 + payload.contentHashCode()

    override fun toString(): String = "WatchAction(id=$actionId, flags=$flags, ${payload.size} bytes)"
}

/**
 * How a watch action ended: 1 done, 2 declined, 3 timed out, 4 failed, 5 unsupported. `text` is
 * what is playing, the app that was opened, or health numbers (Section 4.5); empty for none.
 */
/** The wearer marked a moment as important on the watch (Section 4.6). */
data class MomentMark(
    /** Counts marks on the watch, 1-255 and round again; with [wallMs], names a mark sent twice. */
    val markId: Int,
    val flags: Int,
    /** The recording's stream and its next sample at the mark; both 0 when nothing was recording. */
    val streamId: UInt,
    val sampleIndex: ULong,
    /** The watch's clock at the mark, UTC ms. */
    val wallMs: ULong,
) : ControlOutMessage {
    val whileRecording: Boolean get() = flags and FLAG_RECORDING != 0

    override fun encode(): ByteArray = WireWriter(24)
        .u8(MessageId.MOMENT_MARK)
        .u8(markId)
        .u8(flags)
        .u8(0)
        .u32(streamId)
        .u64(sampleIndex)
        .u64(wallMs)
        .toByteArray()

    companion object {
        const val FLAG_RECORDING: Int = 0x01
    }
}

class WatchActionResult(
    val actionId: Int,
    val statusRaw: Int,
    val value: Int,
    val text: ByteArray = ByteArray(0),
) : ControlOutMessage {
    override fun encode(): ByteArray {
        val w = WireWriter(5 + text.size)
            .u8(MessageId.WATCH_ACTION_RESULT)
            .u8(actionId)
            .u8(statusRaw)
            .u8(value)
        if (text.isNotEmpty()) w.u8(text.size).bytes(text)
        return w.toByteArray()
    }

    val textString: String? get() = if (text.isEmpty()) null else text.decodeToString()

    override fun equals(other: Any?): Boolean = other is WatchActionResult &&
        other.actionId == actionId && other.statusRaw == statusRaw && other.value == value &&
        other.text.contentEquals(text)

    override fun hashCode(): Int = ((actionId * 31 + statusRaw) * 31 + value) * 31 + text.contentHashCode()

    override fun toString(): String = "WatchActionResult(id=$actionId, status=$statusRaw, value=$value, ${text.size} text bytes)"
}

/** Native alarm management (WATCH_ACTION kind 10). 255 preserves an update field. */
data class WatchAlarms(
    val operation: Int, val id: Int = 0, val hour: Int = 255, val minute: Int = 255,
    val smart: Int = 255, val enabled: Int = 255,
) {
    fun payload(): ByteArray {
        require(operation in 0..3 && id in 0..9)
        require(hour in 0..23 || hour == 255)
        require(minute in 0..59 || minute == 255)
        require(smart in listOf(0, 1, 255) && enabled in listOf(0, 1, 255))
        require(operation != 1 || (hour != 255 && minute != 255 && smart != 255 && enabled == 1))
        return byteArrayOf(10, operation.toByte(), id.toByte(), hour.toByte(), minute.toByte(), smart.toByte(), enabled.toByte())
    }
}
