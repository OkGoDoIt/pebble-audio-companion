import Foundation

#if canImport(AudioToolbox)
    import AudioToolbox
#endif

// Lossless compression for the bytes that leave the phone.
//
// WHY THIS EXISTS. The cloud upload path wrapped every segment in an uncompressed RIFF/WAVE body
// (`PcmWav.encodeMono16`) and posted it. Measured over this user's real library — 88 days, 765
// spooled segments, 116.5 h of audio — that is **12.38 GB uploaded for 0.818 GB of Speex that
// actually arrived over BLE: a 16.4x expansion, 141 MB/day.** Nothing about the transcript needs
// those bytes: the audio is 16 kHz mono PCM16 and FLAC stores it *exactly*, at 28-30% of the size,
// measured on three real segments from that library (see `PcmFlacTests`).
//
// WHY FLAC AND NOT A LOSSY CODEC. The audio has already been through Speex-WB CELP at 9,800 bps on
// the watch. Transcoding lossy-onto-lossy would change the samples the recognizer sees, and this
// product cannot trade transcript accuracy for bytes — stream HS measured 5% of the corpus as
// provider confabulation *already*. FLAC is lossless: the decoder returns the identical samples,
// so the provider sees exactly what it sees today and the change is a pure size win. That is
// proved rather than asserted — `PcmFlacTests` round-trips real segments and compares every byte,
// and the same files were independently decoded with ffmpeg's libFLAC to the same SHA-256.
//
// WHY NOTHING IS VENDORED. iOS ships the encoder: `ACFLACEncoder` lives in
// `AudioToolbox.framework/AudioCodecs` and `FLACAudioFile::WritePackets` in AudioToolboxCore, both
// verified present in the iOS 26.5 runtime. `ExtAudioFile` reaches them with an integer client
// format, so the PCM never passes through float and cannot be rounded on the way.
//
// The provider format lists were checked against the live documentation, not assumed:
//   - Soniox async accepts "aac, aiff, amr, asf, flac, mp3, ogg, wav, webm, m4a, mp4" and
//     "automatically detects audio formats for file transcription"
//     (https://soniox.com/docs/stt/async/async-transcription).
//   - OpenAI's OpenAPI spec v2.3.0 (`openai/openai-openapi`, `CreateTranscriptionRequest.file`)
//     says "in one of these formats: flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, or webm", and
//     asks for "an extension-bearing filename and an appropriate content type" — which is what
//     `CloudAudioFormat` supplies. NOTE the prose guide at developers.openai.com currently lists a
//     SHORTER set without flac; the spec is the contract the endpoint validates against, but that
//     disagreement is why the format is a per-provider constant and not a global one.

/// Container the cloud upload path assembles a segment's audio into.
///
/// Which one a given path uses is a constant, not a negotiation: `CloudUploadFormats.passthrough`
/// for a background upload that has the watch's own frames, `.fromPcm` for the synchronous path
/// that only has decoded PCM. WAV remains the floor every provider documents.
public enum CloudAudioFormat: String, Sendable, Equatable, CaseIterable, Codable {
    /// Raw PCM16 in a RIFF/WAVE wrapper. 32,000 B/s at 16 kHz; the original behaviour.
    case wav
    /// Lossless compression of the same samples. 30-45% of the WAV, content-dependent.
    case flac
    /// The watch's own Speex frames in an Ogg container — no decode, no re-encode. A
    /// deterministic **4.08%** of the WAV. See `OggSpeex`.
    case oggSpeex

    /// Multipart `Content-Type` for the file part.
    public var contentType: String {
        switch self {
        case .wav: return "audio/wav"
        case .flac: return "audio/flac"
        // RFC 5574 registers `audio/speex`, but `audio/ogg` with a `.ogg` extension is the pairing
        // a generic (ffmpeg-shaped) demuxer is likeliest to route correctly, and both providers
        // list `ogg` as a container rather than naming codecs.
        case .oggSpeex: return "audio/ogg"
        }
    }

