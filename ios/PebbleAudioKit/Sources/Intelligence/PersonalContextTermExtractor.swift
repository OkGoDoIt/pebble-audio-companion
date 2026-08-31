import Foundation

// Port of `core/ai/.../PersonalContextTermExtractor.kt`.

/// Extracts a bounded keyword list from pasted profile text via `AiModeRouter` for OpenAI STT
/// steering. Prefers on-device (no consent); no-ops cleanly when unavailable.
public final class PersonalContextTermExtractor: @unchecked Sendable {
    private let router: AiModeRouter?
    private let maxTerms: Int
    private let extractionTemplate: AiPromptTemplate

    public init(
        router: AiModeRouter?, maxTerms: Int = PersonalContextFormatting.maxDerivedTerms
    ) {
        self.router = router
        self.maxTerms = maxTerms
        self.extractionTemplate = AiPromptTemplate(
            id: "personal-context-terms",
            title: "Extract vocabulary terms",
            systemPrompt:
                "Extract proper nouns, names, product names, jargon, and acronyms from the user's profile text.\n"
                + "Output ONLY a comma-separated list of terms (no prose, no numbering).\n"
                + "Include up to \(maxTerms) terms. Omit generic words.",
            userPrompt: "Extract terms from this profile text:"
        )
    }

    /// Returns extracted terms, or empty on unavailable provider/consent/failure. Never
    /// throws into the caller except `CancellationError`.
    public func extract(profileText: String) async throws -> [String] {
        let trimmed = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let activeRouter = router else { return [] }
        guard await activeRouter.isAvailable() else { return [] }

        let request = AiRunRequest(
            requestId: "ctx-terms-\(PersonalContextHash.of(trimmed))",
            prompt: extractionTemplate,
            transcripts: [TranscriptExcerpt(segmentId: "profile", text: trimmed)]
        )
        do {
            let result = try await activeRouter.run(request)
            return parseTerms(result.text)
        } catch let error where error is CancellationError {
            throw error
        } catch {
            return []
        }
    }

    private func parseTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isBlank && $0.count <= 80 }
            .filter { seen.insert($0).inserted }
            .prefix(maxTerms)
            .map { $0 }
    }

    /// Updates `context` with cached `derivedTerms` when `profileText` changes; runs
    /// extraction when needed.
    public func refreshDerivedTerms(_ context: PersonalContext) async throws -> PersonalContext {
        guard let hash = context.profileTextHash() else {
            var cleared = context
            cleared.derivedTerms = []
            cleared.derivedTermsSourceHash = nil
            return cleared
        }
        if hash == context.derivedTermsSourceHash && !context.derivedTerms.isEmpty {
            return context
        }
        let terms = try await extract(profileText: context.profileText ?? "")
        var updated = context
        updated.derivedTerms = terms
        updated.derivedTermsSourceHash = hash
        return updated
    }
}
