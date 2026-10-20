import AudioCodec
import Foundation
import Testing

/// Questions from the watch are measured and brought to the level recognizers expect. The watch's
/// real speech sits around -46 dBFS (182 clips, 90th-percentile frame); these pin the gain, its
/// cap, the limiter and the high-pass against that.
@Suite struct VoiceNoteLevelTests {
    /// `seconds` of a 300 Hz tone whose RMS is `dbfs`.
    private func tone(dbfs: Double, seconds: Double = 2, hz: Double = 300) -> [Int16] {
        let amplitude = pow(10, dbfs / 20) * 32768 * 2.0.squareRoot()
        return (0..<Int(seconds * 16_000)).map {
            Int16(clamping: Int((amplitude * sin(2 * .pi * hz * Double($0) / 16_000)).rounded()))
        }
    }

    private func rmsDBFS(_ samples: ArraySlice<Int16>) -> Double {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 20 * log10((sum / Double(samples.count)).squareRoot() / 32768)
    }

    @Test func aQuietQuestionIsBroughtToTheTarget() {
        let (out, report) = VoiceNoteLevel.prepare(tone(dbfs: -46))
        let level = try? #require(report.speechLevelDBFS)
        #expect(abs((level ?? 0) - -46) < 1)
        #expect(abs(report.gainDB - 24) < 1)
        // Past the filter's settling, the speech now sits at the target.
        #expect(abs(rmsDBFS(out[8_000...]) - VoiceNoteLevel.Settings.automaticTargetDBFS) < 1)
        #expect(report.limitedSamples == 0)
    }

    @Test func theBoostIsCapped() {
        let (_, report) = VoiceNoteLevel.prepare(tone(dbfs: -70))
        #expect(report.gainDB == VoiceNoteLevel.Settings.automaticMaxGainDB)
    }

    @Test func loudSpeechIsNeverTurnedDown() {
        let (_, report) = VoiceNoteLevel.prepare(tone(dbfs: -15))
        #expect(report.gainDB == 0)
    }

    @Test func peaksAreHeldUnderTheCeiling() {
        // Quiet speech with a full-scale knock in the middle: the gain mustn't clip the knock.
        var samples = tone(dbfs: -46)
        for i in 16_000..<16_160 { samples[i] = i % 2 == 0 ? 32_000 : -32_000 }
        let (out, report) = VoiceNoteLevel.prepare(samples)
        #expect(report.gainDB > 20)
        #expect(report.limitedSamples > 0)
        #expect(report.peakDBFS <= -3 + 0.1)
        #expect(out.allSatisfy { abs(Int($0)) <= Int(pow(10, -3.0 / 20) * 32767) + 1 })
    }

    @Test func aFixedLevelIsUsedAsIs() {
        let (_, report) = VoiceNoteLevel.prepare(tone(dbfs: -46), settings: .init(fixedGainDB: 12))
        #expect(report.gainDB == 12)
    }

    @Test func silenceStaysSilent() {
        let (out, report) = VoiceNoteLevel.prepare([Int16](repeating: 0, count: 16_000))
        #expect(report.speechLevelDBFS == nil)
        #expect(report.gainDB == 0)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func rumbleIsNotBoostedWithTheSpeech() {
        // 20 Hz handling rumble at -30 dBFS mostly goes before anything is measured or boosted.
        let (out, _) = VoiceNoteLevel.prepare(tone(dbfs: -30, hz: 20), settings: .init(fixedGainDB: 0))
        #expect(rmsDBFS(out[8_000...]) < -45)
    }
}
