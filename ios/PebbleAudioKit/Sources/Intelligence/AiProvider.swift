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
    /// The `[n]` this excerpt is labelled with in the prompt, for templates that ask the model
    /// to cite its sources. The number is what the answer carries, so it is what maps a chip in
    /// the UI back to this segment - never the raw segment id, which models copy into prose.
    public let citationNumber: Int?

    public init(
        segmentId: String,
        text: String,
        startTimeMs: Int64? = nil,
        endTimeMs: Int64? = nil,
        timeLabel: String? = nil,
        citationNumber: Int? = nil
    ) {
        self.segmentId = segmentId
        self.text = text
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.timeLabel = timeLabel
        self.citationNumber = citationNumber
    }
}

public struct AiPromptTemplate: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let systemPrompt: String
    public let userPrompt: String
    /// True for templates whose output is read alongside the recording, so every point should
    /// carry the `[n]` of the excerpt it came from. Off for prose the user sends on (the
    /// follow-up email) and for output a parser consumes (action items, the daily summary).
    public let citesSources: Bool

    public init(
        id: String, title: String, systemPrompt: String, userPrompt: String,
        citesSources: Bool = false
    ) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.citesSources = citesSources
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, systemPrompt, userPrompt, citesSources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        citesSources = try container.decodeIfPresent(Bool.self, forKey: .citesSources) ?? false
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
