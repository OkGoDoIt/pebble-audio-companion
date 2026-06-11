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
    val reserved1: UInt = 0u,
) : AudioCompanionMessage {
    val serviceState: ServiceState? get() = ServiceState.fromRaw(serviceStateRaw)
    val receiverAuthorized: Boolean get() = flags and ProtocolConstants.INFO_FLAG_RECEIVER_AUTHORIZED != 0
    val enabled: Boolean get() = flags and ProtocolConstants.INFO_FLAG_ENABLED != 0
    val consentPending: Boolean get() = flags and ProtocolConstants.INFO_FLAG_CONSENT_PENDING != 0

    override fun encode(): ByteArray = WireWriter(ProtocolConstants.INFO_SNAPSHOT_BYTES)
        .u8(infoVersion)
        .u8(protocolMin)
        .u8(protocolMax)
        .u8(serviceStateRaw)
        .u8(codecBitmap)
        .u8(flags)
        .u16(reserved0)
        .u32(watchCapabilities)
        .u32(fwVersionPacked)
        .u32(reserved1)
        .toByteArray()
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
