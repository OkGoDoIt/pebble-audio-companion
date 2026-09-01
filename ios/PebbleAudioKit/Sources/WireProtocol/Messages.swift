/// Wire messages, spec Sections 3-5. All multi-byte integers are little-endian; structs are
/// packed. Enum-typed fields are stored as the raw wire byte (`*Raw`) with a nullable decoded
/// accessor so unknown future values survive a decode/encode round trip.
/// Port of `core/protocol/.../Messages.kt`.
public protocol AudioCompanionMessage: Sendable {
    /// Encodes the version-1 wire representation (exact bytes, no trailing data).
    func encode() -> [UInt8]
}

/// Phone -> watch control write (ids 0x01-0x3F).
public protocol ControlInMessage: AudioCompanionMessage {}

/// Watch -> phone control notification (ids 0x41-0x7F).
public protocol ControlOutMessage: AudioCompanionMessage {}

/// Watch -> phone data notification (ids 0x80-0x9F).
public protocol DataMessage: AudioCompanionMessage {}

// ---------------------------------------------------------------------------------------------
// Info characteristic (Section 3) — fixed 20-byte snapshot, no msg id.
// ---------------------------------------------------------------------------------------------

public struct InfoSnapshot: AudioCompanionMessage, Equatable {
    public let infoVersion: Int
    public let protocolMin: Int
    public let protocolMax: Int
    public let serviceStateRaw: UInt8
    public let codecBitmap: Int
    public let flags: Int
    public let reserved0: Int
    public let watchCapabilities: UInt32
    public let fwVersionPacked: UInt32
    /// Wire bytes 16-19 (was `reserved1`): notifications the watch's transport refused since
    /// service init. Raw because it is only a count when `flags` bit3 says so — read
    /// `sendBackpressureEvents`, never this.
    public let sendBackpressureEventsRaw: UInt32

    public init(
        infoVersion: Int,
        protocolMin: Int,
        protocolMax: Int,
        serviceStateRaw: UInt8,
        codecBitmap: Int,
        flags: Int,
        reserved0: Int = 0,
        watchCapabilities: UInt32 = 0,
        fwVersionPacked: UInt32 = 0,
        sendBackpressureEventsRaw: UInt32 = 0
    ) {
        self.infoVersion = infoVersion
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.serviceStateRaw = serviceStateRaw
        self.codecBitmap = codecBitmap
        self.flags = flags
        self.reserved0 = reserved0
        self.watchCapabilities = watchCapabilities
        self.fwVersionPacked = fwVersionPacked
        self.sendBackpressureEventsRaw = sendBackpressureEventsRaw
    }

    public var serviceState: ServiceState? { ServiceState(rawValue: serviceStateRaw) }
    public var receiverAuthorized: Bool { flags & ProtocolConstants.infoFlagReceiverAuthorized != 0 }
    public var enabled: Bool { flags & ProtocolConstants.infoFlagEnabled != 0 }
    public var consentPending: Bool { flags & ProtocolConstants.infoFlagConsentPending != 0 }
    /// Whether this firmware reports the backpressure counter at all (`flags` bit3).
    public var reportsSendBackpressure: Bool {
        flags & ProtocolConstants.infoFlagBackpressureCounter != 0
    }
    /// Notifications the watch's transport refused since service init, or nil when this
    /// firmware does not report it.
    ///
    /// The nil is the point. Firmware that predates the field leaves the word zero, and a zero
    /// read as a count says "the radio never refused anything" — the opposite of "we cannot
    /// tell". With the count, audio going missing while this climbs is airtime loss (the link
    /// could not absorb the stream); audio going missing while it stays flat is credit
    /// starvation (this phone stopped checkpointing, so the watch's spool never freed).
    public var sendBackpressureEvents: UInt32? {
        reportsSendBackpressure ? sendBackpressureEventsRaw : nil
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: ProtocolConstants.infoSnapshotBytes)
        w.u8(infoVersion)
        w.u8(protocolMin)
        w.u8(protocolMax)
        w.u8(Int(serviceStateRaw))
        w.u8(codecBitmap)
        w.u8(flags)
        w.u16(reserved0)
        w.u32(watchCapabilities)
        w.u32(fwVersionPacked)
        w.u32(sendBackpressureEventsRaw)
        return w.toBytes()
    }
}

// ---------------------------------------------------------------------------------------------
// Control: phone -> watch (Section 4.1)
// ---------------------------------------------------------------------------------------------

