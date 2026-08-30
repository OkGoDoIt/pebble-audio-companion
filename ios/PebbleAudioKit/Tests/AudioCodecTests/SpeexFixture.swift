import Foundation
import Testing

/// Shared access to the real-firmware Speex fixture (spec/fixtures/speex_frames_v1*, copied into
/// this test bundle's Fixtures directory).
enum SpeexFixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    static func framesBin() throws -> Data {
        try data("speex_frames_v1", "bin")
    }

    static func inputPcm() throws -> Data {
        try data("speex_frames_v1_input", "pcm")
    }

    /// Parses the `{u16le len, frame}` record log into individual encoded frames.
    static func parseFrames(_ bin: Data) -> [Data] {
        let bytes = [UInt8](bin)
        var frames: [Data] = []
        var offset = 0
        while offset + 2 <= bytes.count {
            let len = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            let start = offset + 2
            guard start + len <= bytes.count else { break }
            frames.append(Data(bytes[start..<(start + len)]))
            offset = start + len
        }
        return frames
    }

    /// s16le -> [Double] samples.
    static func samples(_ pcm: Data) -> [Double] {
        let bytes = [UInt8](pcm)
        var out = [Double](repeating: 0, count: bytes.count / 2)
        for i in 0..<out.count {
            let lo = Int(bytes[i * 2])
            let hi = Int(Int8(bitPattern: bytes[i * 2 + 1]))
            out[i] = Double((hi << 8) | lo)
        }
        return out
    }
}
