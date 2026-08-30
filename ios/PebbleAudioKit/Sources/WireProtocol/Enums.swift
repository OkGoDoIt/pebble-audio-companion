/// Protocol enums (spec Section 7). Wire fields carry the raw integer so that unknown values
/// from newer firmware are tolerated and re-encoded byte-exactly; `init?(rawValue:)` is the
/// `fromRaw` lookup, returning nil for unknown values.
/// Port of `core/protocol/.../Enums.kt`.
public enum ServiceState: UInt8, CaseIterable, Sendable {
    case disabled = 0
    case idle = 1
    case authorizedIdle = 2
    case streaming = 3
    case pausedConflict = 4
    case pausedPolicy = 5
    case pausedLowBattery = 6
    case error = 7
    case pausedPowerSave = 8
}

public enum CodecId: UInt8, CaseIterable, Sendable {
    case speexWideband = 0x01
    case pcm16Debug = 0x02
    case opusReserved = 0x03
    case lc3Reserved = 0x04
}

public enum GapReason: UInt8, CaseIterable, Sendable {
    case spoolOverflow = 0x01
    case micConflict = 0x02
    case userDisabled = 0x03
    case lowBattery = 0x04
    case codecError = 0x05
    case transportReset = 0x06
    case powerSave = 0x07
    case silenceSuppressed = 0x08

    /// True when the "gap" is audio the watch intentionally skipped because it was below the
    /// voice-activity threshold. This is known silence reported to save Bluetooth/battery, not
    /// lost audio, so the app must render it as quiet rather than as a gap or error.
    public var isSilence: Bool { self == .silenceSuppressed }
}

public enum StopReason: UInt8, CaseIterable, Sendable {
    case userDisabled = 0x01
    case policy = 0x02
    case error = 0x03
    case shutdown = 0x04
}

public enum AuthStatus: UInt8, CaseIterable, Sendable {
    case ok = 0
    case pendingUserConsent = 1
    case deniedMismatch = 2
    case deniedDisabled = 3
    case invalid = 4
}

public enum AckStatus: UInt8, CaseIterable, Sendable {
    case ok = 0
    case rejected = 1
    case badState = 2
}

public enum RevokeReason: UInt8, CaseIterable, Sendable {
    case userOnWatch = 1
    case appRequested = 2
    case replaced = 3
}

public enum PauseReason: UInt8, CaseIterable, Sendable {
    case lowStorage = 1
    case user = 2
    case policy = 3
}

public enum ReceiverAppState: UInt8, CaseIterable, Sendable {
    case foreground = 1
    case background = 2
    case restored = 3
}

public enum ProtocolErrorCode: UInt8, CaseIterable, Sendable {
    case malformedMessage = 1
    case unauthorized = 2
    case `internal` = 3
    case unsupportedVersion = 4
}