    /// Extension for the multipart `filename`. Both providers use it to sniff the format.
    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .flac: return "flac"
        case .oggSpeex: return "ogg"
        }
    }

    /// Whether a provider has *documented* accepting this container.
    ///
    /// Load-bearing for how a rejection is classified, not cosmetic. Soniox lists `flac`/`wav` and
    /// OpenAI's OpenAPI spec lists both; neither vendor mentions Speex anywhere, so `.oggSpeex` is
    /// an educated bet on an ffmpeg-shaped ingest — one settled by posting a real segment to both
    /// production endpoints (see `CloudUploadFormats.passthrough`). Kept because it is the honest
    /// label for where the vendor docs stop and our own measurement starts.
    public var isDocumentedByProviders: Bool { self != .oggSpeex }
}

/// The audio bytes to upload, and what they actually are.
///
/// `format` reports what was *produced*, not what was requested: when FLAC encoding is
/// unavailable or fails, `encode` degrades to `.wav` rather than dropping the segment, and the
/// caller then labels the part honestly. A failure to compress must never cost a transcript.
public struct CloudAudioBody: Sendable, Equatable {
    public let bytes: Data
    public let format: CloudAudioFormat

    public init(bytes: Data, format: CloudAudioFormat) {
        self.bytes = bytes
        self.format = format
    }

    public var contentType: String { format.contentType }

    /// `filename("segment")` -> `"segment.flac"`.
    public func filename(_ base: String) -> String { "\(base).\(format.fileExtension)" }

    /// Packages already-encoded Speex frames with no decode and no re-encode — the cheapest and
    /// smallest rung of the ladder. Throws rather than degrading, so the caller decides what to
    /// do next (`SegmentAudio.package` walks down to FLAC).
    public static func passthrough(
        speexFrames: [Data],
        sampleRateHz: Int,
        frameSamples: Int,
        bitRateBps: Int
    ) throws -> CloudAudioBody {
        CloudAudioBody(
            bytes: try OggSpeex.encode(
                frames: speexFrames, sampleRateHz: sampleRateHz, frameSamples: frameSamples,
                bitRateBps: bitRateBps),
            format: .oggSpeex)
    }

    /// Encodes raw s16le mono PCM into `format`, falling back to WAV on any encoder failure.
    ///
    /// `.oggSpeex` is not reachable from PCM — packaging the watch's frames is the whole point of
    /// it, and re-encoding decoded audio back to Speex would be tandem coding for no gain — so it
    /// resolves to WAV here, honestly labelled. Callers that can supply frames use `passthrough`.
    public static func encode(
        pcm: Data,
        sampleRateHz: Int,
        format: CloudAudioFormat,
        onFallback: ((Error) -> Void)? = nil
    ) -> CloudAudioBody {
        guard format == .flac else {
            return CloudAudioBody(
                bytes: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: sampleRateHz), format: .wav)
        }
        do {
            return CloudAudioBody(
                bytes: try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: sampleRateHz),
                format: .flac)
        } catch {
            onFallback?(error)
            return CloudAudioBody(
                bytes: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: sampleRateHz), format: .wav)
        }
    }

    /// Encodes an already-assembled `PcmWav` body — the shape the background upload path holds
    /// (`SegmentAudio.wav`).
    ///
    /// `.wav` returns the input untouched, so the previous wire bytes are byte-identical and not
    /// merely equivalent. `.flac` re-encodes the PCM payload; the RIFF header is dropped because
    /// FLAC carries the sample rate and channel count in its own STREAMINFO block.
    public static func encode(
        wav: Data,
        sampleRateHz: Int,
        format: CloudAudioFormat,
        onFallback: ((Error) -> Void)? = nil
    ) -> CloudAudioBody {
        guard format == .flac else { return CloudAudioBody(bytes: wav, format: .wav) }
        do {
            return CloudAudioBody(
                bytes: try PcmFlac.encodeMono16(
                    pcm: PcmWav.pcmBody(of: wav), sampleRateHz: sampleRateHz),
                format: .flac)
        } catch {
            onFallback?(error)
            return CloudAudioBody(bytes: wav, format: .wav)
        }
    }
}

