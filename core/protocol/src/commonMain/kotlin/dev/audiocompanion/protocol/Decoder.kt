package dev.audiocompanion.protocol

/**
 * Result of decoding one wire message. Per spec Section 2:
 * - too-short messages for a known id -> [Malformed]
 * - longer-than-v1 messages for a known id -> decoded, trailing bytes ignored
 * - unknown message ids -> [UnknownMessage] (callers must ignore, never error)
 */
sealed interface DecodeResult {
    data class Decoded(val message: AudioCompanionMessage) : DecodeResult

    class UnknownMessage(val msgId: Int, val bytes: ByteArray) : DecodeResult {
        override fun toString(): String = "UnknownMessage(msgId=0x${msgId.toString(16)}, size=${bytes.size})"
    }

    data class Malformed(val reason: String) : DecodeResult
}

/** Decoders for the three inbound byte channels plus the Info snapshot. */
object AudioCompanionProtocol {

    /** Decodes the 20-byte Info characteristic snapshot (Section 3). */
    fun decodeInfo(bytes: ByteArray): DecodeResult {
        if (bytes.size < ProtocolConstants.INFO_SNAPSHOT_BYTES) {
            return DecodeResult.Malformed("info snapshot too short: ${bytes.size}")
        }
        val r = WireReader(bytes)
        val infoVersion = r.u8()
        val protocolMin = r.u8()
        val protocolMax = r.u8()
        val serviceStateRaw = r.u8()
        val codecBitmap = r.u8()
        val flags = r.u8()
        val reserved0 = r.u16()
        val watchCapabilities = r.u32()
        val fwVersionPacked = r.u32()
        val sendBackpressureEventsRaw = r.u32()
        // A v2 snapshot cut short reads as v1: the first 20 bytes are unchanged.
        val restart = if (infoVersion >= 2 && bytes.size >= ProtocolConstants.INFO_SNAPSHOT_V2_BYTES) {
            InfoSnapshot.WatchRestart(
                reasonRaw = r.u8(),
                faultBoots = r.u8(),
                errorReboots = r.u8(),
                stoodDown = r.u8() != 0,
                faultPc = r.u32(),
                faultLr = r.u32(),
            )
        } else {
            null
        }
        return DecodeResult.Decoded(
            InfoSnapshot(
                infoVersion = infoVersion,
                protocolMin = protocolMin,
                protocolMax = protocolMax,
                serviceStateRaw = serviceStateRaw,
                codecBitmap = codecBitmap,
                flags = flags,
                reserved0 = reserved0,
                watchCapabilities = watchCapabilities,
                fwVersionPacked = fwVersionPacked,
                sendBackpressureEventsRaw = sendBackpressureEventsRaw,
                restart = restart,
            )
        )
    }

