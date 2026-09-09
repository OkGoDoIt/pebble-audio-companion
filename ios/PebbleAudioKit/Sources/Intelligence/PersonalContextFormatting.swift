import Foundation

// Port of `core/ai/.../PersonalContextFormatting.kt`, since rebuilt around the consumers'
// real limits — see `PersonalContextBudget` for every number and where it comes from.

/// Budgeted formatting of `PersonalContext` for injection into transcription and AI pipelines.
///
/// One person's stored context is not one size. The same `PersonalContext` has to become a
/// 224-token keyword list for OpenAI, up to 10,000 characters of prose for Soniox, at most 100
/// short phrases for Apple's on-device recognizer, and a ~1,600-character block inside a
/// 4,096-token on-device chat window. The old single "clamp the whole thing" path served all
/// four from two hand-picked character constants, which meant a large real profile (3,507-char
/// bio, 3,082 contacts) overflowed one budget while leaving another two-thirds empty and, worst
/// of all, silently dropped the entire "known people" list from every AI prompt.
///
/// What the user typed is never modified — this only chooses what fits.
public enum PersonalContextFormatting {
    /// Soniox `context.text` budget. Soniox *errors* above 10,000 characters rather than
    /// trimming, so this leaves margin; see `PersonalContextBudget`.
    public static let sonioxTextBudgetChars = PersonalContextBudget.sonioxContextBudgetChars

    /// OpenAI file STT prompt: a keyword list, sized in tokens against the documented
    /// 224-token limit rather than in characters. Kept as a character ceiling too, because
    /// belt-and-braces on a limit whose overflow is silent costs nothing.
    public static let openAiSttPromptMaxChars = 1_000

    /// On-device / chat grounding block budget.
    public static let aiGroundingBudgetChars = PersonalContextBudget.aiGroundingBudgetChars

    /// Max terms in an extracted keyword list.
    public static let maxDerivedTerms = 40

    /// Soniox `context.text`. This is the one consumer with room for prose, so it gets the
    /// bio in full (a 3,507-character bio is a third of its budget) plus the ranked people
    /// and organizations — the same shape as before, just chosen rather than sampled.
    public static func transcriptionText(
        _ context: PersonalContext, budgetChars: Int = sonioxTextBudgetChars
    ) -> String? {
        guard context.biasTranscription else { return nil }
        let raw = contextText(context, profileChars: budgetChars, peopleLimit: 60)
        guard !raw.isBlank else { return nil }
        return clamp(raw, maxChars: budgetChars)
    }

    /// The bias-term list, ordered least-important-first (see `PersonalContextSelection`).
    ///
    /// Ranked and shape-filtered now: a 3,082-entry contact list contributed its first five
    /// alphabetical-by-import-order entries before, chosen by nothing at all, and included
    /// phone numbers and app handles.
    public static func transcriptionTerms(
        _ context: PersonalContext, maxTerms: Int = maxDerivedTerms
    ) -> [String] {
        guard context.biasTranscription else { return [] }
        let ranked = PersonalContextSelection.rank(context).terms
        return Array(ranked.suffix(maxTerms))
    }

    /// The `prompt` field of `POST /v1/audio/transcriptions`.
    ///
    /// Budgeted in tokens, not characters: the documented ceiling is 224 tokens and name lists
    /// tokenize at ~3.5 characters per token (worse for non-Latin names), so the old 800-char
    /// clamp permitted roughly 243 tokens — over the limit, and truncated from the wrong end.
    public static func openAiSttPrompt(
        _ context: PersonalContext,
        tokenBudget: Int = PersonalContextBudget.openAiSttPromptTokenBudget
    ) -> String? {
        guard context.biasTranscription else { return nil }
        let ascending = PersonalContextSelection.rank(context).terms
        let fitted = PersonalContextSelection.fitTerms(ascending, tokenBudget: tokenBudget)
        guard !fitted.isEmpty else { return nil }
        // The character ceiling can only ever bind after the token budget already has, so a
        // cut here removes whole leading (least important) terms rather than half a name.
        return dropLeadingTerms(fitted, toFit: openAiSttPromptMaxChars)
    }

    /// Contextual strings for Apple's on-device recognizer: at most 100 phrases of one to
    /// three words each, most important first.
    ///
    /// Nothing calls this yet. `SpeechAnalyzerProvider` — the default local engine — passes no
    /// contextual strings at all, so a local-transcription user gets no benefit from About You
    /// today. This is the shape that path needs when it is wired up.
    public static func appleContextualStrings(
        _ context: PersonalContext,
        maxPhrases: Int = PersonalContextBudget.appleContextualStringsMaxPhrases
    ) -> [String] {
        guard context.biasTranscription else { return [] }
        return PersonalContextSelection.rank(context).terms
            .reversed()
            .filter {
                $0.split(separator: " ").count <= PersonalContextBudget.appleContextualStringMaxWords
            }
            .prefix(maxPhrases)
            .map { $0 }
    }

