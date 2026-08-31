import AudioCodec
import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/commonTest/.../SonioxRealtimeAccumulatorTest.kt` (2 cases) and
// `OpenAiRealtimeAccumulatorTest.kt` (1 + the 2 `PcmResamplerTest` cases that share its file) —
// same names.

@Suite struct SonioxRealtimeAccumulatorTests {

    @Test func foldsFinalAndPartialTokens() throws {
        let acc = SonioxRealtimeAccumulator(diarization: false)

        let first = acc.accept(
            tokens: [
                SonioxRtToken(text: "Hello ", isFinal: true),
                SonioxRtToken(text: "wor", isFinal: false),
            ],
            finished: false
        )
        #expect(first.finalText == "Hello")
        #expect(first.partialText == "wor")
        #expect(first.isFinal == false)

        // Next message finalizes the rest; the previous partial is replaced, not appended twice.
        let second = acc.accept(
            tokens: [SonioxRtToken(text: "world", isFinal: true)],
            finished: true
        )
        #expect(second.finalText == "Hello world")
        #expect(second.partialText == "")
        #expect(second.isFinal)
    }

    @Test func groupsFinalTokensBySpeakerWhenDiarizing() throws {
        let acc = SonioxRealtimeAccumulator(diarization: true)

        let update = acc.accept(
            tokens: [
                SonioxRtToken(text: "hi ", isFinal: true, speaker: "1", startMs: 0, endMs: 300),
                SonioxRtToken(text: "there ", isFinal: true, speaker: "1", startMs: 300, endMs: 600),
                SonioxRtToken(text: "yes", isFinal: true, speaker: "2", startMs: 800, endMs: 1_100),
            ],
            finished: false
        )

        #expect(update.finalText == "hi there yes")
        #expect(update.segments.map(\.speaker) == ["1", "2"])
        #expect(update.segments.first?.text == "hi there")
        #expect(update.segments.last?.text == "yes")
    }
}

@Suite struct OpenAiRealtimeAccumulatorTests {

    @Test func deltasFormPartialAndCompletedFinalizes() throws {
        let acc = OpenAiRealtimeAccumulator()

        #expect(acc.delta("Hello").partialText == "Hello")
        let withMore = acc.delta(", wor")
        #expect(withMore.partialText == "Hello, wor")
        #expect(withMore.finalText == "")

        let done = acc.completed("Hello, world")
        #expect(done.finalText == "Hello, world")
        #expect(done.partialText == "")

        // A second item appends to the stable transcript.
        let next = acc.completed("Goodbye")
        #expect(next.finalText == "Hello, world Goodbye")
    }
}

@Suite struct PcmResamplerTests {

    private func samples(_ values: [Int]) -> Data {
        var out = Data(capacity: values.count * 2)
        for value in values {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
        }
        return out
    }

    private func readSamples(_ pcm: Data) -> [Int] {
        let bytes = [UInt8](pcm)
        return (0..<(bytes.count / 2)).map { i in
            let lo = Int(bytes[i * 2])
            let hi = Int(Int8(bitPattern: bytes[i * 2 + 1]))
            return (hi << 8) | lo
        }
    }

    @Test func upsamples16kTo24kByRatio() throws {
        // 4 input samples at 16k -> 6 output samples at 24k (ratio 3/2).
        let input = samples([0, 600, 1_200, 1_800])
        let out = PcmResampler.resampleLinearMono16(pcm: input, fromRate: 16_000, toRate: 24_000)
        #expect(out.count / 2 == 6)
        let s = readSamples(out)
        // Endpoints preserved; values monotonically increase across the interpolation.
        #expect(s.first == 0)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func sameRateIsIdentity() throws {
        let input = samples([1, 2, 3])
        #expect(PcmResampler.resampleLinearMono16(pcm: input, fromRate: 16_000, toRate: 16_000) == input)
    }
}