public struct AuthRequest: ControlInMessage, Equatable {
    public let protoVersion: Int
    public let requestToken: Int
    public let receiverId: [UInt8]
    public let name: String

    public init(protoVersion: Int, requestToken: Int, receiverId: [UInt8], name: String) {
        precondition(
            receiverId.count == ProtocolConstants.receiverIdBytes,
            "receiver_id must be \(ProtocolConstants.receiverIdBytes) bytes, got \(receiverId.count)"
        )
        precondition(
            name.utf8.count <= ProtocolConstants.maxReceiverNameBytes,
            "name must encode to <= \(ProtocolConstants.maxReceiverNameBytes) UTF-8 bytes"
        )
        self.protoVersion = protoVersion
        self.requestToken = requestToken
        self.receiverId = receiverId
        self.name = name
    }

    public func encode() -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var w = WireWriter(initialCapacity: 36 + nameBytes.count)
        w.u8(MessageId.authRequest)
        w.u8(protoVersion)
        w.u8(requestToken)
        w.bytes(receiverId)
        w.u8(nameBytes.count)
        w.bytes(nameBytes)
        return w.toBytes()
    }
}

public struct AuthRevoke: ControlInMessage, Equatable {
    public let requestToken: Int
    public let receiverId: [UInt8]

    public init(requestToken: Int, receiverId: [UInt8]) {
        precondition(
            receiverId.count == ProtocolConstants.receiverIdBytes,
            "receiver_id must be \(ProtocolConstants.receiverIdBytes) bytes, got \(receiverId.count)"
        )
        self.requestToken = requestToken
        self.receiverId = receiverId
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 34)
        w.u8(MessageId.authRevoke)
        w.u8(requestToken)
        w.bytes(receiverId)
        return w.toBytes()
    }
}

public struct Checkpoint: ControlInMessage, Equatable {
    public let requestToken: Int
    public let streamId: UInt32
    public let highestContiguousSequencePersisted: UInt32
    public let persistedSampleIndex: UInt64
    public let receiverFlags: UInt32
    public let freeStorageHintKb: UInt32

    public init(
        requestToken: Int,
        streamId: UInt32,
        highestContiguousSequencePersisted: UInt32,
        persistedSampleIndex: UInt64,
        receiverFlags: UInt32,
        freeStorageHintKb: UInt32
    ) {
        self.requestToken = requestToken
        self.streamId = streamId
        self.highestContiguousSequencePersisted = highestContiguousSequencePersisted
        self.persistedSampleIndex = persistedSampleIndex
        self.receiverFlags = receiverFlags
        self.freeStorageHintKb = freeStorageHintKb
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 26)
        w.u8(MessageId.checkpoint)
        w.u8(requestToken)
        w.u32(streamId)
        w.u32(highestContiguousSequencePersisted)
        w.u64(persistedSampleIndex)
        w.u32(receiverFlags)
        w.u32(freeStorageHintKb)
        return w.toBytes()
    }
}

public struct PauseRequest: ControlInMessage, Equatable {
    public let requestToken: Int
    public let reasonRaw: UInt8

    public init(requestToken: Int, reasonRaw: UInt8) {
        self.requestToken = requestToken
        self.reasonRaw = reasonRaw
    }

    public var reason: PauseReason? { PauseReason(rawValue: reasonRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 3)
        w.u8(MessageId.pauseRequest)
        w.u8(requestToken)
        w.u8(Int(reasonRaw))
        return w.toBytes()
    }
}

public struct ResumeRequest: ControlInMessage, Equatable {
    public let requestToken: Int

    public init(requestToken: Int) {
        self.requestToken = requestToken
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 2)
        w.u8(MessageId.resumeRequest)
        w.u8(requestToken)
        return w.toBytes()
    }
}

public struct EnableRequest: ControlInMessage, Equatable {
    public let requestToken: Int

    public init(requestToken: Int) {
        self.requestToken = requestToken
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 2)
        w.u8(MessageId.enableRequest)
        w.u8(requestToken)
        return w.toBytes()
    }
}

public struct ReceiverHealth: ControlInMessage, Equatable {
    public let requestToken: Int
    public let batteryPct: Int
    public let appStateRaw: UInt8
    public let queueDepthFrames: UInt32

    public init(requestToken: Int, batteryPct: Int, appStateRaw: UInt8, queueDepthFrames: UInt32) {
        self.requestToken = requestToken
        self.batteryPct = batteryPct
        self.appStateRaw = appStateRaw
        self.queueDepthFrames = queueDepthFrames
    }

