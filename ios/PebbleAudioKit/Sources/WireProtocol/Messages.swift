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
    /// Info version 2 (32 bytes): the watch's last restart. Nil from a version-1 watch. See
    /// `WatchRestart`.
    public let restart: WatchRestart?

    /// What the watch knows about its own last restart, reported so a crash loop is visible from
    /// the phone. Until 2026-09-09 the only trace of one was AUTH_RESULT status 3 — the
    /// fault-loop guard had turned background audio off after three restarts in 100 s, and the
    /// phone reported "disabled" for two hours.
    public struct WatchRestart: Equatable, Sendable {
        /// `RebootReasonCode` from the firmware (16 = watchdog, 17 = assert, 18 = stack
        /// overflow, 19 = hard fault, 21 = event queue full, 22 = out of memory; below 16 is
        /// a deliberate restart).
        public let reasonRaw: Int
        /// The guard's consecutive-fault counter; 0 again after a stand-down.
        public let faultBoots: Int
        /// Lifetime fault-class restarts, saturating at 255.
        public let errorReboots: Int
        /// The guard turned background audio off at this boot.
        public let stoodDown: Bool
        /// Stuck-task PC/LR (watchdog) or the fault address; 0 when unknown.
        public let faultPc: UInt32
        public let faultLr: UInt32

        public init(
            reasonRaw: Int, faultBoots: Int, errorReboots: Int, stoodDown: Bool,
            faultPc: UInt32, faultLr: UInt32
        ) {
            self.reasonRaw = reasonRaw
            self.faultBoots = faultBoots
            self.errorReboots = errorReboots
            self.stoodDown = stoodDown
            self.faultPc = faultPc
            self.faultLr = faultLr
        }

        public var isFault: Bool { reasonRaw >= 16 }

        public var reasonName: String {
            switch reasonRaw {
            case 0: return "unknown"
            case 1: return "low battery"
            case 2: return "software update"
            case 3: return "reset buttons held"
            case 4: return "shutdown from the menu"
            case 16: return "watchdog"
            case 17: return "assert"
            case 18: return "stack overflow"
            case 19: return "hard fault"
            case 20: return "launcher panic"
            case 21: return "event queue full"
            case 22: return "out of memory"
            case 23: return "bluetooth coredump"
            default: return "code \(reasonRaw)"
            }
        }

        /// One line for the flight recorder.
        public var summary: String {
            let fault = isFault
                ? String(format: " pc=0x%08x lr=0x%08x", faultPc, faultLr) : ""
            return "last restart: \(reasonName)\(fault); \(faultBoots) fault boot(s) in a row, "
                + "\(errorReboots) fault restart(s) logged"
                + (stoodDown ? "; the watch STOOD DOWN (turned background audio off) at this boot" : "")
        }
    }

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
        sendBackpressureEventsRaw: UInt32 = 0,
        restart: WatchRestart? = nil
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
        self.restart = restart
    }

    /// "4.36.0" from the packed word, or nil when the watch did not fill it in.
    public var fwVersionText: String? {
        guard fwVersionPacked != 0 else { return nil }
        return "\(fwVersionPacked >> 24).\((fwVersionPacked >> 16) & 0xFF).\(fwVersionPacked & 0xFFFF)"
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
        if infoVersion >= 2, let restart {
            w.u8(restart.reasonRaw)
            w.u8(restart.faultBoots)
            w.u8(restart.errorReboots)
            w.u8(restart.stoodDown ? 1 : 0)
            w.u32(restart.faultPc)
            w.u32(restart.faultLr)
        }
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

/// What the phone's own audio system says about playback, as opposed to its media service (AMS):
/// a player can publish "playing" while paused. Answers `PhoneMediaQuery`.
public struct PhoneMediaState: ControlInMessage, Equatable {
    /// The phone could check; when clear the other bits mean nothing.
    public static let flagChecked: UInt8 = 1 << 0
    /// Another app is playing audio (`AVAudioSession.isOtherAudioPlaying`).
    public static let flagOtherAudio: UInt8 = 1 << 1
    /// ... and it is non-mixable primary audio (`secondaryAudioShouldBeSilencedHint`).
    public static let flagPrimaryAudio: UInt8 = 1 << 2

    public let requestToken: Int
    public let flags: UInt8

    public init(requestToken: Int, flags: UInt8) {
        self.requestToken = requestToken
        self.flags = flags
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 3)
        w.u8(MessageId.phoneMediaState)
        w.u8(requestToken)
        w.u8(Int(flags))
        return w.toBytes()
    }
}

