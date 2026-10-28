import AudioCodec
import Foundation
import Testing

/// Playback is leveled in the pieces it is played in. These pin what a listener would notice: the
/// first piece already sits at the target, the level does not jump between pieces, loud audio is
/// left alone, nothing clips when the audio gets louder, and silence stays silent.
@Suite struct PlaybackLevelTests {
    private func tone(dbfs: Double, seconds: Double, hz: Double = 300) -> [Int16] {
        let amplitude = pow(10, dbfs / 20) * 32768 * 2.0.squareRoot()
        return (0..<Int(seconds * 16_000)).map {
            Int16(clamping: Int((amplitude * sin(2 * .pi * hz * Double($0) / 16_000)).rounded()))
        }
    }

    private func rmsDBFS(_ samples: ArraySlice<Int16>) -> Double {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 20 * log10((sum / Double(samples.count)).squareRoot() / 32768)
    }

    /// Played in the half-second pieces segment playback decodes.
    private func play(_ pcm: [Int16], _ level: inout PlaybackLevel) -> [Int16] {
        stride(from: 0, to: pcm.count, by: 8_000).flatMap {
            level.process(Array(pcm[$0..<min($0 + 8_000, pcm.count)]))
        }
    }

    @Test func quietWatchSpeechPlaysAtTheTargetFromTheFirstPiece() {
        var level = PlaybackLevel()
        let out = play(tone(dbfs: -46, seconds: 6), &level)
        #expect(abs(rmsDBFS(out[2_000..<8_000]) - VoiceNoteLevel.Settings.automaticTargetDBFS) < 1)
        #expect(abs(rmsDBFS(out[80_000...]) - VoiceNoteLevel.Settings.automaticTargetDBFS) < 1)
    }

    @Test func theLevelDoesNotJumpBetweenPieces() {
        var level = PlaybackLevel()
        let out = play(tone(dbfs: -46, seconds: 6), &level)
        let pieces = stride(from: 8_000, to: out.count, by: 8_000).map { rmsDBFS(out[$0..<$0 + 8_000]) }
        #expect((pieces.max()! - pieces.min()!) < 0.5)
    }

    @Test func loudAudioIsLeftAtItsLevel() {
        var level = PlaybackLevel()
        let out = play(tone(dbfs: -18, seconds: 4), &level)
        #expect(abs(rmsDBFS(out[8_000...]) - -18) < 0.5)
    }

    @Test func gettingLouderNeverClips() {
        var level = PlaybackLevel()
        let out = play(tone(dbfs: -50, seconds: 4) + tone(dbfs: -20, seconds: 2), &level)
        let ceiling = Int(pow(10, VoiceNoteLevel.Settings().limitDBFS / 20) * 32767) + 1
        #expect(out.allSatisfy { abs(Int($0)) <= ceiling })
    }

    @Test func silenceStaysSilent() {
        var level = PlaybackLevel()
        let out = play([Int16](repeating: 0, count: 32_000), &level)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(level.currentGainDB == nil)
    }
}
