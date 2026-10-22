/// Result of decoding one wire message. Per spec Section 2:
/// - too-short messages for a known id -> `.malformed`
/// - longer-than-v1 messages for a known id -> decoded, trailing bytes ignored
/// - unknown message ids -> `.unknownMessage` (callers must ignore, never error)
/// Port of `core/protocol/.../Decoder.kt`.
public enum DecodeResult: Sendable {
    case decoded(AudioCompanionMessage)
    case unknownMessage(msgId: Int, bytes: [UInt8])
    case malformed(reason: String)
}

extension DecodeResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .decoded(let message):
            return "Decoded(\(message))"
        case .unknownMessage(let msgId, let bytes):
            return "UnknownMessage(msgId=0x\(String(msgId, radix: 16)), size=\(bytes.count))"
        case .malformed(let reason):
            return "Malformed(\(reason))"
        }
    }
}

/// Decoders for the three inbound byte channels plus the Info snapshot.
public enum AudioCompanionProtocol {

    /// Decodes the 20-byte Info characteristic snapshot (Section 3).
    public static func decodeInfo(_ bytes: [UInt8]) -> DecodeResult {
        if bytes.count < ProtocolConstants.infoSnapshotBytes {
            return .malformed(reason: "info snapshot too short: \(bytes.count)")
        }
        var r = WireReader(bytes)
        let infoVersion = r.u8()
        let protocolMin = r.u8()
        let protocolMax = r.u8()
        let serviceStateRaw = UInt8(r.u8())
        let codecBitmap = r.u8()
        let flags = r.u8()
        let reserved0 = r.u16()
        let watchCapabilities = r.u32()
        let fwVersionPacked = r.u32()
        let sendBackpressureEventsRaw = r.u32()
        var restart: InfoSnapshot.WatchRestart?
        if infoVersion >= 2, bytes.count >= ProtocolConstants.infoSnapshotV2Bytes {
            let reasonRaw = r.u8()
            let faultBoots = r.u8()
            let errorReboots = r.u8()
            let stoodDown = r.u8()
            restart = InfoSnapshot.WatchRestart(
                reasonRaw: reasonRaw, faultBoots: faultBoots, errorReboots: errorReboots,
                stoodDown: stoodDown != 0, faultPc: r.u32(), faultLr: r.u32())
        }
        return .decoded(
            InfoSnapshot(
                infoVersion: infoVersion,
                protocolMin: protocolMin,
                protocolMax: protocolMax,
                serviceStateRaw: serviceStateRaw,
                codecBitmap: codecBitmap,
                flags: flags,
                reserved0: reserved0,
                watchCapabilities: watchCapabilities,
                fwVersionPacked: fwVersionPacked,
                sendBackpressureEventsRaw: sendBackpressureEventsRaw,
                restart: restart
            )
        )
    }

