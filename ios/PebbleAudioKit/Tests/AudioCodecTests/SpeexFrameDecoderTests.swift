import AudioCodec
import Foundation
import Testing

/// REAL decode of the firmware fixture through the vendored libspeex — the check the JVM test
/// could not do (no native Speex there). If correlation against the encoder input is low, the
/// decoder configuration (mode / endianness / header byte) is wrong; fix that, don't lower the
/// bar.
@Suite struct SpeexFrameDecoderTests {

    private func fixtureFrames() throws -> [Data] {
        let frames = SpeexFixture.parseFrames(try SpeexFixture.framesBin())
        #expect(frames.count == 50)
        return frames
    }

    @Test func decodesAllFramesToOneSecondOfPcm() throws {
        let decoder = SpeexFrameDecoder(hasHeaderByte: false)
        let pcm = try decoder.decodeAll(frames: try fixtureFrames())
        #expect(pcm.count == 50 * 320 * 2) // 50 frames x 320 samples of s16le = 32 000 bytes

        // Default chunk size is exactly 1 s, so the fixture decodes to a single bounded chunk.
        let chunks = try decoder.decode(frames: try fixtureFrames())
        #expect(chunks.map(\.count) == [32_000])
    }

    @Test func decodedAudioCorrelatesWithEncoderInput() throws {
        let decoder = SpeexFrameDecoder(hasHeaderByte: false)
        let decoded = SpeexFixture.samples(try decoder.decodeAll(frames: try fixtureFrames()))
        let input = SpeexFixture.samples(try SpeexFixture.inputPcm())
        #expect(decoded.count == input.count)

        // Speex is lossy and the wideband codec has algorithmic delay, so search a small lag
        // window for the best normalized cross-correlation instead of expecting byte equality.
        var best = 0.0
        var bestLag = 0
        for lag in 0...600 {
            let n = input.count - lag
            var dot = 0.0
            var inputEnergy = 0.0
            var decodedEnergy = 0.0
            for i in 0..<n {
                dot += input[i] * decoded[i + lag]
                inputEnergy += input[i] * input[i]
                decodedEnergy += decoded[i + lag] * decoded[i + lag]
            }
            let denominator = (inputEnergy * decodedEnergy).squareRoot()
            guard denominator > 0 else { continue }
            let corr = dot / denominator
            if corr > best {
                best = corr
                bestLag = lag
            }
        }
        print("Speex decode correlation: \(best) at lag \(bestLag) samples")
        #expect(best > 0.5, "decoded audio does not correlate with encoder input (best \(best))")

        let inputRms = (input.map { $0 * $0 }.reduce(0, +) / Double(input.count)).squareRoot()
        let decodedRms =
            (decoded.map { $0 * $0 }.reduce(0, +) / Double(decoded.count)).squareRoot()
        #expect(decodedRms > inputRms / 3 && decodedRms < inputRms * 3,
                "decoded RMS \(decodedRms) vs input RMS \(inputRms)")
    }

    @Test func chunkingEmitsBoundedChunksAndRemainder() throws {
        let decoder = SpeexFrameDecoder(hasHeaderByte: false)
        let chunks = try decoder.decode(frames: try fixtureFrames(), pcmChunkBytes: 7000)
        #expect(chunks.map(\.count) == [7000, 7000, 7000, 7000, 4000])

        var joined = Data()
        for chunk in chunks { joined.append(chunk) }
        #expect(joined == (try decoder.decodeAll(frames: try fixtureFrames())))
    }

    @Test func headerByteVariantSkipsLeadingByte() throws {
        let frames = try fixtureFrames()
        let baseline = try SpeexFrameDecoder(hasHeaderByte: false).decodeAll(frames: frames)

        // Official-dictation-style frames carry one frame-quality byte before the Speex payload.
        let prefixed = frames.map { Data([0xFF]) + $0 }
        let viaHeader = try SpeexFrameDecoder(hasHeaderByte: true).decodeAll(frames: prefixed)
        #expect(viaHeader == baseline)
    }

    @Test func asyncDecodeMatchesSyncDecode() async throws {
        let frames = try fixtureFrames()
        let decoder = SpeexFrameDecoder(hasHeaderByte: false)

        let stream = AsyncStream<Data> { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        var streamed = Data()
        var chunkSizes: [Int] = []
        for try await chunk in decoder.decode(frames: stream, pcmChunkBytes: 7000) {
            chunkSizes.append(chunk.count)
            streamed.append(chunk)
        }
        #expect(chunkSizes == [7000, 7000, 7000, 7000, 4000])
        #expect(streamed == (try decoder.decodeAll(frames: frames)))
    }

    @Test func emptyFrameThrowsTranscriptionFailed() throws {
        let decoder = SpeexFrameDecoder(hasHeaderByte: false)
        #expect(throws: AudioCodecError.self) {
            _ = try decoder.decodeAll(frames: [Data()])
        }
    }

    @Test func mismatchedFrameSizeConfigurationThrows() throws {
        // Wideband produces 320-sample frames; a decoder configured for another geometry must
        // fail loudly instead of silently mis-sizing PCM.
        let decoder = SpeexFrameDecoder(frameSamples: 160, hasHeaderByte: false)
        #expect(throws: AudioCodecError.self) {
            _ = try decoder.decodeAll(frames: try self.fixtureFrames())
        }
    }
}
