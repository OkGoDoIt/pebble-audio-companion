import AudioCodec
import Foundation
import Testing

/// Port of the KMP `wavEncoderWritesExpectedHeader` (OpenAiTranscriptionProviderTest) plus
/// field-level locks on the 44-byte RIFF header this Swift port re-implements.
@Suite struct PcmWavTests {

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data.subdata(in: range), as: UTF8.self)
    }

    private func u16le(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private func u32le(_ data: Data, _ offset: Int) -> Int {
        u16le(data, offset) | (u16le(data, offset + 2) << 16)
    }

    @Test func wavEncoderWritesExpectedHeader() {
        let wav = PcmWav.encodeMono16(pcm: Data([1, 2, 3, 4]), sampleRateHz: 16_000)

        #expect(ascii(wav, 0..<4) == "RIFF")
        #expect(ascii(wav, 8..<12) == "WAVE")
        #expect(ascii(wav, 12..<16) == "fmt ")
        #expect(ascii(wav, 36..<40) == "data")
        #expect(wav.count == 48)
        #expect(wav.subdata(in: 44..<48) == Data([1, 2, 3, 4]))
    }

    @Test func headerFieldsAreStandardMono16Pcm() {
        let wav = PcmWav.encodeMono16(pcm: Data(count: 32_000), sampleRateHz: 16_000)

        #expect(u32le(wav, 4) == 36 + 32_000) // RIFF chunk size
        #expect(u32le(wav, 16) == 16) // fmt chunk size
        #expect(u16le(wav, 20) == 1) // PCM format
        #expect(u16le(wav, 22) == 1) // mono
        #expect(u32le(wav, 24) == 16_000) // sample rate
        #expect(u32le(wav, 28) == 32_000) // byte rate = rate * 2
        #expect(u16le(wav, 32) == 2) // block align
        #expect(u16le(wav, 34) == 16) // bits per sample
        #expect(u32le(wav, 40) == 32_000) // data size
    }

    @Test func headerAloneMatchesEncodePrefix() {
        let pcm = Data([9, 8, 7, 6, 5, 4])
        let header = PcmWav.headerMono16(pcmSizeBytes: pcm.count, sampleRateHz: 24_000)
        #expect(header.count == 44)
        #expect(PcmWav.encodeMono16(pcm: pcm, sampleRateHz: 24_000).prefix(44) == header)
    }
}
