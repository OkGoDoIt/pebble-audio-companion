import AudioCodec
import Foundation
import Testing

/// Port of the KMP `PcmResamplerTest` (OpenAiRealtimeAccumulatorTest.kt): the 16 -> 24 kHz ratio
/// behavior used by the OpenAI realtime path, and the identity fast path.
@Suite struct PcmResamplerTests {

    private func samples(_ values: [Int]) -> Data {
        var out = [UInt8](repeating: 0, count: values.count * 2)
        for (i, v) in values.enumerated() {
            out[i * 2] = UInt8(v & 0xFF)
            out[i * 2 + 1] = UInt8((v >> 8) & 0xFF)
        }
        return Data(out)
    }

    private func readSamples(_ pcm: Data) -> [Int] {
        let bytes = [UInt8](pcm)
        return (0..<bytes.count / 2).map { i in
            let lo = Int(bytes[i * 2])
            let hi = Int(Int8(bitPattern: bytes[i * 2 + 1]))
            return (hi << 8) | lo
        }
    }

    @Test func upsamples16kTo24kByRatio() {
        // 4 input samples at 16k -> 6 output samples at 24k (ratio 3/2).
        let input = samples([0, 600, 1200, 1800])
        let out = PcmResampler.resampleLinearMono16(pcm: input, fromRate: 16_000, toRate: 24_000)
        #expect(out.count / 2 == 6)
        let s = readSamples(out)
        // Endpoints preserved; values monotonically increase across the interpolation.
        #expect(s.first == 0)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func sameRateIsIdentity() {
        let input = samples([1, 2, 3])
        #expect(
            PcmResampler.resampleLinearMono16(pcm: input, fromRate: 16_000, toRate: 16_000)
                == input)
    }

    @Test func negativeSamplesSurviveRoundTrip() {
        let input = samples([-32_768, -1200, 0, 1200, 32_767])
        let out = PcmResampler.resampleLinearMono16(pcm: input, fromRate: 16_000, toRate: 24_000)
        let s = readSamples(out)
        #expect(s.first == -32_768)
        #expect(s.allSatisfy { $0 >= -32_768 && $0 <= 32_767 })
        #expect(zip(s, s.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