/// FLAC encoding for s16le mono PCM, via the FLAC encoder iOS already ships.
public enum PcmFlac {
    public enum Failure: Error, Equatable {
        /// No FLAC encoder on this platform. Callers fall back to WAV.
        case unavailable
        /// Nothing to encode (fewer than one whole 16-bit frame).
        case emptyAudio
        /// Shorter than one encoder block — see `minimumFrames`.
        case audioTooShort(frames: Int, minimum: Int)
        /// The encoder returned bytes that are not a FLAC stream. Should be unreachable; it is
        /// checked anyway because the failure mode it guards is silent (see `minimumFrames`).
        case invalidOutput(bytes: Int)
        /// Core Audio said no; the string names the step so a report is diagnosable.
        case coreAudio(step: String, status: Int32)
    }

    /// Encoder block size, in frames. 4096 is libFLAC's own default for 16 kHz-and-up material
    /// and is what Apple's encoder expects to be told; it is not a quality knob (FLAC is
    /// lossless at every block size) but it does set the frame overhead.
    static let framesPerPacket: UInt32 = 4096

    /// Below one whole block, Apple's writer produces a **corrupt file rather than an error**.
    ///
    /// Measured directly against the iOS/macOS encoder: at 1, 320, 1,000 and 4,095 frames every
    /// call returns `noErr` at every step and leaves a 42-byte file whose first four bytes are
    /// `00 00 00 00` — the STREAMINFO block is laid out correctly but the `fLaC` magic was never
    /// written and no audio frame was flushed. At 4,096 and above it is correct, including for
    /// lengths that are not a multiple of the block (the 6-15 minute real segments this shipped
    /// on all round-trip bit-exactly).
    ///
    /// So anything shorter is refused here and the caller sends WAV instead. That costs nothing:
    /// 4,096 frames is 256 ms at 16 kHz, whose WAV is 8 kB. The alternative — shipping 42 bytes
    /// of garbage to a transcription API — would fail the segment, retry it, and fail it again.
    public static var minimumFrames: Int { Int(framesPerPacket) }

    /// Frames handed to the encoder per `ExtAudioFileWrite`. 32k frames is 2 s at 16 kHz — big
    /// enough that the per-call overhead disappears, small enough that nothing is copied twice.
    private static let writeChunkFrames = 32_768

    /// Encodes `pcm` (s16le, mono, `sampleRateHz`) as a native `.flac` stream.
    ///
    /// Goes through a temp file because FLAC's STREAMINFO block carries the total sample count
    /// and an MD5 of the decoded audio, both of which the encoder patches back into the header
    /// after the last frame — that needs a seekable sink. The file is removed before returning;
    /// it is ~30% of the WAV the caller is already holding in memory, so the peak footprint of
    /// this path goes DOWN, not up. It lives in `tmp/`, so the one case that can leave a file
    /// behind — the process being killed mid-encode — is reclaimed by the system rather than
    /// needing the kind of sweep `BackgroundCloudUploadCoordinator` had to grow for `upload-bodies`.
    public static func encodeMono16(pcm: Data, sampleRateHz: Int) throws -> Data {
        #if canImport(AudioToolbox)
            precondition(sampleRateHz > 0, "sampleRateHz must be positive")
            // An odd trailing byte is half a frame; it cannot be a sample and is dropped rather
            // than read past the end of the buffer.
            let frameCount = pcm.count / 2
            guard frameCount > 0 else { throw Failure.emptyAudio }
            guard frameCount >= minimumFrames else {
                throw Failure.audioTooShort(frames: frameCount, minimum: minimumFrames)
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pebble-flac-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: url) }

