import Foundation

// Port of `core/ai/.../AiProvider.kt` — the FIXED AI-provider seam shared by the mode router,
// providers, enrichment, recap, follow-ups, and Ask. Change only with a coordinated change.

/// Raw values match the Kotlin enum names (persisted by name in the old app's settings).
public enum AiProcessingMode: String, CaseIterable, Sendable, Codable {
    case localOnly = "LocalOnly"
    case remoteOnly = "RemoteOnly"
    case localFirst = "LocalFirst"
    case remoteFirst = "RemoteFirst"
}

public struct TranscriptExcerpt: Sendable, Equatable, Codable {
    public let segmentId: String
    public let text: String
    public let startTimeMs: Int64?
    public let endTimeMs: Int64?
    /// Human-readable local start time (e.g. "2026-08-29 21:35"); preferred over raw epoch ms.
    public let timeLabel: String?

    public init(
        segmentId: String,
        text: String,
        startTimeMs: Int64? = nil,
        endTimeMs: Int64? = nil,
        timeLabel: String? = nil
    ) {
        self.segmentId = segmentId
        self.text = text
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.timeLabel = timeLabel
    }
}

public struct AiPromptTemplate: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let systemPrompt: String
    public let userPrompt: String

    public init(id: String, title: String, systemPrompt: String, userPrompt: String) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }
}

public struct AiRunRequest: Sendable {
    public let requestId: String
    public let prompt: AiPromptTemplate
    public let transcripts: [TranscriptExcerpt]
    public let metadata: [String: String]

    /// AI runs require durable transcript input (`transcripts` must be non-empty).
    public init(
        requestId: String,
        prompt: AiPromptTemplate,
        transcripts: [TranscriptExcerpt],
        metadata: [String: String] = [:]
    ) {
        precondition(!transcripts.isEmpty, "AI runs require durable transcript input")
        self.requestId = requestId
        self.prompt = prompt
        self.transcripts = transcripts
        self.metadata = metadata
    }
}

public struct AiProviderResult: Sendable, Equatable {
    public let text: String
    public let modelUsed: String?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(
        text: String, modelUsed: String? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil
    ) {
        self.text = text
        self.modelUsed = modelUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct RoutedAiResult: Sendable, Equatable {
    public let text: String
    public let modeUsed: AiProcessingMode
    public let providerId: String
    public let modelUsed: String?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(
        text: String, modeUsed: AiProcessingMode, providerId: String,
        modelUsed: String?, inputTokens: Int?, outputTokens: Int?
    ) {
        self.text = text
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AiError: Error, Sendable {
    case providerUnavailable(providerId: String)
    /// ConsentRequired NEVER falls back (plan Part 4.5).
    case consentRequired(providerId: String)
    case providerFailed(String, underlying: Error? = nil)
}

public protocol AiProvider: Sendable {
    var id: String { get }

    func isAvailable() async -> Bool

    func run(_ request: AiRunRequest) async throws -> AiProviderResult
}