    /** Decodes a phone -> watch control write (Section 4.1). */
    fun decodeControlIn(bytes: ByteArray): DecodeResult {
        if (bytes.isEmpty()) return DecodeResult.Malformed("empty control message")
        return when (val msgId = bytes[0].toInt() and 0xFF) {
            MessageId.AUTH_REQUEST -> decodeAuthRequest(bytes)
            MessageId.AUTH_REVOKE -> sized(bytes, 34) { r ->
                r.u8()
                AuthRevoke(requestToken = r.u8(), receiverId = r.bytes(32))
            }
            MessageId.CHECKPOINT -> sized(bytes, 26) { r ->
                r.u8()
                Checkpoint(
                    requestToken = r.u8(),
                    streamId = r.u32(),
                    highestContiguousSequencePersisted = r.u32(),
                    persistedSampleIndex = r.u64(),
                    receiverFlags = r.u32(),
                    freeStorageHintKb = r.u32(),
                )
            }
            MessageId.PAUSE_REQUEST -> sized(bytes, 3) { r ->
                r.u8()
                PauseRequest(requestToken = r.u8(), reasonRaw = r.u8())
            }
            MessageId.RESUME_REQUEST -> sized(bytes, 2) { r ->
                r.u8()
                ResumeRequest(requestToken = r.u8())
            }
            MessageId.ENABLE_REQUEST -> sized(bytes, 2) { r ->
                r.u8()
                EnableRequest(requestToken = r.u8())
            }
            MessageId.PHONE_MEDIA_STATE -> sized(bytes, 3) { r ->
                r.u8()
                PhoneMediaState(requestToken = r.u8(), flags = r.u8())
            }
            MessageId.MUSE_SETUP_OPEN -> sized(bytes, 11) { r ->
                r.u8()
                val token = r.u8()
                val seconds = r.u16()
                val suffix = r.bytes(ProtocolConstants.MUSE_SUFFIX_BYTES).decodeToString()
                MuseSetupOpen(requestToken = token, windowSeconds = seconds, suffix = suffix, flags = r.u8())
            }
            MessageId.MUSE_SETUP_CLOSE -> sized(bytes, 3) { r ->
                r.u8()
                MuseSetupClose(requestToken = r.u8(), reasonRaw = r.u8())
            }
            MessageId.MUSE_SETUP_TX -> {
                if (bytes.size < 3) return DecodeResult.Malformed("MUSE_SETUP_TX too short: ${bytes.size}")
                val length = bytes[2].toInt() and 0xFF
                if (length < 1 || length > ProtocolConstants.MUSE_SETUP_TX_MAX_BYTES || bytes.size < 3 + length) {
                    return DecodeResult.Malformed("MUSE_SETUP_TX length $length does not fit ${bytes.size} bytes")
                }
                DecodeResult.Decoded(
                    MuseSetupTx(requestToken = bytes[1].toInt() and 0xFF, data = bytes.copyOfRange(3, 3 + length)),
                )
            }
            MessageId.MUSE_SETUP_DISCONNECT -> sized(bytes, 4) { r ->
                r.u8()
                MuseSetupDisconnect(requestToken = r.u8(), delayMs = r.u16())
            }
            MessageId.ASSISTANT_UPDATE -> {
                if (bytes.size < 6) return DecodeResult.Malformed("ASSISTANT_UPDATE too short: ${bytes.size}")
                val turn = bytes[2].toInt() and 0xFF
                val kind = bytes[3].toInt() and 0xFF
                val length = bytes[5].toInt() and 0xFF
                if (turn == 0 || kind !in 1..6 || length > ProtocolConstants.ASSISTANT_TEXT_MAX_BYTES || bytes.size < 6 + length) {
                    return DecodeResult.Malformed("ASSISTANT_UPDATE turn $turn kind $kind length $length in ${bytes.size} bytes")
                }
                DecodeResult.Decoded(
                    AssistantUpdate(
                        requestToken = bytes[1].toInt() and 0xFF,
                        turn = turn,
                        kindRaw = kind,
                        detail = bytes[4].toInt() and 0xFF,
                        text = bytes.copyOfRange(6, 6 + length),
                    ),
                )
            }
            MessageId.WATCH_ACTION -> {
                if (bytes.size < 5) return DecodeResult.Malformed("WATCH_ACTION too short: ${bytes.size}")
                val actionId = bytes[2].toInt() and 0xFF
                val length = bytes[4].toInt() and 0xFF
                if (actionId == 0 || length < 1 || length > ProtocolConstants.WATCH_ACTION_FRAGMENT_MAX_BYTES || bytes.size < 5 + length) {
                    return DecodeResult.Malformed("WATCH_ACTION id $actionId length $length in ${bytes.size} bytes")
                }
                DecodeResult.Decoded(
                    WatchAction(
                        requestToken = bytes[1].toInt() and 0xFF,
                        actionId = actionId,
                        flags = bytes[3].toInt() and 0xFF,
                        payload = bytes.copyOfRange(5, 5 + length),
                    ),
                )
            }
            MessageId.RECEIVER_HEALTH -> sized(bytes, 8) { r ->
                r.u8()
                ReceiverHealth(
                    requestToken = r.u8(),
                    batteryPct = r.u8(),
                    appStateRaw = r.u8(),
                    queueDepthFrames = r.u32(),
                )
            }
            else -> DecodeResult.UnknownMessage(msgId, bytes)
        }
    }