// Muse gadget setup relay (Section 4.3): the watch hosts Muse's setup service for a window and
// relays its characteristic values to this app, which runs the pairing protocol.

/// Asks the watch to open a pairing window, advertising as `MuseGadget` + `suffix`. The watch
/// asks the user first; the outcome arrives as `MuseSetupEvent` opened or closed.
public struct MuseSetupOpen: ControlInMessage, Equatable {
    public let requestToken: Int
    public let windowSeconds: Int
    /// Six uppercase hex digits: the gadget identity's suffix.
    public let suffix: String
    public let flags: UInt8

    public init(requestToken: Int, windowSeconds: Int, suffix: String, flags: UInt8 = 0) {
        self.requestToken = requestToken
        self.windowSeconds = windowSeconds
        self.suffix = suffix
        self.flags = flags
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 11)
        w.u8(MessageId.museSetupOpen)
        w.u8(requestToken)
        w.u16(Int(UInt16(clamping: windowSeconds)))
        var ascii = Array(suffix.utf8.prefix(6))
        while ascii.count < 6 { ascii.append(0x30) }
        w.bytes(ascii)
        w.u8(Int(flags))
        return w.toBytes()
    }
}

public enum MuseSetupAppCloseReason: UInt8, Sendable {
    case paired = 1
    case cancelled = 2
    case failed = 3
}

/// Ends the window; the watch shows the matching ending.
public struct MuseSetupClose: ControlInMessage, Equatable {
    public let requestToken: Int
    public let reasonRaw: UInt8

    public init(requestToken: Int, reasonRaw: UInt8) {
        self.requestToken = requestToken
        self.reasonRaw = reasonRaw
    }

    public init(requestToken: Int, reason: MuseSetupAppCloseReason) {
        self.init(requestToken: requestToken, reasonRaw: reason.rawValue)
    }

    public var reason: MuseSetupAppCloseReason? { MuseSetupAppCloseReason(rawValue: reasonRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 3)
        w.u8(MessageId.museSetupClose)
        w.u8(requestToken)
        w.u8(Int(reasonRaw))
        return w.toBytes()
    }
}

/// One value for the watch to notify on the setup TX characteristic, verbatim (1–240 bytes).
public struct MuseSetupTx: ControlInMessage, Equatable {
    public static let maxBytes = 240

    public let requestToken: Int
    public let data: [UInt8]

    public init(requestToken: Int, data: [UInt8]) {
        self.requestToken = requestToken
        self.data = data
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 3 + data.count)
        w.u8(MessageId.museSetupTx)
        w.u8(requestToken)
        w.u8(data.count)
        w.bytes(data)
        return w.toBytes()
    }
}

/// Ends the Muse app's link, leaving the window open for it to connect again.
public struct MuseSetupDisconnect: ControlInMessage, Equatable {
    public let requestToken: Int
    public let delayMs: Int

    public init(requestToken: Int, delayMs: Int) {
        self.requestToken = requestToken
        self.delayMs = delayMs
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 4)
        w.u8(MessageId.museSetupDisconnect)
        w.u8(requestToken)
        w.u16(Int(UInt16(clamping: delayMs)))
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

/// The watch asks whether the phone is actually playing audio; answer with `PhoneMediaState`.
public struct PhoneMediaQuery: ControlOutMessage, Equatable {
    public init() {}

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 1)
        w.u8(MessageId.phoneMediaQuery)
        return w.toBytes()
    }
}

/// One value the Muse app wrote to the watch's setup RX characteristic. A long value arrives as
/// several of these sharing `seq`, with `more` set on all but the last.
public struct MuseSetupRx: ControlOutMessage, Equatable {
    public let seq: Int
    public let flags: UInt8
    public let data: [UInt8]

    public init(seq: Int, flags: UInt8, data: [UInt8]) {
        self.seq = seq
        self.flags = flags
        self.data = data
    }

