import Foundation

/// Linear-interpolation resampler for 16-bit signed little-endian mono PCM. Port of the KMP
/// `PcmResampler`. Used to feed providers that require a fixed input rate (e.g. OpenAI realtime
/// wants 24 kHz) from the watch's 16 kHz audio. Linear interpolation is adequate for speech
/// transcription and cheap enough for the live path.
public enum PcmResampler {
    public static func resampleLinearMono16(pcm: Data, fromRate: Int, toRate: Int) -> Data {
        if fromRate == toRate || fromRate <= 0 || toRate <= 0 { return pcm }
        let bytes = [UInt8](pcm)
        let inSamples = bytes.count / 2
        if inSamples == 0 { return Data() }
        let outSamples = max(1, Int(Int64(inSamples) * Int64(toRate) / Int64(fromRate)))
        var out = [UInt8](repeating: 0, count: outSamples * 2)
        for i in 0..<outSamples {
            let srcPos = Double(i) * Double(fromRate) / Double(toRate)
            let idx = Int(srcPos)
            let frac = srcPos - Double(idx)
            let s0 = Double(sample(in: bytes, at: idx, count: inSamples))
            let s1 = Double(sample(in: bytes, at: idx + 1, count: inSamples))
            // Kotlin's roundToInt rounds half-up (floor(x + 0.5)); match it exactly.
            let rounded = Int((s0 + (s1 - s0) * frac + 0.5).rounded(.down))
            let value = min(32767, max(-32768, rounded))
            out[i * 2] = UInt8(value & 0xFF)
            out[i * 2 + 1] = UInt8((value >> 8) & 0xFF)
        }
        return Data(out)
    }

    private static func sample(in bytes: [UInt8], at index: Int, count: Int) -> Int {
        let i = min(max(index, 0), count - 1)
        let lo = Int(bytes[i * 2])
        let hi = Int(Int8(bitPattern: bytes[i * 2 + 1]))
        return (hi << 8) | lo
    }
}
