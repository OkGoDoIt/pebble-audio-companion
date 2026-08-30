import Foundation
import Testing

/// Structural checks for the real-firmware Speex codec fixture. Port of the KMP
/// `SpeexFixtureTest` (core/protocol jvmTest): locks record framing, frame geometry, and the
/// byte-content hash so silent fixture drift is caught. The REAL decode lives in
/// `SpeexFrameDecoderTests` — this suite is the cross-repo drift guard.
@Suite struct SpeexFixtureTests {

    @Test func frameLogHasFiftyConstantSizeRecords() throws {
        let bytes = try SpeexFixture.framesBin()
        #expect(bytes.count == 1350)

        var offset = 0
        var frames = 0
        let raw = [UInt8](bytes)
        while offset < raw.count {
            let len = Int(raw[offset]) | (Int(raw[offset + 1]) << 8)
            #expect(len == 25, "frame \(frames) length")
            offset += 2 + len
            frames += 1
        }
        #expect(frames == 50)
        #expect(offset == raw.count)
    }

    @Test func fixtureBytesMatchFirmwareGoldenHash() throws {
        let bytes = try SpeexFixture.framesBin()
        // Same FNV-1a as PebbleOS test_audio_companion_speex.c GOLDEN_STREAM_FNV1A.
        var hash: UInt32 = 0x811C_9DC5
        for b in bytes {
            hash = (hash ^ UInt32(b)) &* 16_777_619
        }
        #expect(hash == 0x490A_EA30)
    }

    @Test func inputPcmIsOneSecondMono16k() throws {
        let pcm = try SpeexFixture.inputPcm()
        #expect(pcm.count == 16_000 * 2) // 1 s of s16le @ 16 kHz

        // Not silence: at least some samples have meaningful amplitude.
        let loud = SpeexFixture.samples(pcm).filter { $0 > 2000 || $0 < -2000 }.count
        #expect(loud > 1000, "input PCM looks silent: \(loud) loud samples")
    }
}
