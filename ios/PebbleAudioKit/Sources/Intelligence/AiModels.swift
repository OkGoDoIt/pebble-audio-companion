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
    /// Input context window, in tokens. Ask reads as much of the archive as this allows in one
    /// pass and sweeps the remainder in batches, so a wrong number here is the difference
    /// between a complete answer and a silently partial one. Keep it at or below the model's
    /// real limit — `AskBudget` reserves headroom on top.
    public let contextTokens: Int

    public init(
        id: String, displayName: String, description: String, recommended: Bool = false,
        contextTokens: Int = AiModels.conservativeContextTokens
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.recommended = recommended
        self.contextTokens = contextTokens
    }
}

public enum AiModels {
    public static let defaultModelId = "gpt-6-luna"

    /// Assumed window for a model we have no catalog entry for. Deliberately small: reading
    /// less of the archive than we could is a slower answer, reading more than the model can
    /// hold is a failed one.
    public static let conservativeContextTokens = 128_000

    public static let all: [AiModelSpec] = [
        // The GPT-6 family (added 2026-09-30, beside 5.6 rather than in place of it). Ids,
        // windows and prices are from OpenAI's model pages on that date. All three take the
        // Responses API, `reasoning.effort` of low and medium (the two this app sends) and
        // structured outputs, so nothing about the request changes with the model.
        //
        // `contextTokens` is the most INPUT a request may carry: the advertised 1,050,000-token
        // window less the 128,000 tokens reserved for output, 922,000. A prompt over 272,000
        // input tokens is billed at twice the input rate for the whole request.
        AiModelSpec(
            id: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            description: "Fast and the least expensive, with room for a long day of transcript. "
                + "Recommended for automatic titles and summaries.",
            recommended: true,
            contextTokens: 922_000
        ),
        AiModelSpec(
            id: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            description: "Close to the top model on hard questions at a fifth of its price; "
                + "about twenty times GPT-6 Luna's.",
            contextTokens: 922_000
        ),
        AiModelSpec(
            id: "gpt-6-astra",
            displayName: "GPT-6 Astra",
            description: "OpenAI's most capable model, for the most demanding questions across "
                + "a whole archive. By far the highest cost.",
            contextTokens: 922_000
        ),
        // The GPT-5.6 family, kept as options. GPT-5.6 Luna was the default until 2026-09-30;
        // a phone that stored it as a choice keeps it.
        AiModelSpec(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            description: "The previous small model: about twice GPT-6 Luna's price, with a "
                + "million-token context.",
            contextTokens: 1_000_000
        ),
        AiModelSpec(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            description: "Balances intelligence and cost. Stronger on long, noisy, or "
                + "many-speaker transcripts; GPT-6.1 Sol costs slightly less.",
            contextTokens: 400_000
        ),
        AiModelSpec(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "The previous frontier model, at twice GPT-6.1 Sol's price.",
            contextTokens: 400_000
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

    // MARK: - Naming a model that already produced something

    /// The on-device model's recorded id (`FoundationModelsLanguageModel.id`).
    public static let onDeviceModelId = "apple-foundation-models"
    /// Apple Private Cloud Compute's recorded id (`ApplePrivateCloudModel.id`).
    public static let privateCloudModelId = "apple-private-cloud-compute"

    /// The name to show beside something a model WROTE — a recap, a note — from the model id
    /// and provider id stored with it. Nil when nothing was recorded.
    ///
    /// `byId` is for the SETTING: it falls back to the default model, which is right for a
    /// preference and wrong for a record. Used on records, it named everything it did not
    /// recognise "GPT-5.6 Luna" — the on-device model's recaps, Private Cloud Compute's, and
    /// every dated id OpenAI returns (`gpt-5.4-mini-2026-03-17`). A person reading "GPT-5.6
    /// Luna" under a recap the phone wrote is being told the wrong thing about where their
    /// words went. So: Apple's two models by name, OpenAI ids by their catalog family when the
    /// family is known (with or without the date suffix OpenAI adds), and otherwise the id
    /// exactly as recorded — never another model's name.
    public static func displayName(modelUsed: String?, providerId: String? = nil) -> String? {
        let model = modelUsed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (model, providerId) {
        case (onDeviceModelId, _), ("", "apple-foundation-models"), ("", "on-device"):
            return "On-device Apple model"
        case (privateCloudModelId, _), ("", ApplePrivateCloudAiProvider.providerId):
            return "Apple Private Cloud Compute"
        default:
            break
        }
        guard !model.isEmpty else { return nil }
        if let exact = all.first(where: { $0.id == model }) { return exact.displayName }
        let undated = withoutDateSuffix(model)
        if let family = all.first(where: { $0.id == undated }) { return family.displayName }
        return model
    }

    /// "gpt-5.6-luna-2026-09-01" → "gpt-5.6-luna". OpenAI returns the dated snapshot it
    /// actually served under the alias that was asked for.
    static func withoutDateSuffix(_ id: String) -> String {
        guard
            let range = id.range(
                of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression)
        else { return id }
        return String(id[..<range.lowerBound])
    }

    /// The id to SEND for a stored setting: a legacy id resolves to the model Settings shows
    /// for it (`legacyReplacements`), an empty one to the default. An unknown non-empty id is
    /// sent as-is — a model somebody typed or imported is theirs to use.
    public static func resolvedModelId(_ id: String?) -> String {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultModelId }
        if all.contains(where: { $0.id == trimmed }) { return trimmed }
        if let replacement = legacyReplacements[trimmed] { return replacement }
        return trimmed
    }
}
