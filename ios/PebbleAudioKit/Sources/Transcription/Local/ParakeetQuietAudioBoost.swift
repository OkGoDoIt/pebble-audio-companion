import AppDB
import Foundation

// An EXPERIMENT, off by default: watch audio is very quiet (RMS −42…−62 dBFS in the recordings
// the Core AI spike measured), and both local engines transcribe it badly. Peak-normalizing the
// spike's clips helped modestly. This applies the same idea per VAD chunk, right before the
// chunk is written to the WAV both local engines read, so the two can be compared on the same
// input with the switch on and off.
//
// The switch is an App Group defaults key (`local_transcription_boost_quiet_audio`) rather than
// an `AppSettings` property: a Debug-only row on the local-model screen flips it, nothing in
// Settings proper mentions it, and it does not survive into the product unless the numbers say
// it should.
//
// Boost only, never attenuate: a chunk already peaking above the target is left alone. A cap
// keeps near-silence from being amplified into full-scale noise.

public enum ParakeetQuietAudioBoost {
    public static let defaultsKey = "local_transcription_boost_quiet_audio"
    /// Where the loudest sample of a chunk lands after the boost.
    public static let targetPeakDbfs: Double = -3
    /// The most gain ever applied (+40 dB), so a chunk of hiss cannot become full-scale hiss.
    public static let maxGain: Double = 100
    static let fullScale = 32_767.0

    /// The switch, read from the App Group suite (absent ⇒ off).
    public static func isEnabled(
        defaults: UserDefaults? = UserDefaults(suiteName: AppDatabase.appGroupIdentifier)
    ) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    public static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults? = UserDefaults(suiteName: AppDatabase.appGroupIdentifier)
    ) {
        defaults?.set(enabled, forKey: defaultsKey)
    }

    /// Linear gain that brings a chunk whose loudest sample is `peak` (0…32767) up to the
    /// target: 1 for silence, for a chunk already at or above the target, and never above
    /// `maxGain`.
    public static func gain(forPeak peak: Int, targetDbfs: Double = targetPeakDbfs) -> Double {
        guard peak > 0 else { return 1 }
        let target = fullScale * pow(10, targetDbfs / 20)
        let raw = target / Double(peak)
        return min(max(raw, 1), maxGain)
    }

    /// The loudest |sample| in `bytes` of s16le audio (a trailing odd byte is ignored).
    public static func peak(of bytes: Data) -> Int {
        var peak = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            var index = 0
            let end = ParakeetPcm.align(raw.count)
            while index < end {
                let sample = Int(Int16(bitPattern: UInt16(base[index]) | (UInt16(base[index + 1]) << 8)))
                peak = max(peak, abs(sample))
                index += 2
            }
        }
        return peak
    }

    /// `bytes` of s16le audio with `gain` applied, rounded to nearest and clipped to 16 bits.
    /// Gain 1 returns the input untouched.
    public static func apply(_ gain: Double, to bytes: Data) -> Data {
        guard gain != 1 else { return bytes }
        let count = ParakeetPcm.align(bytes.count)
        var out = Data(count: count)
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBytes { dest in
                let target = dest.bindMemory(to: UInt8.self)
                var index = 0
                while index < count {
                    let sample = Int16(bitPattern: UInt16(base[index]) | (UInt16(base[index + 1]) << 8))
                    let scaled = (Double(sample) * gain).rounded()
                    let clipped = Int16(max(min(scaled, Double(Int16.max)), Double(Int16.min)))
                    let bits = UInt16(bitPattern: clipped)
                    target[index] = UInt8(bits & 0xFF)
                    target[index + 1] = UInt8(bits >> 8)
                    index += 2
                }
            }
        }
        return out
    }
}
