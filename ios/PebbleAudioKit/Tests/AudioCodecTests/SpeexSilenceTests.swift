import AudioCodec
import Foundation
import Testing

/// The frame that replaces deleted audio has to be a frame the watch itself could have sent:
/// the decoder takes it, a run of them decodes to silence, and the real audio on either side
/// of the run still decodes. Anything less and deleting one conversation damages the
/// recording it shares a segment with.
@Suite struct SpeexSilenceTests {

    private func fixtureFrames() throws -> [Data] {
        let frames = SpeexFixture.parseFrames(try SpeexFixture.framesBin())
        #expect(frames.count == 50)
        return frames
    }

    /// Frame `index` of a decoded stream, as samples.
    private func frame(_ index: Int, of samples: [Double]) -> ArraySlice<Double> {
        samples[(index * 320)..<((index + 1) * 320)]
    }

    private func peak(_ samples: ArraySlice<Double>) -> Double {
        samples.map { abs($0) }.max() ?? 0
    }

    private func rms(_ samples: ArraySlice<Double>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.map { $0 * $0 }.reduce(0, +) / Double(samples.count)).squareRoot()
    }

    /// The wrapper is only worth trusting for silence if it is the firmware's encoder: same
    /// mode, same quality-then-bit-rate order, same complexity. Fixed-point Speex is
    /// deterministic, so the proof is exact — the fixture's input PCM re-encodes to the
    /// fixture's bytes.
    @Test func theEncoderReproducesTheFirmwareBitstream() throws {
        let expected = try fixtureFrames()
        let input = [UInt8](try SpeexFixture.inputPcm())
        let encoder = try SpeexFrameEncoder()
        #expect(encoder.frameSamples == 320)
        for index in expected.indices {
            var samples = [Int16](repeating: 0, count: 320)
            for i in 0..<320 {
                let offset = (index * 320 + i) * 2
                samples[i] = Int16(
                    bitPattern: UInt16(input[offset]) | (UInt16(input[offset + 1]) << 8))
            }
            #expect(try encoder.encodeFrame(samples) == expected[index], "frame \(index)")
        }
    }

    @Test func theSilenceFrameIsOneFirmwareSizedFrame() throws {
        let silence = try SpeexSilence.frame()
        // Every frame the watch sends is 25 bytes; a silenced log must stay the size it was.
        #expect(silence.count == 25)
        #expect(Set(try fixtureFrames().map(\.count)) == [25])
        // Cached: the same bytes every time.
        #expect(try SpeexSilence.frame() == silence)
    }

    /// One frame stands for any number in a row only if the encoder has no start-up on zero
    /// input: its first frame and its later ones must be the same bytes.
    @Test func zeroInputEncodesToTheSameFrameEveryTime() throws {
        let encoder = try SpeexFrameEncoder()
        let zeros = [Int16](repeating: 0, count: 320)
        let frames = try (0..<12).map { _ in [UInt8](try encoder.encodeFrame(zeros)) }
        #expect(Set(frames).count == 1)
        #expect(frames[0] == (try SpeexSilence.frame()))
    }

    @Test func aRunOfSilenceFramesDecodesToSilence() throws {
        let silence = Data(try SpeexSilence.frame())
        let pcm = try SpeexFrameDecoder().decodeAll(frames: Array(repeating: silence, count: 100))
        #expect(pcm.count == 100 * 320 * 2)
        #expect(peak(SpeexFixture.samples(pcm)[...]) <= 2)
    }

    /// The case the delete actually produces: real frames, a silenced stretch, real frames.
    @Test func aSilencedStretchBetweenRealFramesDecodes() throws {
        let real = try fixtureFrames()
        let silence = Data(try SpeexSilence.frame())
        let decoder = SpeexFrameDecoder()
        let untouched = SpeexFixture.samples(try decoder.decodeAll(frames: real))
        let silenced = SpeexFixture.samples(
            try decoder.decodeAll(
                frames: Array(real[0..<25]) + Array(repeating: silence, count: 50)
                    + Array(real[25..<50])))
        #expect(silenced.count == 100 * 320)

        // Before the stretch nothing changed: a decoder cannot hear what comes next.
        #expect(Array(silenced[0..<(25 * 320)]) == Array(untouched[0..<(25 * 320)]))

        // Inside it: the first frame still carries the codec's delay, the next rings at a few
        // dozen LSB, and after that it is silence.
        #expect(peak(frame(26, of: silenced)) < 328, "second silenced frame rings above 1%")
        for index in 27..<75 {
            #expect(peak(frame(index, of: silenced)) <= 16, "silenced frame \(index) is not quiet")
        }
        for index in 30..<75 {
            #expect(peak(frame(index, of: silenced)) == 0, "silenced frame \(index) is not zero")
        }

        // After it the real audio is audible again. It comes back quieter than it was recorded
        // while the decoder's history catches up (see `SpeexSilence.frame`), so this asks for
        // "clearly there", not "identical".
        let recovered = rms(silenced[(90 * 320)..<(100 * 320)])
        let original = rms(untouched[(40 * 320)..<(50 * 320)])
        print("audio after a silenced stretch: rms \(recovered) against \(original) recorded")
        #expect(recovered > original / 4)
    }

    @Test func anUnsupportedSampleRateThrowsInsteadOfInventingAFrame() {
        #expect(throws: AudioCodecError.self) {
            _ = try SpeexSilence.frame(sampleRateHz: 44_100)
        }
    }
}