            var output = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRateHz),
                mFormatID: kAudioFormatFLAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0)

            var ref: ExtAudioFileRef?
            try check(
                "create",
                ExtAudioFileCreateWithURL(
                    url as CFURL, kAudioFileFLACType, &output, nil,
                    AudioFileFlags.eraseFile.rawValue, &ref))
            guard let file = ref else { throw Failure.coreAudio(step: "create", status: -1) }
            // The success path disposes EARLY (see below) and then flips this, because a `defer`
            // capturing `file` would otherwise dispose the same handle a second time — an
            // ordinary double free, and one the tests would very likely not have caught.
            var disposed = false
            defer { if !disposed { ExtAudioFileDispose(file) } }

            // Integer client format: the samples go straight from the spool's PCM16 into the
            // encoder without a float round trip, so "lossless" is lossless end to end.
            var client = clientFormat(sampleRateHz: sampleRateHz)
            try check(
                "clientFormat",
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

            try pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { throw Failure.emptyAudio }
                let samples = base.assumingMemoryBound(to: Int16.self)
                var written = 0
                while written < frameCount {
                    let frames = min(writeChunkFrames, frameCount - written)
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(frames * 2),
                            mData: UnsafeMutableRawPointer(mutating: samples + written)))
                    try check("write", ExtAudioFileWrite(file, UInt32(frames), &list))
                    written += frames
                }
            }
            // Dispose before reading: the encoder flushes its last frame and rewrites STREAMINFO
            // on close, so the file is not complete until then. `defer` would read it too early.
            ExtAudioFileDispose(file)
            disposed = true
            let encoded = try Data(contentsOf: url)
            // Belt and braces for the failure mode documented on `minimumFrames`: that one is
            // now excluded by the guard above, but it returned `noErr` from every call, so a
            // status check alone would not have caught it and would not catch the next one. The
            // only trustworthy question is whether the bytes are a FLAC stream.
            guard encoded.prefix(4).elementsEqual("fLaC".utf8) else {
                throw Failure.invalidOutput(bytes: encoded.count)
            }
            return encoded
        #else
            throw Failure.unavailable
        #endif
    }

    #if canImport(AudioToolbox)
        /// s16le mono, packed — the exact layout of the spool's decoded PCM and of a `PcmWav` body.
        private static func clientFormat(sampleRateHz: Int) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: Double(sampleRateHz),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0)
        }

        private static func check(_ step: String, _ status: OSStatus) throws {
            guard status == noErr else { throw Failure.coreAudio(step: step, status: status) }
        }

        /// Decodes a `.flac` stream back to s16le mono PCM. Test-facing: the round-trip assertion
        /// in `PcmFlacTests` is the whole correctness argument for shipping FLAC, and it has to
        /// run against the real encoder rather than a mock.
        public static func decodeToPcmMono16(flac: Data, sampleRateHz: Int) throws -> Data {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pebble-flac-\(UUID().uuidString).flac")
            try flac.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            var ref: ExtAudioFileRef?
            try check("open", ExtAudioFileOpenURL(url as CFURL, &ref))
            guard let file = ref else { throw Failure.coreAudio(step: "open", status: -1) }
            defer { ExtAudioFileDispose(file) }
            var client = clientFormat(sampleRateHz: sampleRateHz)
            try check(
                "clientFormat",
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

            var out = Data()
            var scratch = [Int16](repeating: 0, count: writeChunkFrames)
            while true {
                var frames = UInt32(writeChunkFrames)
                let status: OSStatus = scratch.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return noErr }
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(writeChunkFrames * 2),
                            mData: UnsafeMutableRawPointer(base)))
                    return ExtAudioFileRead(file, &frames, &list)
                }
                try check("read", status)
                if frames == 0 { break }
                scratch.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    out.append(
                        UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                        count: Int(frames) * 2)
                }
            }
            return out
        }
    #else
        public static func decodeToPcmMono16(flac: Data, sampleRateHz: Int) throws -> Data {
            throw Failure.unavailable
        }
    #endif
}
