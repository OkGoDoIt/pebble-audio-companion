import Foundation
import Testing

@testable import AudioCodec

// Stream DU. The whole argument for uploading FLAC instead of WAV is "the provider sees the
// identical samples", so these tests prove it rather than assert it — and they prove it on the
// real firmware Speex fixture, i.e. on CELP-decoded audio of exactly the kind the upload path
// carries, not on a synthetic tone that a predictor would find suspiciously easy.
//
// The corpus-scale numbers this shipped on (28.3% / 30.2% / 29.4% of the WAV, on three real
// segments of 6-15 minutes from the user's 88-day library, all three bit-exact after a round trip
// through Apple's encoder AND independently through ffmpeg's libFLAC) cannot live here: the
// library is private and outside the repo. They are recorded in the progress log.

@Suite struct DuPcmFlacTests {
    private static let rate = 16_000

    /// One second of real decoded firmware audio (the `speex_frames_v1` fixture, put through the
    /// app's own vendored libspeex), repeated to `seconds`. This is the actual signal the cloud
    /// path uploads: room noise re-synthesised through a 9.8 kbps CELP vocal-tract model.
    private static func realDecodedPcm(seconds: Int = 1) throws -> Data {
        let frames = SpeexFixture.parseFrames(try SpeexFixture.framesBin())
        let chunks = try SpeexFrameDecoder().decode(frames: frames)
        let one = chunks.reduce(into: Data()) { $0.append($1) }
        var out = Data()
        for _ in 0..<max(1, seconds) { out.append(one) }
        return out
    }

    // MARK: - Correctness

    @Test func flacRoundTripsRealDecodedAudioSampleForSample() throws {
        let pcm = try Self.realDecodedPcm(seconds: 4)
        #expect(pcm.count > 0)

        let flac = try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        let back = try PcmFlac.decodeToPcmMono16(flac: flac, sampleRateHz: Self.rate)

        // Not "close enough" — identical. A lossy codec here would change what the recognizer
        // sees, and this product cannot pay for bytes with transcript accuracy.
        #expect(back == pcm)
    }

    @Test func flacRoundTripsFullScaleAndSilentExtremes() throws {
        // Clipping extremes and a dead-silent run are where an integer/float conversion bug would
        // show up first (Int16.min has no positive counterpart in a naive ±32767 scaling).
        var pcm = Data()
        for value in [Int16.min, Int16.max, 0, -1, 1, Int16.min + 1, Int16.max - 1] {
            for _ in 0..<1_000 {
                pcm.append(UInt8(truncatingIfNeeded: value))
                pcm.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        let flac = try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        #expect(try PcmFlac.decodeToPcmMono16(flac: flac, sampleRateHz: Self.rate) == pcm)
    }

    @Test func producesAStandardFlacStream() throws {
        let flac = try PcmFlac.encodeMono16(
            pcm: try Self.realDecodedPcm(), sampleRateHz: Self.rate)
        // `fLaC`. Both providers sniff the format from the bytes (Soniox) or the filename plus
        // content type (OpenAI); a container Apple invented would be silently rejected.
        #expect(flac.prefix(4).elementsEqual("fLaC".utf8))
    }

    @Test func isSubstantiallySmallerThanTheWav() throws {
        let pcm = try Self.realDecodedPcm(seconds: 4)
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        let flac = try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)

        // Deliberately loose: this fixture is one second of audio repeated, so its ratio is not
        // the corpus ratio and pinning a number here would be measuring the fixture. The claim
        // under test is only "lossless compression actually happens".
        #expect(flac.count < wav.count)
    }

    @Test func oddTrailingByteIsDroppedRatherThanReadPastTheEnd() throws {
        var pcm = try Self.realDecodedPcm()
        pcm.append(0x7F)
        let back = try PcmFlac.decodeToPcmMono16(
            flac: try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: Self.rate),
            sampleRateHz: Self.rate)
        #expect(back.count == pcm.count - 1)
    }

