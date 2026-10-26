import Foundation

/// Brings quiet audio up to speaking level for the speech and overlap detector only. The watch
/// hears its wearer 20–30 dB below a phone held to the mouth (2026-10-26: a read-aloud sample
/// measured −55 to −62 dBFS), and the detector, trained on normal levels, scores that as little or
/// no speech. Embeddings are left alone: their recipe is level-independent by design and every
/// saved voice was made from unboosted audio.
public enum DetectionGain {
    /// Where typical close speech sits.
    static let targetDBFS = -26.0
    /// Beyond +36 dB the codec's own noise is all that would be amplified.
    static let maximumGain = 63.0

    /// The level is read from the loudest tenth of 20 ms frames, so a stretch of silence doesn't
    /// inflate the gain and a single tap doesn't dictate it; peaks the gain would push past full
    /// scale are compressed rather than clipped.
    public static func apply(to pcm16LE: Data) -> Data {
        let samples: [Int16] = pcm16LE.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard samples.count >= 320 else { return pcm16LE }
        var frames: [Double] = []
        for start in stride(from: 0, to: samples.count - 319, by: 320) {
            var sum = 0.0
            for value in samples[start..<(start + 320)] { sum += Double(value) * Double(value) }
            frames.append(sqrt(sum / 320))
        }
        frames.sort()
        let level = frames[min(frames.count - 1, Int(Double(frames.count) * 0.9))]
        guard level > 0 else { return pcm16LE }
        let gain = min(maximumGain, max(1, 32_768 * pow(10, targetDBFS / 20) / level))
        guard gain > 1.05 else { return pcm16LE }
        let knee = 24_000.0, ceiling = 32_000.0
        var out = [Int16](repeating: 0, count: samples.count)
        for (index, value) in samples.enumerated() {
            var y = Double(value) * gain
            let magnitude = abs(y)
            if magnitude > knee {
                // Soft knee: everything above the knee is squeezed into the headroom left.
                let over = (magnitude - knee) / (ceiling - knee)
                y = (knee + (ceiling - knee) * over / (1 + over)) * (y < 0 ? -1 : 1)
            }
            out[index] = Int16(max(-32_767, min(32_767, y)))
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
