import Foundation

/// `VoiceNoteLevel` for audio that is played in pieces: the same high-pass, target, cap, and
/// limiter, with the gain following the last 30 s of audio instead of one whole clip.
///
/// Watch speech sits 20-25 dB below a comfortable listening level, so a recording played as stored
/// is hard to hear. This brings it up while it plays and changes nothing that is stored: the saved
/// frames, and everything transcription and voice recognition read, stay exactly as the watch sent
/// them. Each piece is measured before it is played, so the first one starts at its level; after
/// that the gain rises at most 3 dB a second (a pause does not swell into hiss) and falls at most
/// 12 dB a second, and the limiter holds whatever the gain would clip in between.
public struct PlaybackLevel: Sendable {
    public let settings: VoiceNoteLevel.Settings
    private let sampleRateHz: Int
    private let frameSamples: Int
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var frameEnergy = 0.0
    private var frameCount = 0
    private var levels: [Double] = []
    private var nextLevel = 0
    private var gainDB: Double?
    private var envelope = 1.0

    static let historySeconds = 30
    static let riseDBPerSecond = 3.0
    static let fallDBPerSecond = 12.0

    public init(sampleRateHz: Int = 16_000, settings: VoiceNoteLevel.Settings = .init()) {
        self.settings = settings
        self.sampleRateHz = sampleRateHz
        frameSamples = max(1, sampleRateHz / 50)
        let w0 = 2 * Double.pi * settings.highPassHz / Double(sampleRateHz)
        let alpha = sin(w0) / (2 * 0.707_106_781)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        b0 = (1 + cosW0) / 2 / a0
        b1 = -(1 + cosW0) / a0
        b2 = b0
        a1 = -2 * cosW0 / a0
        a2 = (1 - alpha) / a0
    }

    /// The gain now applied, in dB; nil until something measurable has been heard.
    public var currentGainDB: Double? { gainDB }

    public mutating func process(_ pcm: [Int16]) -> [Int16] {
        guard !pcm.isEmpty else { return pcm }
        var filtered = [Double](repeating: 0, count: pcm.count)
        for i in pcm.indices {
            let x = Double(pcm[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            filtered[i] = y
            frameEnergy += y * y
            frameCount += 1
            if frameCount == frameSamples {
                remember(frameEnergy / Double(frameSamples))
                frameEnergy = 0
                frameCount = 0
            }
        }
        let target = targetGainDB()
        if gainDB == nil, let target { gainDB = target }
        let rise = Self.riseDBPerSecond / Double(sampleRateHz)
        let fall = Self.fallDBPerSecond / Double(sampleRateHz)
        let ceiling = pow(10, settings.limitDBFS / 20) * 32767
        let release = 1 - exp(-1 / (0.05 * Double(sampleRateHz)))
        var gain = gainDB ?? 0
        var out = [Int16](repeating: 0, count: pcm.count)
        for i in filtered.indices {
            if let target { gain += min(max(target - gain, -fall), rise) }
            let y = filtered[i] * pow(10, gain / 20)
            let magnitude = abs(y)
            if magnitude * envelope > ceiling {
                envelope = ceiling / magnitude
            } else {
                envelope += (1 - envelope) * release
                if magnitude * envelope > ceiling { envelope = ceiling / magnitude }
            }
            out[i] = Int16(clamping: Int((y * envelope).rounded()))
        }
        if gainDB != nil { gainDB = gain }
        return out
    }

    private mutating func remember(_ meanSquare: Double) {
        guard meanSquare > 0 else { return }
        let db = 20 * log10(meanSquare.squareRoot() / 32768)
        guard db > VoiceNoteLevel.floorDBFS else { return }
        let capacity = Self.historySeconds * 50
        if levels.count < capacity {
            levels.append(db)
        } else {
            levels[nextLevel] = db
            nextLevel = (nextLevel + 1) % capacity
        }
    }

    private func targetGainDB() -> Double? {
        if let fixed = settings.fixedGainDB { return fixed }
        guard levels.count >= VoiceNoteLevel.minimumFrames else { return nil }
        let sorted = levels.sorted()
        let level = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return min(max(settings.targetDBFS - level, 0), settings.maxGainDB)
    }
}
