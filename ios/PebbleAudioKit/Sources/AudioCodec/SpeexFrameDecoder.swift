import CSpeex
import Foundation

/// Errors from the audio-codec layer. Mirrors the KMP
/// `TranscriptionException.TranscriptionFailed` semantics for the decode path: any frame that
/// fails to decode aborts the whole stream with a descriptive message.
public enum AudioCodecError: Error, Equatable, Sendable {
    case transcriptionFailed(String)
}

/// Decodes firmware Speex wideband frames to bounded PCM16 chunks for transcription.
///
/// Port of the KMP `SpeexFrameDecoder` (commonMain expect + android/ios actuals). Audio Companion
/// STREAM_DATA frames carry raw output from PebbleOS `voice_speex_encode_frame()`: fixed-point
/// wideband (`speex_wb_mode`), 16 kHz, quality 6, 9800 bps CBR, 320 samples per frame, one frame
/// per `speex_bits_reset` — and, unlike the official dictation path, no extra frame-quality
/// header byte.
///
/// The class itself holds only immutable configuration and is `Sendable`. Every `decode` call
/// creates its own private Speex decoder state (matching the KMP actuals, which build a fresh
/// `SpeexCodec` per flow collection); that underlying state is single-threaded, so one decode
/// pass never shares it with anything else.
public final class SpeexFrameDecoder: Sendable {
    /// Default bounded-chunk size: 1 s of s16le mono at 16 kHz (32 000 bytes).
    public static let defaultPcmChunkBytes = 16_000 * MemoryLayout<Int16>.size

    public let sampleRateHz: Int
    /// Encoder-side bit rate; the CBR bitstream is self-describing so the decoder does not need
    /// it, but it is kept for configuration parity with the KMP constructor.
    public let bitRateBps: Int
    public let frameSamples: Int
    public let hasHeaderByte: Bool

    public init(
        sampleRateHz: Int = 16_000,
        bitRateBps: Int = 9_800,
        frameSamples: Int = 320,
        hasHeaderByte: Bool = false
    ) {
        self.sampleRateHz = sampleRateHz
        self.bitRateBps = bitRateBps
        self.frameSamples = frameSamples
        self.hasHeaderByte = hasHeaderByte
    }

    /// Decodes `frames` into bounded PCM chunks. Every emitted chunk except the last is exactly
    /// `pcmChunkBytes` long; the final chunk carries the remainder (only if non-empty).
    public func decode(
        frames: [Data],
        pcmChunkBytes: Int = SpeexFrameDecoder.defaultPcmChunkBytes
    ) throws -> [Data] {
        guard pcmChunkBytes > 0 else {
            throw AudioCodecError.transcriptionFailed("pcmChunkBytes must be positive")
        }
        let session = try makeSession()
        var chunks: [Data] = []
        var pending = Data()
        for frame in frames {
            pending.append(try session.decodeFrame(frame))
            while pending.count >= pcmChunkBytes {
                chunks.append(pending.prefix(pcmChunkBytes))
                pending.removeFirst(pcmChunkBytes)
            }
        }
        if !pending.isEmpty {
            chunks.append(pending)
        }
        return chunks
    }

    /// Convenience for callers that want the whole decoded stream as one buffer.
    public func decodeAll(frames: [Data]) throws -> Data {
        var out = Data()
        for chunk in try decode(frames: frames) {
            out.append(chunk)
        }
        return out
    }