    @Test func emptyAudioThrowsRatherThanProducingAnEmptyFile() {
        #expect(throws: PcmFlac.Failure.emptyAudio) {
            try PcmFlac.encodeMono16(pcm: Data(), sampleRateHz: Self.rate)
        }
        #expect(throws: PcmFlac.Failure.emptyAudio) {
            try PcmFlac.encodeMono16(pcm: Data([0x01]), sampleRateHz: Self.rate)
        }
    }

    @Test func audioShorterThanOneBlockIsRefusedInsteadOfCorrupted() throws {
        // The one genuinely dangerous thing found while building this: below 4,096 frames Apple's
        // writer returns `noErr` from every call and leaves a 42-byte file with a ZEROED magic —
        // a corrupt stream, reported as success. Uploading that would fail the segment at the
        // provider and retry it forever. See `PcmFlac.minimumFrames`.
        let short = Data(repeating: 1, count: (PcmFlac.minimumFrames - 1) * 2)
        #expect(
            throws: PcmFlac.Failure.audioTooShort(
                frames: PcmFlac.minimumFrames - 1, minimum: PcmFlac.minimumFrames)
        ) {
            try PcmFlac.encodeMono16(pcm: short, sampleRateHz: Self.rate)
        }

        // Exactly one block is fine, and so is a length that is not a whole number of blocks.
        for frames in [PcmFlac.minimumFrames, PcmFlac.minimumFrames + 1] {
            let pcm = Data(repeating: 3, count: frames * 2)
            let flac = try PcmFlac.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
            #expect(flac.prefix(4).elementsEqual("fLaC".utf8))
            #expect(try PcmFlac.decodeToPcmMono16(flac: flac, sampleRateHz: Self.rate) == pcm)
        }
    }

    @Test func aShortSegmentUploadsAsWavRatherThanFailing() {
        // 100 ms. There is nothing to save at this length (its WAV is 3 kB), and the segment must
        // still reach the provider.
        let body = CloudAudioBody.encode(
            pcm: Data(repeating: 1, count: 3_200), sampleRateHz: Self.rate, format: .flac)
        #expect(body.format == .wav)
        #expect(body.bytes.prefix(4).elementsEqual("RIFF".utf8))
    }

    // MARK: - The upload body

    @Test func wavFormatReturnsTheInputBytesUntouched() throws {
        let wav = PcmWav.encodeMono16(
            pcm: try Self.realDecodedPcm(), sampleRateHz: Self.rate)
        let body = CloudAudioBody.encode(wav: wav, sampleRateHz: Self.rate, format: .wav)

        // Byte-identical, not merely equivalent: flipping the provider constant back to `.wav`
        // has to restore the previous wire bytes exactly.
        #expect(body.bytes == wav)
        #expect(body.format == .wav)
        #expect(body.contentType == "audio/wav")
        #expect(body.filename("segment") == "segment.wav")
    }

    @Test func flacFormatEncodesTheWavPayloadAndLabelsItHonestly() throws {
        let pcm = try Self.realDecodedPcm(seconds: 2)
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        let body = CloudAudioBody.encode(wav: wav, sampleRateHz: Self.rate, format: .flac)

        #expect(body.format == .flac)
        #expect(body.contentType == "audio/flac")
        #expect(body.filename("segment") == "segment.flac")
        #expect(body.bytes.prefix(4).elementsEqual("fLaC".utf8))
        #expect(try PcmFlac.decodeToPcmMono16(flac: body.bytes, sampleRateHz: Self.rate) == pcm)
    }

    @Test func encodingFromPcmAndFromTheAssembledWavAgree() throws {
        let pcm = try Self.realDecodedPcm(seconds: 2)
        let fromPcm = CloudAudioBody.encode(pcm: pcm, sampleRateHz: Self.rate, format: .flac)
        let fromWav = CloudAudioBody.encode(
            wav: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate),
            sampleRateHz: Self.rate, format: .flac)
        #expect(fromPcm.bytes == fromWav.bytes)
    }

    @Test func aFailedEncodeFallsBackToWavInsteadOfLosingTheSegment() {
        // Empty audio is the only encoder failure reachable without a broken system codec, and it
        // exercises the same path a Core Audio error would: report, then degrade to WAV. A segment
        // must never be dropped because compression did not work.
        var reported: Error?
        let body = CloudAudioBody.encode(
            pcm: Data(), sampleRateHz: Self.rate, format: .flac,
            onFallback: { reported = $0 })

        #expect(body.format == .wav)
        #expect(body.contentType == "audio/wav")
        #expect(body.bytes.prefix(4).elementsEqual("RIFF".utf8))
        #expect(reported as? PcmFlac.Failure == .emptyAudio)
    }

    // MARK: - PcmWav.pcmBody

    @Test func pcmBodyStripsACanonicalHeaderAndLeavesRawPcmAlone() throws {
        let pcm = try Self.realDecodedPcm()
        #expect(PcmWav.pcmBody(of: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)) == pcm)
        // No RIFF => already raw PCM. Same sniff `SegmentEnergy.profile(wav:)` makes.
        #expect(PcmWav.pcmBody(of: pcm) == pcm)
        // Too short to be a header, whatever it starts with.
        #expect(PcmWav.pcmBody(of: Data([0x01, 0x02])) == Data([0x01, 0x02]))
    }
}