    /// Decodes a phone -> watch control write (Section 4.1).
    public static func decodeControlIn(_ bytes: [UInt8]) -> DecodeResult {
        guard let first = bytes.first else { return .malformed(reason: "empty control message") }
        let msgId = Int(first)
        switch msgId {
        case MessageId.authRequest:
            return decodeAuthRequest(bytes)
        case MessageId.authRevoke:
            return sized(bytes, 34) { r in
                _ = r.u8()
                return AuthRevoke(requestToken: r.u8(), receiverId: r.readBytes(32))
            }
        case MessageId.checkpoint:
            return sized(bytes, 26) { r in
                _ = r.u8()
                return Checkpoint(
                    requestToken: r.u8(),
                    streamId: r.u32(),
                    highestContiguousSequencePersisted: r.u32(),
                    persistedSampleIndex: r.u64(),
                    receiverFlags: r.u32(),
                    freeStorageHintKb: r.u32()
                )
            }
        case MessageId.pauseRequest:
            return sized(bytes, 3) { r in
                _ = r.u8()
                return PauseRequest(requestToken: r.u8(), reasonRaw: UInt8(r.u8()))
            }
        case MessageId.resumeRequest:
            return sized(bytes, 2) { r in
                _ = r.u8()
                return ResumeRequest(requestToken: r.u8())
            }
        case MessageId.enableRequest:
            return sized(bytes, 2) { r in
                _ = r.u8()
                return EnableRequest(requestToken: r.u8())
            }
        case MessageId.phoneMediaState:
            return sized(bytes, 3) { r in
                _ = r.u8()
                return PhoneMediaState(requestToken: r.u8(), flags: UInt8(r.u8()))
            }
        case MessageId.museSetupOpen:
            return sized(bytes, 11) { r in
                _ = r.u8()
                let token = r.u8()
                let seconds = Int(r.u16())
                let suffix = String(decoding: r.readBytes(6), as: UTF8.self)
                return MuseSetupOpen(requestToken: token, windowSeconds: seconds, suffix: suffix, flags: UInt8(r.u8()))
            }
        case MessageId.museSetupClose:
            return sized(bytes, 3) { r in
                _ = r.u8()
                return MuseSetupClose(requestToken: r.u8(), reasonRaw: UInt8(r.u8()))
            }
        case MessageId.museSetupTx:
            guard bytes.count >= 3 else { return .malformed(reason: "MUSE_SETUP_TX too short") }
            let length = Int(bytes[2])
            guard length >= 1, length <= MuseSetupTx.maxBytes, bytes.count >= 3 + length else {
                return .malformed(reason: "MUSE_SETUP_TX length \(length) does not fit \(bytes.count) bytes")
            }
            return .decoded(MuseSetupTx(requestToken: Int(bytes[1]), data: Array(bytes[3..<(3 + length)])))
        case MessageId.museSetupDisconnect:
            return sized(bytes, 4) { r in
                _ = r.u8()
                return MuseSetupDisconnect(requestToken: r.u8(), delayMs: Int(r.u16()))
            }
        case MessageId.assistantUpdate:
            guard bytes.count >= 6 else { return .malformed(reason: "ASSISTANT_UPDATE too short") }
            let turn = Int(bytes[2])
            let kind = bytes[3]
            let length = Int(bytes[5])
            guard turn != 0, (1...8).contains(kind), length <= ProtocolConstants.assistantTextMaxBytes,
                bytes.count >= 6 + length
            else {
                return .malformed(reason: "ASSISTANT_UPDATE turn \(turn) kind \(kind) length \(length) in \(bytes.count) bytes")
            }
            return .decoded(AssistantUpdate(
                requestToken: Int(bytes[1]), turn: turn, kindRaw: kind, detail: bytes[4],
                text: Array(bytes[6..<(6 + length)])))
        case MessageId.watchAction:
            guard bytes.count >= 5 else { return .malformed(reason: "WATCH_ACTION too short") }
            let actionId = Int(bytes[2])
            let length = Int(bytes[4])
            guard actionId != 0, length >= 1, length <= ProtocolConstants.watchActionFragmentMaxBytes,
                bytes.count >= 5 + length
            else {
                return .malformed(reason: "WATCH_ACTION id \(actionId) length \(length) in \(bytes.count) bytes")
            }
            return .decoded(WatchAction(
                requestToken: Int(bytes[1]), actionId: actionId, flags: bytes[3],
                payload: Array(bytes[5..<(5 + length)])))
        case MessageId.receiverHealth:
            return sized(bytes, 8) { r in
                _ = r.u8()
                return ReceiverHealth(
                    requestToken: r.u8(),
                    batteryPct: r.u8(),
                    appStateRaw: UInt8(r.u8()),
                    queueDepthFrames: r.u32()
                )
            }
        default:
            return .unknownMessage(msgId: msgId, bytes: bytes)
        }
    }

