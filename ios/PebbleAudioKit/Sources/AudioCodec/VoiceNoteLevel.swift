import Foundation

/// Brings a question asked on the watch up to the level speech recognizers expect, and no
/// further.
///
/// Watch audio sits far below what recognizers are tuned for. Across 182 real conversation clips
/// the loud end of speech (each clip's 90th-percentile 20 ms frame) sat at -46 dBFS at the median,
/// against the -20 to -26 dBFS recognizers expect. A flat boost can't fix that: the spread is wide
/// (-53 to -40 dBFS for the middle half) and a few clips already peak at full scale. So each
/// question is measured and given its own gain, after a high-pass that keeps wind and handling
/// rumble from being boosted with it, and a limiter catches the peaks the gain would clip.
public enum VoiceNoteLevel {
    public struct Settings: Sendable, Equatable {
        /// Where the loud end of the speech (the 90th-percentile 20 ms frame) is put, in dBFS.
        public var targetDBFS: Double
        /// The most a measured question is boosted.
        public var maxGainDB: Double
        /// A fixed gain instead of the measured one.
        public var fixedGainDB: Double?
        /// The limiter's ceiling.
        public var limitDBFS: Double
        public var highPassHz: Double

        public static let automaticTargetDBFS: Double = -22
        public static let automaticMaxGainDB: Double = 30

        public init(
            targetDBFS: Double = Self.automaticTargetDBFS,
            maxGainDB: Double = Self.automaticMaxGainDB,
            fixedGainDB: Double? = nil,
            limitDBFS: Double = -3,
            highPassHz: Double = 80
        ) {
            self.targetDBFS = targetDBFS
            self.maxGainDB = maxGainDB
            self.fixedGainDB = fixedGainDB
            self.limitDBFS = limitDBFS
            self.highPassHz = highPassHz
        }
    }

    public struct Report: Sendable, Equatable {
        /// The 90th-percentile 20 ms frame after the high-pass, nil when there was nothing to
        /// measure.
        public let speechLevelDBFS: Double?
        public let gainDB: Double
        /// Samples the limiter had to hold down.
        public let limitedSamples: Int
        public let peakDBFS: Double
        public let durationSeconds: Double
    }

    /// Frames quieter than this are not speech and not counted (digital silence, gaps).
    static let floorDBFS: Double = -80
    /// Fewer measurable frames than this (100 ms) and the question is left at unity gain.
    static let minimumFrames = 5

    public static func prepare(
        _ pcm: [Int16], sampleRateHz: Int = 16_000, settings: Settings = Settings()
    ) -> (pcm: [Int16], report: Report) {
        let filtered = highPass(pcm, sampleRateHz: sampleRateHz, cutoffHz: settings.highPassHz)
        let level = speechLevel(filtered, frameSamples: max(1, sampleRateHz / 50))
        let gainDB: Double
        if let fixed = settings.fixedGainDB {
            gainDB = fixed
        } else if let level {
            gainDB = min(max(settings.targetDBFS - level, 0), settings.maxGainDB)
        } else {
            gainDB = 0
        }
        let (out, limited) = limit(
            filtered, gain: pow(10, gainDB / 20), ceiling: pow(10, settings.limitDBFS / 20) * 32767,
            sampleRateHz: sampleRateHz)
        let peak = out.reduce(0) { max($0, abs(Int($1))) }
        return (
            out,
            Report(
                speechLevelDBFS: level, gainDB: gainDB, limitedSamples: limited,
                peakDBFS: peak == 0 ? -.infinity : 20 * log10(Double(peak) / 32768),
                durationSeconds: Double(pcm.count) / Double(sampleRateHz))
        )
    }

    /// Second-order Butterworth high-pass.
    static func highPass(_ pcm: [Int16], sampleRateHz: Int, cutoffHz: Double) -> [Double] {
        guard cutoffHz > 0, !pcm.isEmpty else { return pcm.map(Double.init) }
        let w0 = 2 * Double.pi * cutoffHz / Double(sampleRateHz)
        let alpha = sin(w0) / (2 * 0.707_106_781)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 + cosW0) / 2 / a0
        let b1 = -(1 + cosW0) / a0
        let b2 = b0
        let a1 = -2 * cosW0 / a0
        let a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var out = [Double](repeating: 0, count: pcm.count)
        for i in pcm.indices {
            let x = Double(pcm[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            out[i] = y
        }
        return out
    }

    /// The 90th-percentile frame level in dBFS, ignoring frames below `floorDBFS`.
    static func speechLevel(_ samples: [Double], frameSamples: Int) -> Double? {
        var levels: [Double] = []
        var start = 0
        while start + frameSamples <= samples.count {
            var sum = 0.0
            for i in start..<(start + frameSamples) { sum += samples[i] * samples[i] }
            let rms = (sum / Double(frameSamples)).squareRoot()
            if rms > 0 {
                let db = 20 * log10(rms / 32768)
                if db > floorDBFS { levels.append(db) }
            }
            start += frameSamples
        }
        guard levels.count >= minimumFrames else { return nil }
        levels.sort()
        return levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))]
    }

    /// Applies `gain`, holding peaks under `ceiling`: instant attack, ~50 ms release.
    static func limit(_ samples: [Double], gain: Double, ceiling: Double, sampleRateHz: Int) -> ([Int16], Int) {
        let release = 1 - exp(-1 / (0.05 * Double(sampleRateHz)))
        var envelope = 1.0
        var limited = 0
        var out = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let y = samples[i] * gain
            let magnitude = abs(y)
            if magnitude * envelope > ceiling {
                envelope = ceiling / magnitude
                limited += 1
            } else {
                envelope += (1 - envelope) * release
                if magnitude * envelope > ceiling { envelope = ceiling / magnitude }
            }
            out[i] = Int16(clamping: Int((y * envelope).rounded()))
        }
        return (out, limited)
    }
}
