import Foundation

/// Standard 44-byte RIFF/WAVE wrapping for s16le mono PCM. Port of the KMP `PcmWav` object.
public enum PcmWav {
    public static let headerBytes = 44
    private static let pcmFormat: UInt16 = 1

    public static func encodeMono16(pcm: Data, sampleRateHz: Int) -> Data {
        var out = headerMono16(pcmSizeBytes: pcm.count, sampleRateHz: sampleRateHz)
        out.append(pcm)
        return out
    }

    public static func headerMono16(pcmSizeBytes: Int, sampleRateHz: Int) -> Data {
        precondition(sampleRateHz > 0, "sampleRateHz must be positive")
        precondition(pcmSizeBytes >= 0, "pcmSizeBytes must be non-negative")
        var out = [UInt8](repeating: 0, count: headerBytes)
        writeAscii(&out, at: 0, "RIFF")
        writeU32Le(&out, at: 4, UInt32(truncatingIfNeeded: 36 + pcmSizeBytes))
        writeAscii(&out, at: 8, "WAVE")
        writeAscii(&out, at: 12, "fmt ")
        writeU32Le(&out, at: 16, 16)
        writeU16Le(&out, at: 20, pcmFormat)
        writeU16Le(&out, at: 22, 1) // channels
        writeU32Le(&out, at: 24, UInt32(truncatingIfNeeded: sampleRateHz))
        writeU32Le(&out, at: 28, UInt32(truncatingIfNeeded: sampleRateHz * 2)) // byte rate
        writeU16Le(&out, at: 32, 2) // block align
        writeU16Le(&out, at: 34, 16) // bits per sample
        writeAscii(&out, at: 36, "data")
        writeU32Le(&out, at: 40, UInt32(truncatingIfNeeded: pcmSizeBytes))
        return Data(out)
    }

    private static func writeAscii(_ out: inout [UInt8], at offset: Int, _ value: String) {
        for (i, byte) in value.utf8.enumerated() {
            out[offset + i] = byte
        }
    }

    private static func writeU16Le(_ out: inout [UInt8], at offset: Int, _ value: UInt16) {
        out[offset] = UInt8(value & 0xFF)
        out[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func writeU32Le(_ out: inout [UInt8], at offset: Int, _ value: UInt32) {
        out[offset] = UInt8(value & 0xFF)
        out[offset + 1] = UInt8((value >> 8) & 0xFF)
        out[offset + 2] = UInt8((value >> 16) & 0xFF)
        out[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
