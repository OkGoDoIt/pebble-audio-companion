import CSpeex
import Foundation

// The encode half of the vendored Speex, and the one frame the app needs from it.
//
// The app never records: every frame it stores was encoded on the watch. The encoder is here
// for a single purpose — producing a VALID frame of silence in the watch's own bitstream, so a
// stretch of a stored segment can be silenced in place (`SegmentStore.silenceAudio`) instead of
// cut out. Cutting frames out would shift every later media offset in the segment, and the
// transcript's turn and word timings, the follow-up sources and the conversation cuts are all
// offsets into that clock. A silence frame occupies exactly the 20 ms the frame it replaces
// did, so nothing that indexes the stored audio moves.
//
// It has to be a real encoded frame and not zero bytes: a Speex frame of zeros is a bitstream
// the decoder reads as mode bits, not as silence — it decodes to garbage or fails the whole
// stream (`AudioCodecError.transcriptionFailed`), which would take the neighbouring
// conversation's audio down with the deleted one.

/// Encodes PCM16 with the firmware's Speex configuration (`voice_speex.c`): wideband, fixed
/// point, quality 6 then a 9800 bps bit-rate cap, complexity 1, CBR, 320-sample frames, one
/// frame per `speex_bits_reset`, no header byte.
///
/// Owns libspeex encoder state, so it is NOT thread-safe and deliberately not `Sendable`:
/// confine an instance to one encode loop, as `SpeexDecodeSession` is confined to one decode.
public final class SpeexFrameEncoder {
    /// Samples per frame the codec consumes (320 for wideband: 20 ms at 16 kHz).
    public let frameSamples: Int

    private let state: UnsafeMutableRawPointer
    private var bits = SpeexBits()

    /// The defaults are the recorder's. The order of the control calls below is the firmware's
    /// and matters: `SPEEX_SET_BITRATE` lowers the quality chosen just before it to the highest
    /// one that fits the rate, which is what makes a "quality 6" stream 25 bytes a frame.
    public init(
        sampleRateHz: Int = 16_000,
        bitRateBps: Int = 9_800,
        quality: Int = 6,
        complexity: Int = 1
    ) throws {
        let modeId: Int32
        switch sampleRateHz {
        case 8_000: modeId = SPEEX_MODEID_NB
        case 16_000: modeId = SPEEX_MODEID_WB
        case 32_000: modeId = SPEEX_MODEID_UWB
        default:
            throw AudioCodecError.transcriptionFailed(
                "unsupported Speex sample rate: \(sampleRateHz)")
        }
        guard let mode = speex_lib_get_mode(modeId), let state = speex_encoder_init(mode) else {
            throw AudioCodecError.transcriptionFailed("failed to initialize Speex encoder")
        }
        var value = Int32(quality)
        speex_encoder_ctl(state, SPEEX_SET_QUALITY, &value)
        value = Int32(complexity)
        speex_encoder_ctl(state, SPEEX_SET_COMPLEXITY, &value)
        value = Int32(sampleRateHz)
        speex_encoder_ctl(state, SPEEX_SET_SAMPLING_RATE, &value)
        value = Int32(bitRateBps)
        speex_encoder_ctl(state, SPEEX_SET_BITRATE, &value)
        var frameSize: Int32 = 0
        speex_encoder_ctl(state, SPEEX_GET_FRAME_SIZE, &frameSize)
        guard frameSize > 0 else {
            speex_encoder_destroy(state)
            throw AudioCodecError.transcriptionFailed("Speex encoder reported no frame size")
        }
        self.state = state
        self.frameSamples = Int(frameSize)
        speex_bits_init(&bits)
    }

    deinit {
        speex_bits_destroy(&bits)
        speex_encoder_destroy(state)
    }

    /// Encodes exactly one frame (`frameSamples` samples) and returns its payload — the bytes
    /// the watch would put in one STREAM_DATA frame entry.
    public func encodeFrame(_ samples: [Int16]) throws -> Data {
        guard samples.count == frameSamples else {
            throw AudioCodecError.transcriptionFailed(
                "Speex frame size mismatch: given \(samples.count), codec takes \(frameSamples)")
        }
        // The encoder writes its analysis back into the input buffer, so it gets a copy.
        var input = samples
        speex_bits_reset(&bits)
        _ = input.withUnsafeMutableBufferPointer { buffer in
            speex_encode_int(state, buffer.baseAddress, &bits)
        }
        var out = [CChar](repeating: 0, count: Self.maxFrameBytes)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            speex_bits_write(&bits, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else {
            throw AudioCodecError.transcriptionFailed("Speex encoder produced no bytes")
        }
        return Data(out.prefix(Int(written)).map { UInt8(bitPattern: $0) })
    }

    /// Generous: the largest frame any Speex mode produces is well under this.
    private static let maxFrameBytes = 320
}

/// The payload that replaces a deleted stretch of stored audio: 20 ms of digital silence in the
/// recorder's bitstream.
public enum SpeexSilence {
    /// One valid Speex frame that decodes to silence, for a stream with this configuration.
    /// For the recorder's (16 kHz, 9800 bps) it is 25 bytes, the size of every frame the watch
    /// sends, so a log with silenced frames stays the size it was.
    ///
    /// It is what a fresh encoder makes of 320 zero samples. On zero input the encoder has no
    /// start-up to get through — its first frame and its hundredth are the same bytes
    /// (`SpeexSilenceTests`) — so one frame can stand for any number in a row. A decoder that
    /// was just playing speech does not echo it into the silence either: measured on the
    /// firmware fixture, the first silenced frame still carries the codec's own delay, the
    /// second and third ring at a few LSB, and from the fifth on every sample is exactly zero.
    ///
    /// The cost is on the far side. Speex predicts each frame from the ones before it, so real
    /// audio that resumes straight after a silenced stretch decodes quieter than it was
    /// recorded for roughly half a second while the decoder's history catches up — the same
    /// thing that already happens after every gap in a stream. Conversations are cut between
    /// turns, ahead of the first word, so that half second is normally the pause before it.
    ///
    /// Encoded once per configuration and kept.
    public static func frame(sampleRateHz: Int = 16_000, bitRateBps: Int = 9_800) throws -> [UInt8] {
        let key = Key(sampleRateHz: sampleRateHz, bitRateBps: bitRateBps)
        if let cached = cache.value(for: key) { return cached }
        let encoder = try SpeexFrameEncoder(sampleRateHz: sampleRateHz, bitRateBps: bitRateBps)
        let zeros = [Int16](repeating: 0, count: encoder.frameSamples)
        let bytes = [UInt8](try encoder.encodeFrame(zeros))
        cache.store(bytes, for: key)
        return bytes
    }

    private struct Key: Hashable {
        var sampleRateHz: Int
        var bitRateBps: Int
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Key: [UInt8]] = [:]

        func value(for key: Key) -> [UInt8]? { lock.withLock { frames[key] } }
        func store(_ frame: [UInt8], for key: Key) { lock.withLock { frames[key] = frame } }
    }

    private static let cache = Cache()
}