    public var appState: ReceiverAppState? { ReceiverAppState(rawValue: appStateRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 8)
        w.u8(MessageId.receiverHealth)
        w.u8(requestToken)
        w.u8(batteryPct)
        w.u8(Int(appStateRaw))
        w.u32(queueDepthFrames)
        return w.toBytes()
    }
}

// ---------------------------------------------------------------------------------------------
// Control: watch -> phone (Section 4.2)
// ---------------------------------------------------------------------------------------------

public struct AuthResult: ControlOutMessage, Equatable {
    public let requestToken: Int
    public let statusRaw: UInt8
    public let grantedProtoVersion: Int

    public init(requestToken: Int, statusRaw: UInt8, grantedProtoVersion: Int) {
        self.requestToken = requestToken
        self.statusRaw = statusRaw
        self.grantedProtoVersion = grantedProtoVersion
    }

    public var status: AuthStatus? { AuthStatus(rawValue: statusRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 4)
        w.u8(MessageId.authResult)
        w.u8(requestToken)
        w.u8(Int(statusRaw))
        w.u8(grantedProtoVersion)
        return w.toBytes()
    }
}

public struct Revoked: ControlOutMessage, Equatable {
    public let reasonRaw: UInt8

    public init(reasonRaw: UInt8) {
        self.reasonRaw = reasonRaw
    }

    public var reason: RevokeReason? { RevokeReason(rawValue: reasonRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 2)
        w.u8(MessageId.revoked)
        w.u8(Int(reasonRaw))
        return w.toBytes()
    }
}

public struct Ack: ControlOutMessage, Equatable {
    public let requestToken: Int
    public let statusRaw: UInt8

    public init(requestToken: Int, statusRaw: UInt8) {
        self.requestToken = requestToken
        self.statusRaw = statusRaw
    }

    public var status: AckStatus? { AckStatus(rawValue: statusRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 3)
        w.u8(MessageId.ack)
        w.u8(requestToken)
        w.u8(Int(statusRaw))
        return w.toBytes()
    }
}

public struct StateChanged: ControlOutMessage, Equatable {
    public let serviceStateRaw: UInt8

    public init(serviceStateRaw: UInt8) {
        self.serviceStateRaw = serviceStateRaw
    }

    public var serviceState: ServiceState? { ServiceState(rawValue: serviceStateRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 2)
        w.u8(MessageId.stateChanged)
        w.u8(Int(serviceStateRaw))
        return w.toBytes()
    }
}

public struct ErrorMessage: ControlOutMessage, Equatable {
    public let errorCodeRaw: UInt8
    public let detail: UInt32

    public init(errorCodeRaw: UInt8, detail: UInt32) {
        self.errorCodeRaw = errorCodeRaw
        self.detail = detail
    }

    public var errorCode: ProtocolErrorCode? { ProtocolErrorCode(rawValue: errorCodeRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 6)
        w.u8(MessageId.error)
        w.u8(Int(errorCodeRaw))
        w.u32(detail)
        return w.toBytes()
    }
}

// ---------------------------------------------------------------------------------------------
// Data channel (Section 5)
// ---------------------------------------------------------------------------------------------

public struct StreamStart: DataMessage, Equatable {
    public let protocolVersion: Int
    public let streamId: UInt32
    public let codecIdRaw: UInt8
    public let channels: Int
    public let frameSamples: Int
    public let sampleRateHz: UInt32
    public let bitRateBps: UInt32
    public let frameDurationMs: Int
    public let startTimeMs: UInt64
    public let startMonotonicMs: UInt64
    public let flags: UInt32

    public init(
        protocolVersion: Int,
        streamId: UInt32,
        codecIdRaw: UInt8,
        channels: Int,
        frameSamples: Int,
        sampleRateHz: UInt32,
        bitRateBps: UInt32,
        frameDurationMs: Int,
        startTimeMs: UInt64,
        startMonotonicMs: UInt64,
        flags: UInt32
    ) {
        self.protocolVersion = protocolVersion
        self.streamId = streamId
        self.codecIdRaw = codecIdRaw
        self.channels = channels
        self.frameSamples = frameSamples
        self.sampleRateHz = sampleRateHz
        self.bitRateBps = bitRateBps
        self.frameDurationMs = frameDurationMs
        self.startTimeMs = startTimeMs
        self.startMonotonicMs = startMonotonicMs
        self.flags = flags
    }