    /** Decodes a watch -> phone control notification (Section 4.2). */
    fun decodeControlOut(bytes: ByteArray): DecodeResult {
        if (bytes.isEmpty()) return DecodeResult.Malformed("empty control message")
        return when (val msgId = bytes[0].toInt() and 0xFF) {
            MessageId.AUTH_RESULT -> sized(bytes, 4) { r ->
                r.u8()
                AuthResult(requestToken = r.u8(), statusRaw = r.u8(), grantedProtoVersion = r.u8())
            }
            MessageId.REVOKED -> sized(bytes, 2) { r ->
                r.u8()
                Revoked(reasonRaw = r.u8())
            }
            MessageId.ACK -> sized(bytes, 3) { r ->
                r.u8()
                Ack(requestToken = r.u8(), statusRaw = r.u8())
            }
            MessageId.STATE_CHANGED -> sized(bytes, 2) { r ->
                r.u8()
                StateChanged(serviceStateRaw = r.u8())
            }
            MessageId.PHONE_MEDIA_QUERY -> sized(bytes, 1) { r ->
                r.u8()
                PhoneMediaQuery
            }
            MessageId.MUSE_SETUP_RX -> {
                if (bytes.size < 4) return DecodeResult.Malformed("MUSE_SETUP_RX too short: ${bytes.size}")
                val length = bytes[3].toInt() and 0xFF
                if (bytes.size < 4 + length) {
                    return DecodeResult.Malformed("MUSE_SETUP_RX length $length does not fit ${bytes.size} bytes")
                }
                DecodeResult.Decoded(
                    MuseSetupRx(
                        seq = bytes[1].toInt() and 0xFF,
                        flags = bytes[2].toInt() and 0xFF,
                        data = bytes.copyOfRange(4, 4 + length),
                    ),
                )
            }
            MessageId.PTT_EVENT -> sized(bytes, 8) { r ->
                r.u8()
                PttEvent(turn = r.u8(), eventRaw = r.u8(), detail = r.u8(), frameCount = r.u16(), maxSeconds = r.u16())
            }
            MessageId.WATCH_ACTION_RESULT -> {
                if (bytes.size < 4) return DecodeResult.Malformed("WATCH_ACTION_RESULT too short: ${bytes.size} < 4")
                var text = ByteArray(0)
                if (bytes.size > 4) {
                    val length = bytes[4].toInt() and 0xFF
                    if (bytes.size < 5 + length) {
                        return DecodeResult.Malformed("WATCH_ACTION_RESULT text $length does not fit ${bytes.size} bytes")
                    }
                    text = bytes.copyOfRange(5, 5 + length)
                }
                DecodeResult.Decoded(
                    WatchActionResult(
                        actionId = bytes[1].toInt() and 0xFF,
                        statusRaw = bytes[2].toInt() and 0xFF,
                        value = bytes[3].toInt() and 0xFF,
                        text = text,
                    )
                )
            }
            MessageId.MUSE_SETUP_EVENT -> sized(bytes, 7) { r ->
                r.u8()
                MuseSetupEvent(eventRaw = r.u8(), detail = r.u8(), mtu = r.u16(), secondsLeft = r.u16())
            }
            MessageId.ERROR -> sized(bytes, 6) { r ->
                r.u8()
                ErrorMessage(errorCodeRaw = r.u8(), detail = r.u32())
            }
            else -> DecodeResult.UnknownMessage(msgId, bytes)
        }
    }

    /** Decodes a watch -> phone data notification (Section 5). */
    fun decodeData(bytes: ByteArray): DecodeResult {
        if (bytes.isEmpty()) return DecodeResult.Malformed("empty data message")
        return when (val msgId = bytes[0].toInt() and 0xFF) {
            MessageId.STREAM_START -> sized(bytes, 40) { r ->
                r.u8()
                StreamStart(
                    protocolVersion = r.u8(),
                    streamId = r.u32(),
                    codecIdRaw = r.u8(),
                    channels = r.u8(),
                    frameSamples = r.u16(),
                    sampleRateHz = r.u32(),
                    bitRateBps = r.u32(),
                    frameDurationMs = r.u16(),
                    startTimeMs = r.u64(),
                    startMonotonicMs = r.u64(),
                    flags = r.u32(),
                )
            }
            MessageId.STREAM_DATA -> decodeStreamData(bytes)
            MessageId.PTT_AUDIO -> decodePttAudio(bytes)
            MessageId.STREAM_GAP -> sized(bytes, 26) { r ->
                r.u8()
                StreamGap(
                    streamId = r.u32(),
                    firstMissingSequence = r.u32(),
                    missingFrameCount = r.u32(),
                    firstMissingSampleIndex = r.u64(),
                    reasonRaw = r.u8(),
                    watchDropCounter = r.u32(),
                )
            }
            MessageId.STREAM_STOP -> sized(bytes, 22) { r ->
                r.u8()
                StreamStop(
                    streamId = r.u32(),
                    reasonRaw = r.u8(),
                    finalSequence = r.u32(),
                    finalSampleIndex = r.u64(),
                    countersCrcOrZero = r.u32(),
                )
            }
            else -> DecodeResult.UnknownMessage(msgId, bytes)
        }
    }