    public var more: Bool { flags & ProtocolConstants.museSetupRxFlagMore != 0 }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 4 + data.count)
        w.u8(MessageId.museSetupRx)
        w.u8(seq)
        w.u8(Int(flags))
        w.u8(data.count)
        w.bytes(data)
        return w.toBytes()
    }
}

public enum MuseSetupEventKind: UInt8, Sendable {
    case opened = 1
    case clientConnected = 2
    case subscribed = 3
    case clientDisconnected = 4
    case closed = 5
    case rxOverflow = 6
    case mtu = 7
}

public enum MuseSetupCloseReason: UInt8, Sendable {
    case appPaired = 1
    case appCancelled = 2
    case appFailed = 3
    case timeout = 4
    case cancelledOnWatch = 5
    case declinedOnWatch = 6
    case phoneLinkLost = 7
    case couldNotStart = 8
    case receiverGone = 9
}

/// What happened on the pairing window.
public struct MuseSetupEvent: ControlOutMessage, Equatable {
    public let eventRaw: UInt8
    public let detail: UInt8
    /// The Muse link's ATT MTU, 0 when there is none.
    public let mtu: Int
    public let secondsLeft: Int

    public init(eventRaw: UInt8, detail: UInt8, mtu: Int, secondsLeft: Int) {
        self.eventRaw = eventRaw
        self.detail = detail
        self.mtu = mtu
        self.secondsLeft = secondsLeft
    }

    public var event: MuseSetupEventKind? { MuseSetupEventKind(rawValue: eventRaw) }
    /// For a `closed` event, why.
    public var closeReason: MuseSetupCloseReason? {
        event == .closed ? MuseSetupCloseReason(rawValue: detail) : nil
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 7)
        w.u8(MessageId.museSetupEvent)
        w.u8(Int(eventRaw))
        w.u8(Int(detail))
        w.u16(Int(UInt16(clamping: mtu)))
        w.u16(Int(UInt16(clamping: secondsLeft)))
        return w.toBytes()
    }
}

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

// ---------------------------------------------------------------------------------------------
// Push-to-talk (Section 4.4) and watch actions (Section 4.5)
// ---------------------------------------------------------------------------------------------

public enum PttEventKind: UInt8, Sendable {
    case start = 1
    case end = 2
    case cancel = 3
    /// The wearer picked option `detail` of the turn's answer (watch capability bit5).
    case pick = 4
}

public enum PttTrigger: UInt8, Sendable {
    case quickLaunch = 1
    case inApp = 2
    case followUp = 3
}

public enum PttEndReason: UInt8, Sendable {
    case released = 1
    case maxLength = 2
}

public enum PttCancelReason: UInt8, Sendable {
    case tooShort = 1
    case cancelled = 2
    case phoneUnavailable = 3
    case micUnavailable = 4
}

/// A question begins, ends or is called off on the watch.
public struct PttEvent: ControlOutMessage, Equatable {
    public let turn: Int
    public let eventRaw: UInt8
    public let detail: UInt8
    /// End/Cancel: frames captured in the turn.
    public let frameCount: Int
    /// Start: the longest question the watch records.
    public let maxSeconds: Int

    public init(turn: Int, eventRaw: UInt8, detail: UInt8, frameCount: Int = 0, maxSeconds: Int = 0) {
        self.turn = turn
        self.eventRaw = eventRaw
        self.detail = detail
        self.frameCount = frameCount
        self.maxSeconds = maxSeconds
    }

    public var event: PttEventKind? { PttEventKind(rawValue: eventRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 8)
        w.u8(MessageId.pttEvent)
        w.u8(turn)
        w.u8(Int(eventRaw))
        w.u8(Int(detail))
        w.u16(frameCount)
        w.u16(maxSeconds)
        return w.toBytes()
    }
}

/// The question's audio, as it is captured: Speex frames numbered from 0 at the press.
public struct PttAudio: DataMessage, Equatable {
    public let turn: Int
    public let firstFrame: Int
    public let frames: [[UInt8]]