    /// Decodes a watch -> phone control notification (Section 4.2).
    public static func decodeControlOut(_ bytes: [UInt8]) -> DecodeResult {
        guard let first = bytes.first else { return .malformed(reason: "empty control message") }
        let msgId = Int(first)
        switch msgId {
        case MessageId.authResult:
            return sized(bytes, 4) { r in
                _ = r.u8()
                return AuthResult(
                    requestToken: r.u8(), statusRaw: UInt8(r.u8()), grantedProtoVersion: r.u8()
                )
            }
        case MessageId.revoked:
            return sized(bytes, 2) { r in
                _ = r.u8()
                return Revoked(reasonRaw: UInt8(r.u8()))
            }
        case MessageId.ack:
            return sized(bytes, 3) { r in
                _ = r.u8()
                return Ack(requestToken: r.u8(), statusRaw: UInt8(r.u8()))
            }
        case MessageId.stateChanged:
            return sized(bytes, 2) { r in
                _ = r.u8()
                return StateChanged(serviceStateRaw: UInt8(r.u8()))
            }
        case MessageId.phoneMediaQuery:
            return sized(bytes, 1) { r in
                _ = r.u8()
                return PhoneMediaQuery()
            }
        case MessageId.museSetupRx:
            guard bytes.count >= 4 else { return .malformed(reason: "MUSE_SETUP_RX too short") }
            let length = Int(bytes[3])
            guard bytes.count >= 4 + length else {
                return .malformed(reason: "MUSE_SETUP_RX length \(length) does not fit \(bytes.count) bytes")
            }
            return .decoded(MuseSetupRx(seq: Int(bytes[1]), flags: bytes[2], data: Array(bytes[4..<(4 + length)])))
        case MessageId.pttEvent:
            return sized(bytes, 8) { r in
                _ = r.u8()
                return PttEvent(turn: r.u8(), eventRaw: UInt8(r.u8()), detail: UInt8(r.u8()), frameCount: r.u16(), maxSeconds: r.u16())
            }
        case MessageId.momentMark:
            return sized(bytes, 24) { r in
                _ = r.u8()
                let markId = r.u8()
                let flags = UInt8(r.u8())
                _ = r.u8()
                return MomentMark(
                    markId: markId, flags: flags, streamId: r.u32(), sampleIndex: r.u64(),
                    wallMs: r.u64())
            }
        case MessageId.watchActionResult:
            guard bytes.count >= 4 else {
                return .malformed(reason: "WATCH_ACTION_RESULT too short: \(bytes.count) < 4")
            }
            var text: [UInt8] = []
            if bytes.count > 4 {
                let length = Int(bytes[4])
                guard bytes.count >= 5 + length else {
                    return .malformed(reason: "WATCH_ACTION_RESULT text \(length) does not fit \(bytes.count) bytes")
                }
                text = Array(bytes[5..<(5 + length)])
            }
            return .decoded(WatchActionResult(actionId: Int(bytes[1]), statusRaw: bytes[2], value: Int(bytes[3]), text: text))
        case MessageId.museSetupEvent:
            return sized(bytes, 7) { r in
                _ = r.u8()
                return MuseSetupEvent(eventRaw: UInt8(r.u8()), detail: UInt8(r.u8()), mtu: Int(r.u16()), secondsLeft: Int(r.u16()))
            }
        case MessageId.error:
            return sized(bytes, 6) { r in
                _ = r.u8()
                return ErrorMessage(errorCodeRaw: UInt8(r.u8()), detail: r.u32())
            }
        default:
            return .unknownMessage(msgId: msgId, bytes: bytes)
        }
    }

    /// Decodes a watch -> phone data notification (Section 5).
    public static func decodeData(_ bytes: [UInt8]) -> DecodeResult {
        guard let first = bytes.first else { return .malformed(reason: "empty data message") }
        let msgId = Int(first)
        switch msgId {
        case MessageId.streamStart:
            return sized(bytes, 40) { r in
                _ = r.u8()
                return StreamStart(
                    protocolVersion: r.u8(),
                    streamId: r.u32(),
                    codecIdRaw: UInt8(r.u8()),
                    channels: r.u8(),
                    frameSamples: r.u16(),
                    sampleRateHz: r.u32(),
                    bitRateBps: r.u32(),
                    frameDurationMs: r.u16(),
                    startTimeMs: r.u64(),
                    startMonotonicMs: r.u64(),
                    flags: r.u32()
                )
            }
        case MessageId.streamData:
            return decodeStreamData(bytes)
        case MessageId.pttAudio:
            return decodePttAudio(bytes)
        case MessageId.streamGap:
            return sized(bytes, 26) { r in
                _ = r.u8()
                return StreamGap(
                    streamId: r.u32(),
                    firstMissingSequence: r.u32(),
                    missingFrameCount: r.u32(),
                    firstMissingSampleIndex: r.u64(),
                    reasonRaw: UInt8(r.u8()),
                    watchDropCounter: r.u32()
                )
            }
        case MessageId.streamStop:
            return sized(bytes, 22) { r in
                _ = r.u8()
                return StreamStop(
                    streamId: r.u32(),
                    reasonRaw: UInt8(r.u8()),
                    finalSequence: r.u32(),
                    finalSampleIndex: r.u64(),
                    countersCrcOrZero: r.u32()
                )
            }
        default:
            return .unknownMessage(msgId: msgId, bytes: bytes)
        }
    }