    public var codecId: CodecId? { CodecId(rawValue: codecIdRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 40)
        w.u8(MessageId.streamStart)
        w.u8(protocolVersion)
        w.u32(streamId)
        w.u8(Int(codecIdRaw))
        w.u8(channels)
        w.u16(frameSamples)
        w.u32(sampleRateHz)
        w.u32(bitRateBps)
        w.u16(frameDurationMs)
        w.u64(startTimeMs)
        w.u64(startMonotonicMs)
        w.u32(flags)
        return w.toBytes()
    }
}

public struct StreamData: DataMessage, Equatable {
    public let streamId: UInt32
    public let firstSequence: UInt32
    public let firstSampleIndex: UInt64
    public let flags: Int
    public let frames: [[UInt8]]

    public init(
        streamId: UInt32,
        firstSequence: UInt32,
        firstSampleIndex: UInt64,
        flags: Int,
        frames: [[UInt8]]
    ) {
        precondition(
            (1...ProtocolConstants.maxFramesPerDataMsg).contains(frames.count),
            "frame_count must be 1..\(ProtocolConstants.maxFramesPerDataMsg), got \(frames.count)"
        )
        for frame in frames {
            precondition(
                frame.count <= ProtocolConstants.maxEncodedFrameBytes,
                "frame length \(frame.count) exceeds MAX_ENCODED_FRAME_BYTES"
            )
        }
        self.streamId = streamId
        self.firstSequence = firstSequence
        self.firstSampleIndex = firstSampleIndex
        self.flags = flags
        self.frames = frames
    }

    public var frameCount: Int { frames.count }

    /// Sequence of frame *i* (spec: frames are consecutive).
    public func sequenceOf(_ index: Int) -> UInt32 {
        firstSequence &+ UInt32(index)
    }

    /// Sample index of frame *i* given the stream's frame_samples.
    public func sampleIndexOf(_ index: Int, frameSamples: Int) -> UInt64 {
        firstSampleIndex &+ (UInt64(index) &* UInt64(frameSamples))
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 20 + frames.reduce(0) { $0 + $1.count + 2 })
        w.u8(MessageId.streamData)
        w.u32(streamId)
        w.u32(firstSequence)
        w.u64(firstSampleIndex)
        w.u8(frames.count)
        w.u16(flags)
        for frame in frames {
            w.u16(frame.count)
            w.bytes(frame)
        }
        return w.toBytes()
    }
}

public struct StreamGap: DataMessage, Equatable {
    public let streamId: UInt32
    public let firstMissingSequence: UInt32
    /// 0 = unknown / elapsed-time-only gap.
    public let missingFrameCount: UInt32
    public let firstMissingSampleIndex: UInt64
    public let reasonRaw: UInt8
    public let watchDropCounter: UInt32

    public init(
        streamId: UInt32,
        firstMissingSequence: UInt32,
        missingFrameCount: UInt32,
        firstMissingSampleIndex: UInt64,
        reasonRaw: UInt8,
        watchDropCounter: UInt32
    ) {
        self.streamId = streamId
        self.firstMissingSequence = firstMissingSequence
        self.missingFrameCount = missingFrameCount
        self.firstMissingSampleIndex = firstMissingSampleIndex
        self.reasonRaw = reasonRaw
        self.watchDropCounter = watchDropCounter
    }

    public var reason: GapReason? { GapReason(rawValue: reasonRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 26)
        w.u8(MessageId.streamGap)
        w.u32(streamId)
        w.u32(firstMissingSequence)
        w.u32(missingFrameCount)
        w.u64(firstMissingSampleIndex)
        w.u8(Int(reasonRaw))
        w.u32(watchDropCounter)
        return w.toBytes()
    }
}

public struct StreamStop: DataMessage, Equatable {
    public let streamId: UInt32
    public let reasonRaw: UInt8
    public let finalSequence: UInt32
    public let finalSampleIndex: UInt64
    public let countersCrcOrZero: UInt32

    public init(
        streamId: UInt32,
        reasonRaw: UInt8,
        finalSequence: UInt32,
        finalSampleIndex: UInt64,
        countersCrcOrZero: UInt32
    ) {
        self.streamId = streamId
        self.reasonRaw = reasonRaw
        self.finalSequence = finalSequence
        self.finalSampleIndex = finalSampleIndex
        self.countersCrcOrZero = countersCrcOrZero
    }

    public var reason: StopReason? { StopReason(rawValue: reasonRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 22)
        w.u8(MessageId.streamStop)
        w.u32(streamId)
        w.u8(Int(reasonRaw))
        w.u32(finalSequence)
        w.u64(finalSampleIndex)
        w.u32(countersCrcOrZero)
        return w.toBytes()
    }
}
