package dev.audiocompanion.protocol

/**
 * Constants from `spec/audio-companion-protocol.md` (version 1). That document is normative;
 * if this file and the spec disagree, the spec wins.
 */
object ProtocolConstants {
    const val PROTOCOL_VERSION: Int = 1

    const val MAX_ENCODED_FRAME_BYTES: Int = 200
    const val DEFAULT_FRAME_SAMPLES: Int = 320
    const val DEFAULT_SAMPLE_RATE_HZ: Int = 16000
    const val DEFAULT_FRAME_DURATION_MS: Int = 20
    const val DEFAULT_BIT_RATE_BPS: Int = 9800
    const val MAX_FRAMES_PER_DATA_MSG: Int = 32
    const val MAX_RECEIVER_NAME_BYTES: Int = 24
    const val CONSENT_TIMEOUT_SECONDS: Int = 60

    const val RECEIVER_ID_BYTES: Int = 32
    const val INFO_SNAPSHOT_BYTES: Int = 20

    // GATT identifiers (Section 1). Base UUID is third-party-owned, deliberately not Pebble's.
    const val BASE_UUID: String = "7C2B0000-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    const val SERVICE_UUID: String = "7C2B0001-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    const val INFO_CHARACTERISTIC_UUID: String = "7C2B0002-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    const val CONTROL_CHARACTERISTIC_UUID: String = "7C2B0003-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    const val DATA_CHARACTERISTIC_UUID: String = "7C2B0004-9E4D-4FC2-A2B3-1D6E8A1C9F50"

    // Info characteristic flag bits (Section 3).
    const val INFO_FLAG_RECEIVER_AUTHORIZED: Int = 1 shl 0
    const val INFO_FLAG_ENABLED: Int = 1 shl 1
    const val INFO_FLAG_CONSENT_PENDING: Int = 1 shl 2

    // Info characteristic codec bitmap bits (Section 3).
    const val CODEC_BITMAP_SPEEX_WIDEBAND: Int = 1 shl 0

    // CHECKPOINT receiver_flags bits (Section 4.1).
    const val RECEIVER_FLAG_LOW_STORAGE: UInt = 1u
    const val RECEIVER_FLAG_PAUSE_REQUESTED: UInt = 2u
}

/** One-byte message ids (Sections 4 and 5). */
object MessageId {
    // Phone -> watch control writes (0x01-0x3F).
    const val AUTH_REQUEST: Int = 0x01
    const val AUTH_REVOKE: Int = 0x02
    const val CHECKPOINT: Int = 0x03
    const val PAUSE_REQUEST: Int = 0x04
    const val RESUME_REQUEST: Int = 0x05
    const val RECEIVER_HEALTH: Int = 0x06

    // Watch -> phone control notifications (0x41-0x7F).
    const val AUTH_RESULT: Int = 0x41
    const val REVOKED: Int = 0x42
    const val ACK: Int = 0x43
    const val STATE_CHANGED: Int = 0x44
    const val ERROR: Int = 0x45

    // Watch -> phone data notifications (0x80-0x9F).
    const val STREAM_START: Int = 0x80
    const val STREAM_DATA: Int = 0x81
    const val STREAM_GAP: Int = 0x82
    const val STREAM_STOP: Int = 0x83
}
