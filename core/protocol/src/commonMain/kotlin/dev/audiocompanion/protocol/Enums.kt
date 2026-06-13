package dev.audiocompanion.protocol

/**
 * Protocol enums (spec Section 7). Wire fields carry the raw integer so that unknown values
 * from newer firmware are tolerated and re-encoded byte-exactly; each enum offers a
 * `fromRaw` lookup that returns null for unknown values.
 */
enum class ServiceState(val raw: Int) {
    Disabled(0),
    Idle(1),
    AuthorizedIdle(2),
    Streaming(3),
    PausedConflict(4),
    PausedPolicy(5),
    PausedLowBattery(6),
    Error(7),
    PausedPowerSave(8);

    companion object {
        fun fromRaw(raw: Int): ServiceState? = entries.firstOrNull { it.raw == raw }
    }
}

enum class CodecId(val raw: Int) {
    SpeexWideband(0x01),
    Pcm16Debug(0x02),
    OpusReserved(0x03),
    Lc3Reserved(0x04);

    companion object {
        fun fromRaw(raw: Int): CodecId? = entries.firstOrNull { it.raw == raw }
    }
}

enum class GapReason(val raw: Int) {
    SpoolOverflow(0x01),
    MicConflict(0x02),
    UserDisabled(0x03),
    LowBattery(0x04),
    CodecError(0x05),
    TransportReset(0x06),
    PowerSave(0x07),
    SilenceSuppressed(0x08);

    companion object {
        fun fromRaw(raw: Int): GapReason? = entries.firstOrNull { it.raw == raw }
    }
}

enum class StopReason(val raw: Int) {
    UserDisabled(0x01),
    Policy(0x02),
    Error(0x03),
    Shutdown(0x04);

    companion object {
        fun fromRaw(raw: Int): StopReason? = entries.firstOrNull { it.raw == raw }
    }
}

enum class AuthStatus(val raw: Int) {
    Ok(0),
    PendingUserConsent(1),
    DeniedMismatch(2),
    DeniedDisabled(3),
    Invalid(4);

    companion object {
        fun fromRaw(raw: Int): AuthStatus? = entries.firstOrNull { it.raw == raw }
    }
}

enum class AckStatus(val raw: Int) {
    Ok(0),
    Rejected(1),
    BadState(2);

    companion object {
        fun fromRaw(raw: Int): AckStatus? = entries.firstOrNull { it.raw == raw }
    }
}

enum class RevokeReason(val raw: Int) {
    UserOnWatch(1),
    AppRequested(2),
    Replaced(3);

    companion object {
        fun fromRaw(raw: Int): RevokeReason? = entries.firstOrNull { it.raw == raw }
    }
}

enum class PauseReason(val raw: Int) {
    LowStorage(1),
    User(2),
    Policy(3);

    companion object {
        fun fromRaw(raw: Int): PauseReason? = entries.firstOrNull { it.raw == raw }
    }
}

enum class ReceiverAppState(val raw: Int) {
    Foreground(1),
    Background(2),
    Restored(3);

    companion object {
        fun fromRaw(raw: Int): ReceiverAppState? = entries.firstOrNull { it.raw == raw }
    }
}

enum class ProtocolErrorCode(val raw: Int) {
    MalformedMessage(1),
    Unauthorized(2),
    Internal(3),
    UnsupportedVersion(4);

    companion object {
        fun fromRaw(raw: Int): ProtocolErrorCode? = entries.firstOrNull { it.raw == raw }
    }
}