    public init(turn: Int, firstFrame: Int, frames: [[UInt8]]) {
        self.turn = turn
        self.firstFrame = firstFrame
        self.frames = frames
    }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 5 + frames.reduce(0) { $0 + 2 + $1.count })
        w.u8(MessageId.pttAudio)
        w.u8(turn)
        w.u16(firstFrame)
        w.u8(frames.count)
        for frame in frames {
            w.u16(frame.count)
            w.bytes(frame)
        }
        return w.toBytes()
    }
}

public enum AssistantUpdateKind: UInt8, Sendable {
    case heard = 1
    case status = 2
    case answer = 3
    case done = 4
    case error = 5
    /// The answer so far is replaced by this text; `answer` appends to it from here.
    case answerRestart = 6
    /// The receiver begins a turn of its own (`AssistantBegin` in `detail`); bit5.
    case begin = 7
    /// One option the wearer can pick: `detail` its index, the text its words; bit5.
    case option = 8
}

/// ASSISTANT_UPDATE Begin `detail`.
public enum AssistantBegin: UInt8, Sendable {
    /// A message the assistant sent by itself.
    case message = 0
    /// An answer that came after the receiver stopped waiting; the text is its question.
    case lateAnswer = 1
}

public enum AssistantError: UInt8, Sendable {
    case notSetUp = 1
    case unreachable = 2
    case noAnswer = 3
    case didNotCatch = 4
    case busy = 5
    /// The receiver stopped waiting while the assistant still works; the answer comes later.
    case stillWorking = 6
}

/// What the assistant heard, is doing, and answered, for the watch to show.
public struct AssistantUpdate: ControlInMessage, Equatable {
    public let requestToken: Int
    public let turn: Int
    public let kindRaw: UInt8
    public let detail: UInt8
    /// UTF-8, at most `ProtocolConstants.assistantTextMaxBytes`.
    public let text: [UInt8]

    public init(requestToken: Int, turn: Int, kindRaw: UInt8, detail: UInt8 = 0, text: [UInt8] = []) {
        self.requestToken = requestToken
        self.turn = turn
        self.kindRaw = kindRaw
        self.detail = detail
        self.text = text
    }

    public init(requestToken: Int, turn: Int, kind: AssistantUpdateKind, detail: UInt8 = 0, text: [UInt8] = []) {
        self.init(requestToken: requestToken, turn: turn, kindRaw: kind.rawValue, detail: detail, text: text)
    }

    public var kind: AssistantUpdateKind? { AssistantUpdateKind(rawValue: kindRaw) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 6 + text.count)
        w.u8(MessageId.assistantUpdate)
        w.u8(requestToken)
        w.u8(turn)
        w.u8(Int(kindRaw))
        w.u8(Int(detail))
        w.u8(text.count)
        w.bytes(text)
        return w.toBytes()
    }

    /// `text` split into pieces of at most `maxBytes`, never inside a character.
    public static func chunks(of text: String, maxBytes: Int = ProtocolConstants.assistantTextMaxBytes) -> [[UInt8]] {
        var pieces: [[UInt8]] = []
        var current: [UInt8] = []
        for scalar in text.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if current.count + bytes.count > maxBytes {
                pieces.append(current)
                current = []
            }
            current += bytes
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// One write of a watch action; a long payload spans several with the same `actionId`.
public struct WatchAction: ControlInMessage, Equatable {
    public let requestToken: Int
    public let actionId: Int
    public let flags: UInt8
    public let payload: [UInt8]

    public init(requestToken: Int, actionId: Int, flags: UInt8, payload: [UInt8]) {
        self.requestToken = requestToken
        self.actionId = actionId
        self.flags = flags
        self.payload = payload
    }

    public var more: Bool { flags & ProtocolConstants.watchActionFlagMore != 0 }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 5 + payload.count)
        w.u8(MessageId.watchAction)
        w.u8(requestToken)
        w.u8(actionId)
        w.u8(Int(flags))
        w.u8(payload.count)
        w.bytes(payload)
        return w.toBytes()
    }
}

/// What a watch action asks the watch to do (the joined `WATCH_ACTION` payload).
public enum WatchActionRequest: Equatable, Sendable {
    case timer(seconds: Int, label: String)
    case alarm(hour: Int, minute: Int, label: String)
    case choose(question: String, options: [String], timeoutSeconds: Int)
    case music(MusicCommand)
    /// `minutes` 0: until turned off.
    case quietTime(on: Bool, minutes: Int)
    case launchApp(name: String)
    case findWatch(seconds: Int)
    case health(HealthMetric, days: Int)
    /// The receiver's own short message, shown on the watch.
    case notice(String)

