import Foundation
import Testing

@testable import Transcription

// The boost is an experiment, but its arithmetic is not: a wrong gain quietly changes what both
// local engines hear. Every rule — target, never attenuate, the cap, rounding and clipping — is
// pinned here on hand-made samples.

private func pcm(_ samples: [Int16]) -> Data {
    samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self))
    }
}

@Suite struct ParakeetQuietAudioBoostTests {
    @Test func gainBringsThePeakToMinusThreeDbfs() {
        // −3 dBFS is 32767 × 10^(−3/20) ≈ 23197.
        let gain = ParakeetQuietAudioBoost.gain(forPeak: 1_000)
        #expect(abs(gain * 1_000 - 23_197) < 1)
        #expect(abs(ParakeetQuietAudioBoost.gain(forPeak: 23_197) - 1) < 0.001)
    }

    @Test func gainNeverAttenuatesAndIsCapped() {
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 32_767) == 1)
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 30_000) == 1)
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 0) == 1)
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 1) == ParakeetQuietAudioBoost.maxGain)
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 100) == ParakeetQuietAudioBoost.maxGain)
        #expect(ParakeetQuietAudioBoost.gain(forPeak: 300) < ParakeetQuietAudioBoost.maxGain)
    }

    @Test func peakIsTheLargestMagnitudeEitherSign() {
        #expect(ParakeetQuietAudioBoost.peak(of: pcm([10, -300, 250, 0])) == 300)
        #expect(ParakeetQuietAudioBoost.peak(of: pcm([Int16.min])) == 32_768)
        #expect(ParakeetQuietAudioBoost.peak(of: Data()) == 0)
        // A trailing odd byte is not a sample.
        #expect(ParakeetQuietAudioBoost.peak(of: pcm([5]) + Data([0x7F])) == 5)
    }

    @Test func applyScalesRoundsAndClips() {
        let out = samples(ParakeetQuietAudioBoost.apply(2.5, to: pcm([100, -100, 3, 20_000, -20_000])))
        #expect(out == [250, -250, 8, 32_767, -32_768])
        // Gain 1 is the identity, bytes untouched.
        let input = pcm([1, 2, 3])
        #expect(ParakeetQuietAudioBoost.apply(1, to: input) == input)
    }

    @Test func endToEndAQuietChunkLandsOnTheTarget() {
        // Peak 800 (≈ −32 dBFS, typical watch speech): well inside the +40 dB cap.
        let quiet = pcm([500, -800, 200, 0, 800])
        let gain = ParakeetQuietAudioBoost.gain(forPeak: ParakeetQuietAudioBoost.peak(of: quiet))
        let boosted = samples(ParakeetQuietAudioBoost.apply(gain, to: quiet))
        #expect(boosted.map { abs(Int($0)) }.max() == 23_197)
        // Peak 80 (≈ −52 dBFS, the quietest recordings) hits the cap instead: 100 × 80.
        let hiss = pcm([80, -30])
        let capped = ParakeetQuietAudioBoost.gain(forPeak: ParakeetQuietAudioBoost.peak(of: hiss))
        #expect(samples(ParakeetQuietAudioBoost.apply(capped, to: hiss)) == [8_000, -3_000])
    }

    @Test func theSwitchIsAnAppGroupDefaultThatIsOffByDefault() throws {
        let suite = "dev.audiocompanion.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ParakeetQuietAudioBoost.isEnabled(defaults: defaults) == false)
        ParakeetQuietAudioBoost.setEnabled(true, defaults: defaults)
        #expect(ParakeetQuietAudioBoost.isEnabled(defaults: defaults))
        #expect(ParakeetQuietAudioBoost.defaultsKey == "local_transcription_boost_quiet_audio")
        // A nil suite (no App Group in this process) reads as off, never as on.
        #expect(ParakeetQuietAudioBoost.isEnabled(defaults: nil) == false)
    }
}
