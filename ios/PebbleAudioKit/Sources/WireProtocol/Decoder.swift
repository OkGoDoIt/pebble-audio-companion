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
        return .decoded(
            InfoSnapshot(
                infoVersion: r.u8(),
                protocolMin: r.u8(),
                protocolMax: r.u8(),
                serviceStateRaw: UInt8(r.u8()),
                codecBitmap: r.u8(),
                flags: r.u8(),
                reserved0: r.u16(),
                watchCapabilities: r.u32(),
                fwVersionPacked: r.u32(),
                reserved1: r.u32()
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
