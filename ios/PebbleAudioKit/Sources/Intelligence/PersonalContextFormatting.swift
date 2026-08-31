import Foundation

// Port of `core/ai/.../PersonalContextFormatting.kt`.

/// Budgeted formatting of `PersonalContext` for injection into transcription and AI
/// pipelines. Keeps slices small for on-device context windows and OpenAI realtime prompt
/// limits.
public enum PersonalContextFormatting {
    /// Soniox `context.text` budget (~10k chars per Soniox docs).
    public static let sonioxTextBudgetChars = 10_000

    /// OpenAI file STT prompt: short keyword list only.
    public static let openAiSttPromptMaxChars = 800

    /// On-device / chat grounding block budget.
    public static let aiGroundingBudgetChars = 2_000

    /// Max terms in an extracted keyword list.
    public static let maxDerivedTerms = 40

    public static func transcriptionText(
        _ context: PersonalContext, budgetChars: Int = sonioxTextBudgetChars
    ) -> String? {
        guard context.biasTranscription else { return nil }
        let raw = contextTextForGrounding(context)
        guard !raw.isBlank else { return nil }
        return clamp(raw, maxChars: budgetChars)
    }

    public static func transcriptionTerms(
        _ context: PersonalContext, maxTerms: Int = maxDerivedTerms
    ) -> [String] {
        guard context.biasTranscription else { return [] }
        var importedTerms: [String] = []
        importedTerms.append(contentsOf: context.terms.map { $0.text })
        importedTerms.append(
            contentsOf: context.people.flatMap { person in [person.name] + person.aliases })
        importedTerms.append(contentsOf: context.orgs)
        var seen = Set<String>()
        return (context.derivedTerms + importedTerms)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .prefix(maxTerms)
            .map { $0 }
    }

    public static func openAiSttPrompt(_ context: PersonalContext) -> String? {
        let terms = transcriptionTerms(context)
        guard !terms.isEmpty else { return nil }
        return clamp(terms.joined(separator: ", "), maxChars: openAiSttPromptMaxChars)
    }

    public static func aiGroundingBlock(
        _ context: PersonalContext, budgetChars: Int = aiGroundingBudgetChars
    ) -> String? {
        guard context.groundAi else { return nil }
        let raw = contextTextForGrounding(context)
        guard !raw.isBlank else { return nil }
        let block = ("About the user / known context:\n" + clamp(raw, maxChars: budgetChars - 40))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return block.count > 20 ? block : nil
    }

    private static func contextTextForGrounding(_ context: PersonalContext) -> String {
        var out = ""
        if let profile = context.profileText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !profile.isEmpty
        {
            out += profile + "\n"
        }
        if !context.people.isEmpty {
            out += "Known people:\n"
            for person in context.people.prefix(50) {
                let detail = [person.role, person.organization, person.relationship]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                out += "- " + person.name
                if !person.aliases.isEmpty {
                    out += " (aka \(person.aliases.joined(separator: ", ")))"
                }
                if !detail.isBlank { out += ": " + detail }
                out += "\n"
            }
        }
        if !context.orgs.isEmpty {
            out += "Organizations: \(context.orgs.prefix(40).joined(separator: ", "))\n"
        }
        if !context.topics.isEmpty {
            out += "Topics: \(context.topics.prefix(40).joined(separator: ", "))\n"
        }
        if !context.terms.isEmpty {
            let vocab = context.terms.prefix(40).map { $0.text }.joined(separator: ", ")
            out += "Vocabulary: \(vocab)\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clamp(_ text: String, maxChars: Int) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars - 3)) + "..."
    }
}
