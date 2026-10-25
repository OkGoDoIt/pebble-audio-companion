import Foundation

/// All fields participate in compatibility. A shared dimension alone is never sufficient.
public struct SpeakerEmbeddingRecipe: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let weightsSHA256: String
    public let runtimeID: String
    public let preprocessingID: String
    public let dimensions: Int

    public init(modelID: String, modelRevision: String, weightsSHA256: String,
                runtimeID: String, preprocessingID: String, dimensions: Int) {
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.weightsSHA256 = weightsSHA256
        self.runtimeID = runtimeID
        self.preprocessingID = preprocessingID
        self.dimensions = dimensions
    }
}

public enum SpeakerRecognitionError: Error, Equatable, Sendable {
    case disabled
    case unsupportedPlatform
    case invalidAudio(String)
    case invalidEmbedding
    case incompatibleRecipe
    case invalidPolicy
    case invalidCorpus(String)
    case modelVerificationFailed(String)
    case modelLoadFailed(String)
    case nativeFailure(String)
}

public struct SpeakerEmbedding: Codable, Equatable, Sendable {
    public let recipe: SpeakerEmbeddingRecipe
    /// Unit length. Revalidated after decoding at the matching boundary.
    public let values: [Float]

    public init(recipe: SpeakerEmbeddingRecipe, values: [Float]) throws {
        self.recipe = recipe
        self.values = try Self.normalized(values, dimensions: recipe.dimensions)
    }

    static func normalized(_ values: [Float], dimensions: Int) throws -> [Float] {
        guard dimensions > 0, dimensions <= 16_384, values.count == dimensions,
              values.allSatisfy({ $0.isFinite }) else {
            throw SpeakerRecognitionError.invalidEmbedding
        }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-12 else { throw SpeakerRecognitionError.invalidEmbedding }
        return values.map { Float(Double($0) / norm) }
    }

    public func cosineSimilarity(to other: SpeakerEmbedding) throws -> Double {
        guard recipe == other.recipe else { throw SpeakerRecognitionError.incompatibleRecipe }
        let a = try Self.normalized(values, dimensions: recipe.dimensions)
        let b = try Self.normalized(other.values, dimensions: recipe.dimensions)
        return min(1, max(-1, zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }))
    }
}

/// Caller-supplied evidence about the exact crop, not an acoustic claim inferred from energy.
public struct SpeakerAudioEvidence: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceRevision: String
    public let sessionID: String
    public let startSample: Int
    public let endSample: Int
    public let speechOnly: Bool
    public let singleSpeaker: Bool
    public let containsDiscontinuity: Bool

    public init(sourceID: String, sourceRevision: String, sessionID: String,
                startSample: Int, endSample: Int, speechOnly: Bool,
                singleSpeaker: Bool, containsDiscontinuity: Bool) {
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.sessionID = sessionID
        self.startSample = startSample
        self.endSample = endSample
        self.speechOnly = speechOnly
        self.singleSpeaker = singleSpeaker
        self.containsDiscontinuity = containsDiscontinuity
    }
}

public struct SpeakerAudioQuality: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let rmsDBFS: Double
    public let clippedFraction: Double
}

/// Already cropped, signed 16-bit little-endian mono PCM, at exactly 16 kHz.
/// Use original decoded audio; do not reuse transcription's optional gain/denoising path.
public struct SpeakerAudioSample: Sendable {
    public let pcm16LE: Data
    public let sampleRate: Int
    public let channels: Int
    public let evidence: SpeakerAudioEvidence

    public init(pcm16LE: Data, sampleRate: Int = 16_000, channels: Int = 1,
                evidence: SpeakerAudioEvidence) {
        self.pcm16LE = pcm16LE
        self.sampleRate = sampleRate
        self.channels = channels
        self.evidence = evidence
    }

    /// Conservative engineering gates, not a calibrated speech or overlap detector.
    /// 2–30 seconds bounds memory/work; enrollment UI should collect several clean crops.
    public func validate() throws -> SpeakerAudioQuality {
        guard sampleRate == 16_000, channels == 1, pcm16LE.count.isMultiple(of: 2) else {
            throw SpeakerRecognitionError.invalidAudio("Expected 16 kHz mono PCM16LE")
        }
        let count = pcm16LE.count / 2
        guard (32_000...480_000).contains(count) else {
            throw SpeakerRecognitionError.invalidAudio("Select 2–30 seconds of speech")
        }
        guard !evidence.sourceID.isEmpty, !evidence.sourceRevision.isEmpty,
              !evidence.sessionID.isEmpty, evidence.startSample >= 0,
              evidence.endSample >= evidence.startSample,
              evidence.endSample - evidence.startSample == count else {
            throw SpeakerRecognitionError.invalidAudio("Missing or inconsistent media range provenance")
        }
        guard evidence.speechOnly, evidence.singleSpeaker, !evidence.containsDiscontinuity else {
            throw SpeakerRecognitionError.invalidAudio("Crop must contain one speaker, speech, and no recording gap")
        }
        var sum = 0.0
        var clipped = 0
        pcm16LE.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let value = Int(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                sum += Double(value) * Double(value)
                if abs(value) >= 32_760 { clipped += 1 }
            }
        }
        let rms = sqrt(sum / Double(count)) / 32_768
        guard rms > 0 else { throw SpeakerRecognitionError.invalidAudio("No audible signal") }
        let db = 20 * log10(rms)
        let clippedFraction = Double(clipped) / Double(count)
        guard db >= -60 else { throw SpeakerRecognitionError.invalidAudio("Signal is too quiet") }
        guard clippedFraction <= 0.01 else { throw SpeakerRecognitionError.invalidAudio("Signal is clipped") }
        return SpeakerAudioQuality(durationSeconds: Double(count) / 16_000,
                                   rmsDBFS: db, clippedFraction: clippedFraction)
    }
}