    private static func decodeAuthRequest(_ bytes: [UInt8]) -> DecodeResult {
        if bytes.count < 36 {
            return .malformed(reason: "AUTH_REQUEST too short: \(bytes.count) < 36")
        }
        var r = WireReader(bytes)
        _ = r.u8()
        let protoVersion = r.u8()
        let requestToken = r.u8()
        let receiverId = r.readBytes(32)
        let nameLen = r.u8()
        if nameLen > ProtocolConstants.maxReceiverNameBytes {
            return .malformed(
                reason: "AUTH_REQUEST name_len \(nameLen) exceeds \(ProtocolConstants.maxReceiverNameBytes)"
            )
        }
        if r.remaining < nameLen {
            return .malformed(
                reason: "AUTH_REQUEST name_len \(nameLen) overruns payload (\(r.remaining) bytes left)"
            )
        }
        let name = String(decoding: r.readBytes(nameLen), as: UTF8.self)
        return .decoded(
            AuthRequest(
                protoVersion: protoVersion,
                requestToken: requestToken,
                receiverId: receiverId,
                name: name
            )
        )
    }

    private static func decodePttAudio(_ bytes: [UInt8]) -> DecodeResult {
        guard bytes.count >= 5 else { return .malformed(reason: "PTT_AUDIO header too short: \(bytes.count) < 5") }
        var r = WireReader(bytes)
        _ = r.u8()
        let turn = r.u8()
        let firstFrame = r.u16()
        let frameCount = r.u8()
        guard turn != 0, (1...ProtocolConstants.maxFramesPerDataMsg).contains(frameCount) else {
            return .malformed(reason: "PTT_AUDIO turn \(turn) frame_count \(frameCount)")
        }
        var frames: [[UInt8]] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            guard r.remaining >= 2 else { return .malformed(reason: "PTT_AUDIO truncated at frame \(i) length") }
            let length = r.u16()
            guard length <= ProtocolConstants.maxEncodedFrameBytes, r.remaining >= length else {
                return .malformed(reason: "PTT_AUDIO frame \(i) length \(length) does not fit")
            }
            frames.append(r.readBytes(length))
        }
        return .decoded(PttAudio(turn: turn, firstFrame: firstFrame, frames: frames))
    }

    private static func decodeStreamData(_ bytes: [UInt8]) -> DecodeResult {
        if bytes.count < 20 {
            return .malformed(reason: "STREAM_DATA header too short: \(bytes.count) < 20")
        }
        var r = WireReader(bytes)
        _ = r.u8()
        let streamId = r.u32()
        let firstSequence = r.u32()
        let firstSampleIndex = r.u64()
        let frameCount = r.u8()
        let flags = r.u16()
        if frameCount < 1 || frameCount > ProtocolConstants.maxFramesPerDataMsg {
            return .malformed(
                reason: "STREAM_DATA frame_count \(frameCount) outside 1..\(ProtocolConstants.maxFramesPerDataMsg)"
            )
        }
        var frames: [[UInt8]] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            if r.remaining < 2 {
                return .malformed(reason: "STREAM_DATA truncated at frame \(i) length")
            }
            let len = r.u16()
            if len > ProtocolConstants.maxEncodedFrameBytes {
                return .malformed(
                    reason: "STREAM_DATA frame \(i) length \(len) exceeds MAX_ENCODED_FRAME_BYTES"
                )
            }
            if r.remaining < len {
                return .malformed(reason: "STREAM_DATA truncated inside frame \(i) payload")
            }
            frames.append(r.readBytes(len))
        }
        return .decoded(
            StreamData(
                streamId: streamId,
                firstSequence: firstSequence,
                firstSampleIndex: firstSampleIndex,
                flags: flags,
                frames: frames
            )
        )
    }

    /// Common path: reject < `v1Size`, parse the v1 prefix, ignore appended (future) bytes.
    private static func sized(
        _ bytes: [UInt8],
        _ v1Size: Int,
        _ parse: (inout WireReader) -> AudioCompanionMessage
    ) -> DecodeResult {
        if bytes.count < v1Size {
            return .malformed(
                reason: "message 0x\(String(Int(bytes[0]), radix: 16)) too short: \(bytes.count) < \(v1Size)"
            )
        }
        var r = WireReader(bytes)
        return .decoded(parse(&r))
    }
}