    /// The block prepended to every AI system prompt, on-device and remote.
    ///
    /// Partitioned rather than first-come-first-served. Previously the bio was emitted first
    /// and the whole 2,000 characters went to it, so for anyone with a bio longer than about
    /// 350 words the "Known people" section — the only part of About You measured to change an
    /// answer — never appeared in a single prompt. Now the profile has its own slice, the
    /// people have a reserved one, and the profile's slice ends on a paragraph or sentence
    /// boundary instead of mid-word.
    public static func aiGroundingBlock(
        _ context: PersonalContext, budgetChars: Int = aiGroundingBudgetChars
    ) -> String? {
        guard context.groundAi else { return nil }
        let raw = groundingBody(context, budgetChars: budgetChars)
        guard !raw.isBlank else { return nil }
        let block = ("About the user / known context:\n" + raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return block.count > 20 ? block : nil
    }

    private static func groundingBody(_ context: PersonalContext, budgetChars: Int) -> String {
        // Scale the partition if a caller passes a smaller budget than the default, so the
        // reserves stay proportional instead of one section eating a tiny budget whole.
        let scale = Double(budgetChars) / Double(PersonalContextBudget.aiGroundingBudgetChars)
        let profileChars = max(
            0, Int(Double(PersonalContextBudget.aiGroundingProfileChars) * scale))
        let peopleChars = max(0, Int(Double(PersonalContextBudget.aiGroundingPeopleChars) * scale))
        let extrasChars = max(0, Int(Double(PersonalContextBudget.aiGroundingExtrasChars) * scale))

        let ranked = PersonalContextSelection.rank(context)
        var sections: [String] = []
        var spare = 0

        if let profile = context.profileText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !profile.isEmpty
        {
            let extract = PersonalContextSelection.profileExtract(profile, maxChars: profileChars)
            if !extract.isEmpty {
                sections.append(extract)
                spare += profileChars - extract.count
            }
        } else {
            spare += profileChars
        }

        // Unspent profile budget rolls forward — a user with a two-line bio should get more
        // names, not a shorter block.
        let peopleBudget = peopleChars + max(0, spare)
        let peopleBlock = peopleSection(
            ranked.people, maxChars: peopleBudget,
            maxPeople: PersonalContextBudget.aiGroundingMaxPeople)
        if !peopleBlock.isEmpty {
            sections.append(peopleBlock)
            spare = max(0, peopleBudget - peopleBlock.count)
        }

        var extras: [String] = []
        var extrasLeft = extrasChars + max(0, spare)
        if !ranked.orgs.isEmpty {
            let line = joinedLine(label: "Organizations", ranked.orgs, maxChars: extrasLeft)
            if !line.isEmpty {
                extras.append(line)
                extrasLeft -= line.count
            }
        }
        if !context.topics.isEmpty {
            let line = joinedLine(label: "Topics", context.topics, maxChars: extrasLeft)
            if !line.isEmpty {
                extras.append(line)
                extrasLeft -= line.count
            }
        }
        if !context.terms.isEmpty {
            let line = joinedLine(
                label: "Vocabulary", context.terms.map(\.text), maxChars: extrasLeft)
            if !line.isEmpty { extras.append(line) }
        }
        sections.append(contentsOf: extras)

        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Known people" as whole rows. A row is emitted complete or not at all — a truncated
    /// roster reads as a complete one, and a model asked to correct a misheard name against a
    /// half-written one will produce a confidently wrong correction.
    private static func peopleSection(
        _ people: [KnownPerson], maxChars: Int, maxPeople: Int
    ) -> String {
        guard !people.isEmpty, maxPeople > 0 else { return "" }
        let header = "Known people:\n"
        guard maxChars > header.count else { return "" }
        var out = header
        var emitted = 0
        for person in people.prefix(maxPeople) {
            let detail = [person.role, person.organization, person.relationship]
                .compactMap { $0 }
                .filter { !$0.isBlank }
                .joined(separator: ", ")
            var row = "- " + person.name
            let aliases = person.aliases.filter {
                PersonalContextSelection.isNameShaped($0)
                    && !PersonalContextSelection.containsWord(
                        person.name.lowercased(), $0.lowercased())
            }
            if !aliases.isEmpty { row += " (aka \(aliases.joined(separator: ", ")))" }
            if !detail.isEmpty { row += ": " + detail }
            row += "\n"
            if out.count + row.count > maxChars { break }
            out += row
            emitted += 1
        }
        return emitted == 0 ? "" : String(out.dropLast())
    }

    /// `Label: a, b, c` truncated only at a comma — never in the middle of a name.
    private static func joinedLine(label: String, _ values: [String], maxChars: Int) -> String {
        let prefix = "\(label): "
        guard maxChars > prefix.count + 2 else { return "" }
        var out = prefix
        var first = true
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let piece = first ? trimmed : ", " + trimmed
            if out.count + piece.count > maxChars { break }
            out += piece
            first = false
        }
        return first ? "" : out
    }

    /// Drops whole terms from the FRONT (the least important end) until the joined list fits.
    private static func dropLeadingTerms(_ ascending: [String], toFit maxChars: Int) -> String {
        var terms = ascending
        while terms.count > 1, terms.joined(separator: ", ").count > maxChars {
            terms.removeFirst()
        }
        let joined = terms.joined(separator: ", ")
        // A single term longer than the ceiling is pathological; sending nothing beats sending
        // half a name, which a speech model would happily bias toward.
        return joined.count <= maxChars ? joined : ""
    }

    /// The prose form used by Soniox, where there is genuine room for it.
    private static func contextText(
        _ context: PersonalContext, profileChars: Int, peopleLimit: Int
    ) -> String {
        let ranked = PersonalContextSelection.rank(context)
        var out = ""
        if let profile = context.profileText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !profile.isEmpty
        {
            out += PersonalContextSelection.profileExtract(profile, maxChars: profileChars) + "\n"
        }
        let people = peopleSection(
            ranked.people, maxChars: Int.max, maxPeople: peopleLimit)
        if !people.isEmpty { out += people + "\n" }
        if !ranked.orgs.isEmpty {
            out += "Organizations: \(ranked.orgs.prefix(40).joined(separator: ", "))\n"
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

    /// Last-resort ceiling. Sentence-safe so a clamp never lands mid-word; the callers above
    /// all pack whole units, so this only fires on a single oversized unit.
    private static func clamp(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return PersonalContextSelection.sentenceSafePrefix(text, maxChars: maxChars - 1) + "…"
    }
}
