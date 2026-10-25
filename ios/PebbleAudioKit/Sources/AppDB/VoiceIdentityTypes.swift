import Foundation

public enum VoiceRecognitionMode: String, Codable, Sendable { case off, local }
public struct VoiceRecognitionConfiguration: Equatable, Sendable {
    public var mode: VoiceRecognitionMode
    public var generation: Int64
    public var corpusRevision: Int64
    public var enabledAtMs: Int64?
    public init(mode: VoiceRecognitionMode = .off, generation: Int64 = 0, corpusRevision: Int64 = 0, enabledAtMs: Int64? = nil) {
        self.mode = mode; self.generation = generation; self.corpusRevision = corpusRevision; self.enabledAtMs = enabledAtMs
    }
}
public struct VoiceSourceState: Equatable, Sendable {
    public var segmentId: String
    public var revision: String
    public var generation: Int64
    public init(segmentId: String, revision: String, generation: Int64) {
        self.segmentId = segmentId; self.revision = revision; self.generation = generation
    }
}
public struct VoiceWorkToken: Equatable, Sendable {
    public var configGeneration: Int64
    public var corpusRevision: Int64
    public var sourceGeneration: Int64
    public var sourceRevision: String
    public init(configGeneration: Int64, corpusRevision: Int64, sourceGeneration: Int64, sourceRevision: String) {
        self.configGeneration = configGeneration; self.corpusRevision = corpusRevision
        self.sourceGeneration = sourceGeneration; self.sourceRevision = sourceRevision
    }
}

/// An explicit human-confirmed crop. JSON preserves the complete embedding recipe and values;
/// AppDB does not interpret vectors or depend on an inference runtime. No raw audio is copied.
public struct VoiceConfirmedExample: Equatable, Sendable {
    public var id, personId, confirmationID, sessionID, segmentId, sourceRevision, recipeID: String
    public var startMediaMs, endMediaMs, createdAtMs: Int64
    public var recipeJSON, embeddingJSON, qualityJSON: Data
    public init(id: String = UUID().uuidString.lowercased(), personId: String,
                confirmationID: String, sessionID: String, segmentId: String,
                startMediaMs: Int64, endMediaMs: Int64, sourceRevision: String,
                recipeID: String, recipeJSON: Data, embeddingJSON: Data, qualityJSON: Data,
                createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.personId = personId; self.confirmationID = confirmationID
        self.sessionID = sessionID; self.segmentId = segmentId; self.startMediaMs = startMediaMs
        self.endMediaMs = endMediaMs; self.sourceRevision = sourceRevision; self.recipeID = recipeID
        self.recipeJSON = recipeJSON; self.embeddingJSON = embeddingJSON; self.qualityJSON = qualityJSON
        self.createdAtMs = createdAtMs
    }
}
public struct VoiceWorkContext: Sendable {
    public var configuration: VoiceRecognitionConfiguration
    public var source: VoiceSourceState
    public var examples: [VoiceConfirmedExample]
    public var token: VoiceWorkToken {
        VoiceWorkToken(configGeneration: configuration.generation, corpusRevision: configuration.corpusRevision,
                       sourceGeneration: source.generation, sourceRevision: source.revision)
    }
}
public struct VoiceProfileSummary: Equatable, Sendable {
    public var person: Person
    public var exampleCount: Int
    public var updatedAtMs: Int64
    public var recipeIDs: [String]
    public init(person: Person, exampleCount: Int, updatedAtMs: Int64, recipeIDs: [String]) {
        self.person = person; self.exampleCount = exampleCount; self.updatedAtMs = updatedAtMs; self.recipeIDs = recipeIDs
    }
}

public enum VoiceAttributionDisposition: String, Codable, Sendable { case recognized, suggestion }
public struct VoiceAutomaticAttribution: Equatable, Sendable {
    public var id, personId, segmentId, sourceRevision, recipeID, calibrationID, runID: String
    public var startMediaMs, endMediaMs, createdAtMs: Int64
    public var score: Double
    public var margin: Double?
    public var disposition: VoiceAttributionDisposition
    public init(id: String = UUID().uuidString.lowercased(), personId: String, segmentId: String,
                startMediaMs: Int64, endMediaMs: Int64, sourceRevision: String, recipeID: String,
                score: Double, margin: Double?, calibrationID: String, runID: String,
                disposition: VoiceAttributionDisposition = .recognized,
                createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.personId = personId; self.segmentId = segmentId
        self.startMediaMs = startMediaMs; self.endMediaMs = endMediaMs
        self.sourceRevision = sourceRevision; self.recipeID = recipeID; self.score = score
        self.margin = margin; self.calibrationID = calibrationID; self.runID = runID
        self.disposition = disposition; self.createdAtMs = createdAtMs
    }
}
public struct VoiceResolvedAttribution: Equatable, Sendable {
    public var attribution: VoiceAutomaticAttribution
    public var person: Person
    public init(attribution: VoiceAutomaticAttribution, person: Person) {
        self.attribution = attribution; self.person = person
    }
}
public enum VoiceAutomaticResolution: Equatable, Sendable {
    case named(VoiceResolvedAttribution), partial
}
public enum VoiceJobState: String, Sendable { case pending, running, done, failed, cancelled }
public struct VoiceRecognitionJob: Equatable, Sendable {
    public var id, runID, segmentId, recipeID: String
    public var startMediaMs, endMediaMs, cursorMediaMs, updatedAtMs: Int64
    public var token: VoiceWorkToken
    public var state: VoiceJobState
    public var attempts: Int
    public var lastError: String?
}
public struct VoiceRunSummary: Equatable, Sendable {
    public var runID: String
    public var pending, running, done, failed, cancelled: Int
    public var completedMediaMs, totalMediaMs, updatedAtMs: Int64
}
public enum VoiceIdentityError: Error, Equatable, Sendable {
    case invalidRecord, sourceDeleted, sourceInvalidated, missingSource, disabled, capacityExceeded
}