    public enum Kind: UInt8, Sendable {
        case timer = 1
        case alarm = 2
        case choose = 3
        case music = 4
        case quietTime = 5
        case launchApp = 6
        case findWatch = 7
        case health = 8
        case notice = 9
    }

    public enum MusicCommand: UInt8, Sendable, CaseIterable {
        case play = 1
        case pause = 2
        case togglePlayPause = 3
        case next = 4
        case previous = 5
        case volumeUp = 6
        case volumeDown = 7
        /// Changes nothing; the result says what is playing.
        case nowPlaying = 8
    }

    public enum HealthMetric: UInt8, Sendable, CaseIterable {
        case steps = 1
        case distanceMeters = 2
        case activeSeconds = 3
        case activeKCalories = 4
        case sleepSeconds = 5
        /// The latest reading: the result is "bpm,age_seconds".
        case heartRate = 6
    }

    public enum Invalid: Error, Equatable, Sendable {
        case outOfRange(String)
    }

    /// The joined payload. Strings longer than their limit are cut on a character boundary.
    public func payload() throws(Invalid) -> [UInt8] {
        var w = WireWriter(initialCapacity: 64)
        switch self {
        case .timer(let seconds, let label):
            guard (1...86_400).contains(seconds) else { throw .outOfRange("timer seconds \(seconds)") }
            w.u8(Int(Kind.timer.rawValue))
            w.u32(UInt32(seconds))
            Self.string(&w, label, max: ProtocolConstants.watchActionLabelMaxBytes)
        case .alarm(let hour, let minute, let label):
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw .outOfRange("alarm \(hour):\(minute)")
            }
            w.u8(Int(Kind.alarm.rawValue))
            w.u8(hour)
            w.u8(minute)
            Self.string(&w, label, max: ProtocolConstants.watchActionLabelMaxBytes)
        case .choose(let question, let options, let timeoutSeconds):
            guard (ProtocolConstants.watchActionMinOptions...ProtocolConstants.watchActionMaxOptions).contains(options.count) else {
                throw .outOfRange("\(options.count) options")
            }
            w.u8(Int(Kind.choose.rawValue))
            w.u16(min(max(timeoutSeconds, 10), 300))
            Self.string(&w, question, max: ProtocolConstants.watchActionQuestionMaxBytes)
            w.u8(options.count)
            for option in options {
                Self.string(&w, option, max: ProtocolConstants.watchActionOptionMaxBytes)
            }
        case .music(let command):
            w.u8(Int(Kind.music.rawValue))
            w.u8(Int(command.rawValue))
        case .quietTime(let on, let minutes):
            guard (0...0xFFFF).contains(minutes) else { throw .outOfRange("quiet time minutes \(minutes)") }
            w.u8(Int(Kind.quietTime.rawValue))
            w.u8(on ? 1 : 0)
            w.u16(minutes)
        case .launchApp(let name):
            guard !name.isEmpty else { throw .outOfRange("empty app name") }
            w.u8(Int(Kind.launchApp.rawValue))
            Self.string(&w, name, max: ProtocolConstants.watchActionAppNameMaxBytes)
        case .findWatch(let seconds):
            w.u8(Int(Kind.findWatch.rawValue))
            w.u8(min(max(seconds, 1), ProtocolConstants.watchActionFindMaxSeconds))
        case .health(let metric, let days):
            w.u8(Int(Kind.health.rawValue))
            w.u8(Int(metric.rawValue))
            w.u8(min(max(days, 1), ProtocolConstants.watchActionHealthMaxDays))
        case .notice(let text):
            guard !text.isEmpty else { throw .outOfRange("empty notice") }
            w.u8(Int(Kind.notice.rawValue))
            Self.string(&w, text, max: ProtocolConstants.watchActionNoticeMaxBytes)
        }
        return w.toBytes()
    }

    /// The writes that carry it, each with a token from `token`.
    public func messages(actionId: Int, token: () -> Int) throws(Invalid) -> [WatchAction] {
        let bytes = try payload()
        var messages: [WatchAction] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + ProtocolConstants.watchActionFragmentMaxBytes, bytes.count)
            let more: UInt8 = end < bytes.count ? ProtocolConstants.watchActionFlagMore : 0
            messages.append(WatchAction(requestToken: token(), actionId: actionId, flags: more, payload: Array(bytes[offset..<end])))
            offset = end
        }
        return messages
    }

    /// Parses a joined payload; nil when it doesn't follow Section 4.5.
    public static func parse(_ bytes: [UInt8]) -> WatchActionRequest? {
        var r = WireReader(bytes)
        func string() -> String? {
            guard r.remaining >= 1 else { return nil }
            let length = r.u8()
            guard r.remaining >= length else { return nil }
            return String(decoding: r.readBytes(length), as: UTF8.self)
        }
        guard r.remaining >= 1, let kind = Kind(rawValue: UInt8(r.u8())) else { return nil }
        switch kind {
        case .timer:
            guard r.remaining >= 4 else { return nil }
            let seconds = Int(r.u32())
            guard let label = string() else { return nil }
            return .timer(seconds: seconds, label: label)
        case .alarm:
            guard r.remaining >= 2 else { return nil }
            let hour = r.u8()
            let minute = r.u8()
            guard let label = string() else { return nil }
            return .alarm(hour: hour, minute: minute, label: label)
        case .choose:
            guard r.remaining >= 2 else { return nil }
            let timeout = r.u16()
            guard let question = string(), r.remaining >= 1 else { return nil }
            let count = r.u8()
            var options: [String] = []
            for _ in 0..<count {
                guard let option = string() else { return nil }
                options.append(option)
            }
            return .choose(question: question, options: options, timeoutSeconds: timeout)
        case .music:
            guard r.remaining >= 1, let command = MusicCommand(rawValue: UInt8(r.u8())) else { return nil }
            return .music(command)
        case .quietTime:
            guard r.remaining >= 3 else { return nil }
            let on = r.u8() != 0
            return .quietTime(on: on, minutes: r.u16())
        case .launchApp:
            guard let name = string(), !name.isEmpty else { return nil }
            return .launchApp(name: name)
        case .findWatch:
            guard r.remaining >= 1 else { return nil }
            return .findWatch(seconds: r.u8())
        case .health:
            guard r.remaining >= 2, let metric = HealthMetric(rawValue: UInt8(r.u8())) else { return nil }
            return .health(metric, days: r.u8())
        case .notice:
            guard let text = string(), !text.isEmpty else { return nil }
            return .notice(text)
        }
    }

    private static func string(_ w: inout WireWriter, _ text: String, max: Int) {
        let bytes = AssistantUpdate.chunks(of: text, maxBytes: max).first ?? []
        w.u8(bytes.count)
        w.bytes(bytes)
    }
}

public enum WatchActionStatus: UInt8, Sendable {
    case done = 1
    case declined = 2
    case timedOut = 3
    case failed = 4
    case unsupported = 5
}

/// How a watch action ended.
public struct WatchActionResult: ControlOutMessage, Equatable {
    public let actionId: Int
    public let statusRaw: UInt8
    /// Choose: the chosen option's index.
    public let value: Int
    /// What is playing, the app that was opened, or health numbers (Section 4.5); empty for none.
    public let text: [UInt8]

    public init(actionId: Int, statusRaw: UInt8, value: Int = 0, text: [UInt8] = []) {
        self.actionId = actionId
        self.statusRaw = statusRaw
        self.value = value
        self.text = text
    }

    public var status: WatchActionStatus? { WatchActionStatus(rawValue: statusRaw) }
    public var textString: String? { text.isEmpty ? nil : String(decoding: text, as: UTF8.self) }

    public func encode() -> [UInt8] {
        var w = WireWriter(initialCapacity: 5 + text.count)
        w.u8(MessageId.watchActionResult)
        w.u8(actionId)
        w.u8(Int(statusRaw))
        w.u8(value)
        if !text.isEmpty {
            w.u8(text.count)
            w.bytes(text)
        }
        return w.toBytes()
    }
}
