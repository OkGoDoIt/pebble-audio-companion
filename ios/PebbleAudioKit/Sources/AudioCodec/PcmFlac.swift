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
    /// FLAC's STREAMINFO block carries the total sample count and an MD5 of the decoded audio,
    /// both of which the encoder patches back into the header after the last frame, so it needs
    /// a seekable sink. That sink is memory (`encodeInMemory`): the caller is about to hold the
    /// whole stream as `Data` anyway, and a temp file meant every 15-minute segment transcribed
    /// in-process wrote ~11 MB to flash only to read it straight back. With charger passes and
    /// re-hearing that was a large part of the 1 GB+ a day iOS reported (disk-write exception,
    /// 2026-11-27). If Core Audio refuses the in-memory sink the temp file still does the job.
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
            if let encoded = try? encodeInMemory(
                pcm: pcm, frameCount: frameCount, sampleRateHz: sampleRateHz)
            {
                return encoded
            }
            return try encodeThroughFile(pcm: pcm, frameCount: frameCount, sampleRateHz: sampleRateHz)
        #else
            throw Failure.unavailable
        #endif
    }

    #if canImport(AudioToolbox)
        private static func outputFormat(sampleRateHz: Int) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: Double(sampleRateHz),
                mFormatID: kAudioFormatFLAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0)
        }

        /// Hands the samples to an open encoder.
        private static func write(
            pcm: Data, frameCount: Int, sampleRateHz: Int, to file: ExtAudioFileRef
        ) throws {
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
        }

        /// The failure mode documented on `minimumFrames` returned `noErr` from every call, so a
        /// status check alone would not have caught it and would not catch the next one. The
        /// only trustworthy question is whether the bytes are a FLAC stream.
        private static func verified(_ encoded: Data) throws -> Data {
            guard encoded.prefix(4).elementsEqual("fLaC".utf8) else {
                throw Failure.invalidOutput(bytes: encoded.count)
            }
            return encoded
        }

        /// The encoder's sink, as bytes in memory.
        private final class MemorySink {
            var bytes = Data()
        }

        /// Where the converter's input callback is in the samples.
        private final class PcmFeed {
            let base: UnsafeRawPointer
            let byteCount: Int
            var offset = 0
            init(base: UnsafeRawPointer, byteCount: Int) {
                self.base = base
                self.byteCount = byteCount
            }
        }

        /// Packets asked of the converter per call: 8 blocks is 2 s at 16 kHz.
        private static let packetsPerFill: UInt32 = 8

        /// Encodes into memory: an `AudioConverter` makes the FLAC packets and Audio File
        /// Services lays them out as a `.flac` stream in a file backed by callbacks.
        ///
        /// Not `ExtAudioFile` over that file, which would be the same few lines as the temp-file
        /// path: wrapped for writing it reports an empty data format and refuses the client
        /// format (-50, macOS 27.2).
        static func encodeInMemory(pcm: Data, frameCount: Int, sampleRateHz: Int) throws -> Data {
            var input = clientFormat(sampleRateHz: sampleRateHz)
            var output = outputFormat(sampleRateHz: sampleRateHz)
            var made: AudioConverterRef?
            try check("converter", AudioConverterNew(&input, &output, &made))
            guard let converter = made else { throw Failure.coreAudio(step: "converter", status: -1) }
            defer { AudioConverterDispose(converter) }

            // The converter fills in what the encoder settled on; the file is made from that.
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                "outputFormat",
                AudioConverterGetProperty(
                    converter, kAudioConverterCurrentOutputStreamDescription, &size, &output))
            var maxPacketBytes: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try check(
                "packetSize",
                AudioConverterGetProperty(
                    converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacketBytes))
            guard maxPacketBytes > 0 else { throw Failure.coreAudio(step: "packetSize", status: -1) }

            let sink = MemorySink()
            var opened: AudioFileID?
            try check(
                "create",
                AudioFileInitializeWithCallbacks(
                    Unmanaged.passUnretained(sink).toOpaque(),
                    { client, position, count, buffer, actual in
                        let sink = Unmanaged<MemorySink>.fromOpaque(client).takeUnretainedValue()
                        let start = Int(position)
                        guard start >= 0, start <= sink.bytes.count else {
                            actual.pointee = 0
                            return kAudioFilePositionError
                        }
                        let length = min(Int(count), sink.bytes.count - start)
                        if length > 0 {
                            sink.bytes.copyBytes(
                                to: buffer.assumingMemoryBound(to: UInt8.self),
                                from: start..<(start + length))
                        }
                        actual.pointee = UInt32(length)
                        return noErr
                    },
                    { client, position, count, buffer, actual in
                        let sink = Unmanaged<MemorySink>.fromOpaque(client).takeUnretainedValue()
                        let start = Int(position)
                        guard start >= 0 else {
                            actual.pointee = 0
                            return kAudioFilePositionError
                        }
                        let end = start + Int(count)
                        // A write past the end leaves zeros between, as a file would.
                        if end > sink.bytes.count { sink.bytes.count = end }
                        sink.bytes.replaceSubrange(
                            start..<end, with: UnsafeRawBufferPointer(start: buffer, count: Int(count)))
                        actual.pointee = count
                        return noErr
                    },
                    { client in
                        Int64(Unmanaged<MemorySink>.fromOpaque(client).takeUnretainedValue().bytes.count)
                    },
                    { client, size in
                        guard size >= 0 else { return kAudioFilePositionError }
                        Unmanaged<MemorySink>.fromOpaque(client).takeUnretainedValue().bytes.count = Int(size)
                        return noErr
                    },
                    kAudioFileFLACType, &output, [], &opened))
            guard let file = opened else { throw Failure.coreAudio(step: "create", status: -1) }
            var closed = false
            defer { if !closed { AudioFileClose(file) } }

            // STREAMINFO travels as the converter's magic cookie: given once so the header is
            // laid down, and again after the last packet, when it holds the sample count and MD5.
            func writeCookie(_ step: String) throws {
                var cookieSize: UInt32 = 0
                guard
                    AudioConverterGetPropertyInfo(
                        converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr,
                    cookieSize > 0
                else { throw Failure.coreAudio(step: step, status: -1) }
                var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
                try check(
                    step,
                    AudioConverterGetProperty(
                        converter, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie))
                try check(
                    step,
                    AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, cookieSize, cookie))
            }
            try writeCookie("cookie")

            try pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { throw Failure.emptyAudio }
                let feed = PcmFeed(base: base, byteCount: frameCount * 2)
                let capacity = Int(maxPacketBytes * packetsPerFill)
                let packets = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
                defer { packets.deallocate() }
                var descriptions = [AudioStreamPacketDescription](
                    repeating: AudioStreamPacketDescription(), count: Int(packetsPerFill))
                var packetIndex: Int64 = 0
                while true {
                    var count = packetsPerFill
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1, mDataByteSize: UInt32(capacity), mData: packets))
                    try check(
                        "convert",
                        AudioConverterFillComplexBuffer(
                            converter,
                            { _, ioPackets, ioData, _, user in
                                guard let user else { return kAudio_ParamError }
                                let feed = Unmanaged<PcmFeed>.fromOpaque(user).takeUnretainedValue()
                                // Fewer than asked, then none: none is the end of the audio.
                                let frames = min(
                                    Int(ioPackets.pointee), (feed.byteCount - feed.offset) / 2)
                                ioData.pointee.mNumberBuffers = 1
                                ioData.pointee.mBuffers.mNumberChannels = 1
                                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                                    mutating: feed.base + feed.offset)
                                ioData.pointee.mBuffers.mDataByteSize = UInt32(frames * 2)
                                feed.offset += frames * 2
                                ioPackets.pointee = UInt32(frames)
                                return noErr
                            },
                            Unmanaged.passUnretained(feed).toOpaque(), &count, &list, &descriptions))
                    if count == 0 { break }
                    var written = count
                    try check(
                        "write",
                        AudioFileWritePackets(
                            file, false, list.mBuffers.mDataByteSize, descriptions, packetIndex,
                            &written, packets))
                    guard written == count else { throw Failure.coreAudio(step: "write", status: -1) }
                    packetIndex += Int64(written)
                }
                // Every sample must have gone in: a stream that stops short still starts "fLaC".
                guard feed.offset == feed.byteCount else {
                    throw Failure.coreAudio(step: "convert", status: -1)
                }
            }
            try writeCookie("finalCookie")
            try check("close", AudioFileClose(file))
            closed = true
            // `sink` is only borrowed by the callbacks; it must outlive the close above.
            return try withExtendedLifetime(sink) { try verified(sink.bytes) }
        }

        /// Encodes through a temp file: the fallback, and the reference the in-memory path is
        /// tested against. The file lives in `tmp/`, so the one case that can leave it behind,
        /// the process being killed mid-encode, is reclaimed by the system.
        static func encodeThroughFile(pcm: Data, frameCount: Int, sampleRateHz: Int) throws -> Data {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pebble-flac-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: url) }

            var output = outputFormat(sampleRateHz: sampleRateHz)
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

            try write(pcm: pcm, frameCount: frameCount, sampleRateHz: sampleRateHz, to: file)
            // Dispose before reading: the encoder flushes its last frame and rewrites STREAMINFO
            // on close, so the file is not complete until then. `defer` would read it too early.
            ExtAudioFileDispose(file)
            disposed = true
            return try verified(try Data(contentsOf: url))
        }
    #endif

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