    private fun decodeAuthRequest(bytes: ByteArray): DecodeResult {
        if (bytes.size < 36) {
            return DecodeResult.Malformed("AUTH_REQUEST too short: ${bytes.size} < 36")
        }
        val r = WireReader(bytes)
        r.u8()
        val protoVersion = r.u8()
        val requestToken = r.u8()
        val receiverId = r.bytes(32)
        val nameLen = r.u8()
        if (nameLen > ProtocolConstants.MAX_RECEIVER_NAME_BYTES) {
            return DecodeResult.Malformed("AUTH_REQUEST name_len $nameLen exceeds ${ProtocolConstants.MAX_RECEIVER_NAME_BYTES}")
        }
        if (r.remaining < nameLen) {
            return DecodeResult.Malformed("AUTH_REQUEST name_len $nameLen overruns payload (${r.remaining} bytes left)")
        }
        val name = r.bytes(nameLen).decodeToString()
        return DecodeResult.Decoded(
            AuthRequest(
                protoVersion = protoVersion,
                requestToken = requestToken,
                receiverId = receiverId,
                name = name,
            )
        )
    }

    private fun decodePttAudio(bytes: ByteArray): DecodeResult {
        if (bytes.size < 5) return DecodeResult.Malformed("PTT_AUDIO header too short: ${bytes.size} < 5")
        val r = WireReader(bytes)
        r.u8()
        val turn = r.u8()
        val firstFrame = r.u16()
        val frameCount = r.u8()
        if (turn == 0 || frameCount !in 1..ProtocolConstants.MAX_FRAMES_PER_DATA_MSG) {
            return DecodeResult.Malformed("PTT_AUDIO turn $turn frame_count $frameCount")
        }
        val frames = ArrayList<ByteArray>(frameCount)
        for (i in 0 until frameCount) {
            if (r.remaining < 2) return DecodeResult.Malformed("PTT_AUDIO truncated at frame $i length")
            val length = r.u16()
            if (length > ProtocolConstants.MAX_ENCODED_FRAME_BYTES || r.remaining < length) {
                return DecodeResult.Malformed("PTT_AUDIO frame $i length $length does not fit")
            }
            frames.add(r.bytes(length))
        }
        return DecodeResult.Decoded(PttAudio(turn = turn, firstFrame = firstFrame, frames = frames))
    }

    private fun decodeStreamData(bytes: ByteArray): DecodeResult {
        if (bytes.size < 20) {
            return DecodeResult.Malformed("STREAM_DATA header too short: ${bytes.size} < 20")
        }
        val r = WireReader(bytes)
        r.u8()
        val streamId = r.u32()
        val firstSequence = r.u32()
        val firstSampleIndex = r.u64()
        val frameCount = r.u8()
        val flags = r.u16()
        if (frameCount < 1 || frameCount > ProtocolConstants.MAX_FRAMES_PER_DATA_MSG) {
            return DecodeResult.Malformed("STREAM_DATA frame_count $frameCount outside 1..${ProtocolConstants.MAX_FRAMES_PER_DATA_MSG}")
        }
        val frames = ArrayList<ByteArray>(frameCount)
        repeat(frameCount) { i ->
            if (r.remaining < 2) {
                return DecodeResult.Malformed("STREAM_DATA truncated at frame $i length")
            }
            val len = r.u16()
            if (len > ProtocolConstants.MAX_ENCODED_FRAME_BYTES) {
                return DecodeResult.Malformed("STREAM_DATA frame $i length $len exceeds MAX_ENCODED_FRAME_BYTES")
            }
            if (r.remaining < len) {
                return DecodeResult.Malformed("STREAM_DATA truncated inside frame $i payload")
            }
            frames.add(r.bytes(len))
        }
        return DecodeResult.Decoded(
            StreamData(
                streamId = streamId,
                firstSequence = firstSequence,
                firstSampleIndex = firstSampleIndex,
                flags = flags,
                frames = frames,
            )
        )
    }

    /** Common path: reject < [v1Size], parse the v1 prefix, ignore appended (future) bytes. */
    private inline fun sized(
        bytes: ByteArray,
        v1Size: Int,
        parse: (WireReader) -> AudioCompanionMessage,
    ): DecodeResult {
        if (bytes.size < v1Size) {
            return DecodeResult.Malformed(
                "message 0x${(bytes[0].toInt() and 0xFF).toString(16)} too short: ${bytes.size} < $v1Size"
            )
        }
        return DecodeResult.Decoded(parse(WireReader(bytes)))
    }
}