    /// Streaming variant mirroring the KMP `Flow<ByteArray> -> Flow<ByteArray>` shape: consumes
    /// frames as they arrive (e.g. the live-audio path) and yields bounded PCM chunks. A frame
    /// that fails to decode finishes the stream with `AudioCodecError.transcriptionFailed`.
    public func decode<S: AsyncSequence>(
        frames: S,
        pcmChunkBytes: Int = SpeexFrameDecoder.defaultPcmChunkBytes
    ) -> AsyncThrowingStream<Data, Error> where S.Element == Data {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard pcmChunkBytes > 0 else {
                        throw AudioCodecError.transcriptionFailed("pcmChunkBytes must be positive")
                    }
                    let session = try self.makeSession()
                    var pending = Data()
                    for try await frame in frames {
                        try Task.checkCancellation()
                        pending.append(try session.decodeFrame(frame))
                        while pending.count >= pcmChunkBytes {
                            continuation.yield(pending.prefix(pcmChunkBytes))
                            pending.removeFirst(pcmChunkBytes)
                        }
                    }
                    if !pending.isEmpty {
                        continuation.yield(pending)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession() throws -> SpeexDecodeSession {
        try SpeexDecodeSession(
            sampleRateHz: sampleRateHz,
            frameSamples: frameSamples,
            hasHeaderByte: hasHeaderByte
        )
    }
}

/// One decode pass over a Speex stream. Owns the libspeex decoder state and bit reader; NOT
/// thread-safe — confine each instance to a single decode loop.
private final class SpeexDecodeSession {
    private let state: UnsafeMutableRawPointer
    private var bits = SpeexBits()
    private let frameSamples: Int
    private let hasHeaderByte: Bool

    init(sampleRateHz: Int, frameSamples: Int, hasHeaderByte: Bool) throws {
        let modeId: Int32
        switch sampleRateHz {
        case 8_000: modeId = SPEEX_MODEID_NB
        case 16_000: modeId = SPEEX_MODEID_WB
        case 32_000: modeId = SPEEX_MODEID_UWB
        default:
            throw AudioCodecError.transcriptionFailed(
                "unsupported Speex sample rate: \(sampleRateHz)")
        }
        guard let mode = speex_lib_get_mode(modeId),
              let state = speex_decoder_init(mode)
        else {
            throw AudioCodecError.transcriptionFailed("failed to initialize Speex decoder")
        }

        var rate = Int32(sampleRateHz)
        speex_decoder_ctl(state, SPEEX_SET_SAMPLING_RATE, &rate)
        var actualFrameSamples: Int32 = 0
        speex_decoder_ctl(state, SPEEX_GET_FRAME_SIZE, &actualFrameSamples)
        guard actualFrameSamples == Int32(frameSamples) else {
            speex_decoder_destroy(state)
            throw AudioCodecError.transcriptionFailed(
                "Speex frame size mismatch: configured \(frameSamples), "
                    + "codec produces \(actualFrameSamples)")
        }

        self.state = state
        self.frameSamples = frameSamples
        self.hasHeaderByte = hasHeaderByte
        speex_bits_init(&bits)
    }

    deinit {
        speex_bits_destroy(&bits)
        speex_decoder_destroy(state)
    }

    /// Decodes one encoded frame to `frameSamples` samples of s16le PCM.
    func decodeFrame(_ frame: Data) throws -> Data {
        let payload = hasHeaderByte ? frame.dropFirst() : frame[...]
        guard !payload.isEmpty else {
            throw AudioCodecError.transcriptionFailed("failed to decode Speex frame: EmptyFrame")
        }
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let chars = raw.bindMemory(to: CChar.self)
            speex_bits_read_from(&bits, chars.baseAddress, Int32(chars.count))
        }
        var samples = [Int16](repeating: 0, count: frameSamples)
        let rc = samples.withUnsafeMutableBufferPointer { buffer in
            speex_decode_int(state, &bits, buffer.baseAddress)
        }
        guard rc == 0 else {
            throw AudioCodecError.transcriptionFailed(
                "failed to decode Speex frame: \(Self.describe(rc))")
        }
        var out = [UInt8](repeating: 0, count: frameSamples * 2)
        for i in 0..<frameSamples {
            let v = UInt16(bitPattern: samples[i])
            out[2 * i] = UInt8(v & 0xFF)
            out[2 * i + 1] = UInt8(v >> 8)
        }
        return Data(out)
    }

    private static func describe(_ rc: Int32) -> String {
        switch rc {
        case -1: return "EndOfStream"
        case -2: return "CorruptStream"
        default: return "code \(rc)"
        }
    }
}
