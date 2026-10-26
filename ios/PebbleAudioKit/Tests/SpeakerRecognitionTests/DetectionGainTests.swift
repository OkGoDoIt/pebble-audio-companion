import Foundation
import Testing
@testable import SpeakerRecognition

@Suite struct DetectionGainTests {
    private func tone(dBFS: Double, seconds: Double = 2, click: Bool = false) -> Data {
        let amplitude = 32_768 * pow(10, dBFS / 20) * sqrt(2)
        var samples = (0..<Int(seconds * 16_000)).map { Int16(amplitude * sin(2 * .pi * 220 * Double($0) / 16_000)) }
        if click { for i in 100..<140 { samples[i] = 32_000 } }
        return samples.withUnsafeBytes { Data($0) }
    }
    private func rmsDBFS(_ pcm: Data) -> Double {
        let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        return 20 * log10(rms / 32_768)
    }

    @Test func quietWatchSpeechIsLiftedToSpeakingLevelWithoutClipping() {
        let boosted = DetectionGain.apply(to: tone(dBFS: -58, click: true))
        #expect(abs(rmsDBFS(boosted) + 26) < 2)
        let peak = boosted.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        #expect(peak <= 32_000, "A tap is compressed, not clipped")
    }

    @Test func speechAlreadyAtLevelAndSilenceAreLeftAlone() {
        let normal = tone(dBFS: -24)
        #expect(DetectionGain.apply(to: normal) == normal)
        let silence = Data(count: 32_000)
        #expect(DetectionGain.apply(to: silence) == silence)
    }

    @Test func gainIsCappedSoNoiseIsNotTurnedIntoSpeech() {
        #expect(rmsDBFS(DetectionGain.apply(to: tone(dBFS: -80))) < -40)
    }
}
