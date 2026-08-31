import Foundation

// Port of `core/ai/.../AiModels.kt`.

/// Catalog entry for a remote AI model the user can pick for automatic titles/summaries and
/// the manual AI flow. The id is sent verbatim as the API `model`; display strings drive the
/// Settings picker.
public struct AiModelSpec: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let recommended: Bool

    public init(id: String, displayName: String, description: String, recommended: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.recommended = recommended
    }
}

public enum AiModels {
    public static let defaultModelId = "gpt-5.6-luna"

    public static let all: [AiModelSpec] = [
        AiModelSpec(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            description: "Fast and inexpensive, with a million-token context for long days of "
                + "transcript. Recommended for automatic titles and summaries.",
            recommended: true
        ),
        AiModelSpec(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            description: "Balances intelligence and cost. Stronger on long, noisy, or "
                + "many-speaker transcripts; roughly ten times Luna's price."
        ),
        AiModelSpec(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "Frontier model for demanding questions across a whole archive. Best "
                + "answers, highest cost."
        ),
    ]

    /// Ids from earlier versions of this catalog, mapped to the closest current model so a
    /// stored preference keeps its intent — a budget pick stays budget, a frontier pick stays
    /// frontier — instead of collapsing to the default. Resolve through `byId` before sending
    /// a stored id as the API `model`, so what we call always matches what Settings shows.
    private static let legacyReplacements: [String: String] = [
        "gpt-5.4-nano": "gpt-5.6-luna",
        "gpt-5.4-mini": "gpt-5.6-luna",
        "gpt-5.4": "gpt-5.6-terra",
        "gpt-5.5": "gpt-5.6-sol",
    ]

    public static let `default`: AiModelSpec = all.first { $0.id == defaultModelId }!

    public static func byId(_ id: String?) -> AiModelSpec {
        if let match = all.first(where: { $0.id == id }) { return match }
        if let id, let replacement = legacyReplacements[id],
            let match = all.first(where: { $0.id == replacement })
        {
            return match
        }
        return `default`
    }
}
