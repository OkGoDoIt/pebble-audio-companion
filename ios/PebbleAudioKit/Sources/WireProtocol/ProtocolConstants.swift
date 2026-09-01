/// Constants from `spec/audio-companion-protocol.md` (version 1). That document is normative;
/// if this file and the spec disagree, the spec wins.
/// Port of `core/protocol/.../ProtocolConstants.kt`.
public enum ProtocolConstants {
    public static let protocolVersion: Int = 1

    public static let maxEncodedFrameBytes: Int = 200
    public static let defaultFrameSamples: Int = 320
    public static let defaultSampleRateHz: Int = 16000
    public static let defaultFrameDurationMs: Int = 20
    public static let defaultBitRateBps: Int = 9800
    public static let maxFramesPerDataMsg: Int = 32
    public static let maxReceiverNameBytes: Int = 24
    public static let consentTimeoutSeconds: Int = 60

    public static let receiverIdBytes: Int = 32
    public static let infoSnapshotBytes: Int = 20

    // GATT identifiers (Section 1). Base UUID is third-party-owned, deliberately not Pebble's.
    public static let baseUUID = "7C2B0000-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    public static let serviceUUID = "7C2B0001-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    public static let infoCharacteristicUUID = "7C2B0002-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    public static let controlCharacteristicUUID = "7C2B0003-9E4D-4FC2-A2B3-1D6E8A1C9F50"
    public static let dataCharacteristicUUID = "7C2B0004-9E4D-4FC2-A2B3-1D6E8A1C9F50"

    // Info characteristic flag bits (Section 3).
    public static let infoFlagReceiverAuthorized: Int = 1 << 0
    public static let infoFlagEnabled: Int = 1 << 1
    public static let infoFlagConsentPending: Int = 1 << 2
    /// bit3: `send_backpressure_events` carries a real count. Firmware that predates the field
    /// leaves those bytes zero, which is indistinguishable from "the transport never refused a
    /// notification" without this bit — so a zero is only meaningful when it is set.
    public static let infoFlagBackpressureCounter: Int = 1 << 3

    // Info characteristic codec bitmap bits (Section 3).
    public static let codecBitmapSpeexWideband: Int = 1 << 0

    // CHECKPOINT receiver_flags bits (Section 4.1).
    public static let receiverFlagLowStorage: UInt32 = 1
    public static let receiverFlagPauseRequested: UInt32 = 2

    // STREAM_START flags (Section 5). RESUME marks a re-announcement of an already-running stream
    // to a freshly (re)attached receiver: take the first STREAM_DATA/STREAM_GAP sequence as the
    // contiguity base instead of assuming the stream begins at sequence 0.
    public static let streamStartFlagResume: UInt32 = 1
}

/// One-byte message ids (Sections 4 and 5).
public enum MessageId {
    // Phone -> watch control writes (0x01-0x3F).
    public static let authRequest: Int = 0x01
    public static let authRevoke: Int = 0x02
    public static let checkpoint: Int = 0x03
    public static let pauseRequest: Int = 0x04
    public static let resumeRequest: Int = 0x05
    public static let receiverHealth: Int = 0x06
    public static let enableRequest: Int = 0x07

    // Watch -> phone control notifications (0x41-0x7F).
    public static let authResult: Int = 0x41
    public static let revoked: Int = 0x42
    public static let ack: Int = 0x43
    public static let stateChanged: Int = 0x44
    public static let error: Int = 0x45

    // Watch -> phone data notifications (0x80-0x9F).
    public static let streamStart: Int = 0x80
    public static let streamData: Int = 0x81
    public static let streamGap: Int = 0x82
    public static let streamStop: Int = 0x83
}
