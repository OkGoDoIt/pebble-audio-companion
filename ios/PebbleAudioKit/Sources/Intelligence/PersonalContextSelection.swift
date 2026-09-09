import Foundation

/// Chooses *which* of a person's stored context is worth a prompt, and packs it without ever
/// cutting a name or a sentence in half.
///
/// The problem this solves, from a real 516 KB `personal_context.json`: 3,082 imported
/// contacts, 52 "organizations" (34 of which are actually calendar event titles — birthdays,
/// flight numbers, "Trivia night"), and a 3,507-character bio. The old formatter took
/// `people.prefix(50)` — Contacts import order — which for that file meant the user's closest friend,
/// their family and the colleague they talk about most were at indices 785, 695 and beyond, and
/// never shipped, while an old forum handle from 2016 and a phone number did.
///
/// Nothing here mutates or discards stored data. The About You screen keeps showing every word
/// the user wrote; this only decides what fits in a prompt.
public enum PersonalContextSelection {

    // MARK: - Shape

    /// Is this string plausibly a name a speech model or a chat model could use?
    ///
    /// Rejects what a Contacts import actually contains alongside people: phone numbers,
    /// app handles (`blue_kite_650`, `zebra123456`), parenthetical notes
    /// (`Sam (Plumber)`, `quorum ( only used for spell correction )`), emoji. On the real
    /// file this drops 351 of 3,082 contacts and 28 of 52 "organizations", every one of them
    /// something we would otherwise have sent to a cloud transcription provider as a bias term.
    /// That last part matters on its own: this is a background-microphone product, and a
    /// contact list is not a vocabulary list.
    public static func isNameShaped(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 48 else { return false }
        // One pass, no intermediate collections: this runs over every stored contact on every
        // transcription and every AI call.
        var letters = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            // Digits are the single strongest junk signal: phone numbers, years, flight
            // numbers, "Casey's 40th Birthday". Real names essentially never carry them.
            if CharacterSet.decimalDigits.contains(scalar) { return false }
            if Self.rejectedPunctuation.contains(scalar) { return false }
            if !scalar.isASCII, scalar.properties.isEmoji { return false }
            if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        guard letters >= 2 else { return false }
        // Mostly-letters: allows "O'Brien", "Jean-Luc", "Grace Lin", rejects "— / —".
        return Double(letters) / Double(total) >= 0.6
    }

    private static let rejectedPunctuation = CharacterSet(charactersIn: "@/\\|<>#&()[]{}©®™*_=+~^$%")

    /// How many ranked people may contribute bias terms. Comfortably above every consumer's
    /// cap (100 phrases for Apple, ~35 terms for OpenAI's 224-token prompt), so it bounds the
    /// work without ever being the thing that decides what ships.
    static let termPoolPeopleLimit = 150

    // MARK: - Ranking

    /// A person's stored context, ordered by how likely it is to matter in a prompt, with the
    /// junk removed and the duplicates collapsed.
    public struct Ranked: Equatable, Sendable {
        /// Most relevant first.
        public var people: [KnownPerson]
        /// Most relevant first.
        public var orgs: [String]
        /// Most relevant LAST, because OpenAI keeps only the final 224 tokens of a
        /// transcription prompt — see `PersonalContextBudget`.
        public var terms: [String]

        public init(people: [KnownPerson] = [], orgs: [String] = [], terms: [String] = []) {
            self.people = people
            self.orgs = orgs
            self.terms = terms
        }
    }

    /// Ranks the whole stored context.
    ///
    /// The ranking signal that does the work is embarrassingly simple and turned out to be the
    /// right one: **a contact whose full name the user typed into their own bio is a person
    /// they actually talk about.** On the real file that selects 10 people out of 3,082 —
    /// family, the book club, the colleague — where import order selected none of them.
    /// `derivedTerms` (an LLM's own reading of the bio) is the second signal, and having an
    /// organization or a multi-word name breaks ties after that.
    public static func rank(_ context: PersonalContext) -> Ranked {
        let profile = context.profileText ?? ""
        let derived = Set(context.derivedTerms.map { $0.lowercased() })
        // Cheap gate before the O(bio) scan below: a name can only be mentioned if its first
        // word is one of the bio's words. `rank` runs on every transcription and every AI call,
        // and 3,000 contacts × a 3,500-character bio is not free.
        let profileWords = Set(
            profile.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })

        var scored: [(person: KnownPerson, lowered: String, score: Int, order: Int)] = []
        scored.reserveCapacity(context.people.count)
        var seenNames = Set<String>()
        for (index, person) in context.people.enumerated() {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isNameShaped(name) else { continue }
            let key = name.lowercased()
            guard seenNames.insert(key).inserted else { continue }  // Contacts exports duplicate
            var score = 0
            let multiWord = name.split(separator: " ").count >= 2
            if mentionsProperNoun(profile, name, words: profileWords) {
                // A single-word contact label collides with ordinary prose far too easily —
                // "Star", "Home", "My Phone" all matched a real bio and outranked the user's
                // own family in the first version of this. A full name is evidence; a first
                // name on its own is a hint.
                score += multiWord ? 100 : 40
            }
            if derived.contains(key) { score += 80 }
            if person.organization?.isBlank == false { score += 10 }
            if person.role?.isBlank == false || person.relationship?.isBlank == false {
                score += 10
            }
            if multiWord { score += 5 }
            scored.append((person, key, score, index))
        }
        // Sort is not stable in Swift, so the import index is part of the key: two contacts
        // with identical evidence must not swap places between launches, or the derived-terms
        // cache and the prompt would churn for no reason.
        scored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }

        // "Hughes" is not a second person when "Owen Hughes" is already on the list — it is the
        // same match, scored twice, and it wastes a slot while reading as a distinct human.
        //
        // Only the head of the ranking is de-fragmented. Comparing all 3,000 contacts against
        // each other is quadratic and measured at 600ms+ per call on a real store — and this
        // runs on every transcription and every AI call, where the tail is never read anyway.
        var people: [KnownPerson] = []
        people.reserveCapacity(scored.count)
        var deFragmented: [String] = []
        for candidate in scored {
            if deFragmented.count < termPoolPeopleLimit {
                let isFragment = deFragmented.contains { other in
                    other != candidate.lowered && containsWord(other, candidate.lowered)
                }
                if isFragment { continue }
                deFragmented.append(candidate.lowered)
            }
            people.append(candidate.person)
        }

        // `orgs` is not organizations. `ContextImportSettings` records the fact plainly —
        // "nothing else in the app has ever written that field" — because it is populated
        // exclusively by the calendar import, from event titles. On one real store 34 of 52
        // entries were birthdays, flight numbers and "Trivia night", and all 52 were being
        // shipped to a cloud speech model as vocabulary and into every AI prompt as facts.
        //
        // Shape alone does not catch "Mia OOO" or "BOOKED - Garden Party", so an
        // organization has to be *corroborated* — named in the bio, or picked out of it by the
        // term extractor — before it earns a speech model's bias budget or a chat model's
        // attention. An uncorroborated calendar title is not evidence of anything. (A contact's
        // employer is unaffected: that lives on `KnownPerson.organization` and still ships with
        // the person's row.)
        var orgScored: [(text: String, score: Int, order: Int)] = []
        var seenOrgs = Set<String>()
        for (index, org) in context.orgs.enumerated() {
            let text = org.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isNameShaped(text), seenOrgs.insert(text.lowercased()).inserted else { continue }
            var score = 0
            if mentionsProperNoun(profile, text, words: profileWords) { score += 100 }
            if derived.contains(text.lowercased()) { score += 80 }
            guard score > 0 else { continue }
            orgScored.append((text, score, index))
        }
        orgScored.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }

        return Ranked(
            people: people,
            orgs: orgScored.map(\.text),
            terms: rankedTerms(context, people: people, orgs: orgScored.map(\.text))
        )
    }

    /// Does `name` appear in `profile` as a proper noun — whole words, and capitalised where
    /// the script has case?
    ///
    /// The capitalisation requirement is what separates a contact called "Star" from the word
    /// "star", and it is why "my phone" in a bio no longer promotes a contact card called
    /// "My Phone" above the user's own children. Scripts without case (CJK, and any name whose
    /// first letter is already uncased) skip the test rather than fail it.
    static func mentionsProperNoun(_ profile: String, _ name: String, words: Set<String>) -> Bool {
        guard !name.isEmpty, !profile.isEmpty else { return false }
        guard let firstWord = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first(where: { !$0.isEmpty })
        else { return false }
        guard words.contains(firstWord) else { return false }
        // Match case-insensitively (a contact may be stored "MAY LIN") but demand that the
        // occurrence *in the bio* is capitalised, which is the actual proper-noun evidence.
        var searchRange = profile.startIndex..<profile.endIndex
        while let found = profile.range(
            of: name, options: [.caseInsensitive], range: searchRange)
        {
            let beforeOk =
                found.lowerBound == profile.startIndex
                || !isWordScalar(profile[profile.index(before: found.lowerBound)])
            let afterOk =
                found.upperBound == profile.endIndex || !isWordScalar(profile[found.upperBound])
            let initial = profile[found.lowerBound]
            if beforeOk, afterOk, !(initial.isCased && initial.isLowercase) { return true }
            guard found.lowerBound < profile.endIndex else { return false }
            searchRange = profile.index(after: found.lowerBound)..<profile.endIndex
        }
        return false
    }

    /// The bias-term list, ordered **least important first**.
    ///
    /// Backwards on purpose: OpenAI keeps only the final 224 tokens of a transcription prompt
    /// and silently drops everything before them, so anything we lose to that must be the
    /// material we cared about least. The old code did the opposite — it clamped the head of
    /// the list, so the derived terms it deliberately put first were exactly the ones the API
    /// would have thrown away.
    private static func rankedTerms(
        _ context: PersonalContext, people: [KnownPerson], orgs: [String]
    ) -> [String] {
        // Ascending importance: organizations, then contacts (already relevance-ordered, so
        // reversed here), then the bio's own derived terms, then vocabulary the user typed by
        // hand — which is the most deliberate signal there is and therefore goes last.
        // Only the top-ranked people contribute terms. Every consumer of this list caps well
        // below a hundred, so materialising 3,000 names on every transcription would be pure
        // waste — and the tail of the ranking is by definition the part no budget will reach.
        var ordered: [String] = []
        ordered.append(contentsOf: orgs.reversed())
        for person in people.prefix(termPoolPeopleLimit).reversed() {
            // A two-letter alias ("My" from a contact card called "My Phone") is a decoding
            // hazard, not a name.
            ordered.append(contentsOf: person.aliases.filter { $0.count >= 3 && isNameShaped($0) })
            ordered.append(person.name)
        }
        ordered.append(contentsOf: context.derivedTerms.filter(isNameShaped))
        ordered.append(contentsOf: context.terms.map(\.text).filter(isNameShaped))

        // Last occurrence wins, so a term that is both a contact and hand-typed vocabulary
        // keeps its more important (later) position.
        var lastIndex: [String: Int] = [:]
        for (index, term) in ordered.enumerated() {
            lastIndex[term.lowercased()] = index
        }
        return ordered.enumerated()
            .filter { lastIndex[$0.element.lowercased()] == $0.offset }
            .map { $0.element.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whole-word containment, so "Mari" does not match "maritime" and "Star" does not match
    /// "started". Substring matching is what produced "My Phone" and "Home" as known people in
    /// the first draft of this ranker.
    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [], range: searchRange) {
            let beforeOk =
                found.lowerBound == haystack.startIndex
                || !isWordScalar(haystack[haystack.index(before: found.lowerBound)])
            let afterOk =
                found.upperBound == haystack.endIndex || !isWordScalar(haystack[found.upperBound])
            if beforeOk && afterOk { return true }
            guard found.lowerBound < haystack.endIndex else { return false }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func isWordScalar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Packing

    /// Takes terms from the END of an ascending-importance list until the token budget is
    /// spent, and returns them still in ascending order. Whole terms only — a half-written
    /// name is worse than no name, because a speech model will happily bias toward it.
    public static func fitTerms(_ ascending: [String], tokenBudget: Int) -> [String] {
        var kept: [String] = []
        var spent = 0
        for term in ascending.reversed() {
            let cost = PersonalContextBudget.estimatedTokens(forTerm: term)
            if spent + cost > tokenBudget { break }
            spent += cost
            kept.append(term)
        }
        return kept.reversed()
    }

    /// An extract of the user's own prose that ends where a thought ends.
    ///
    /// Paragraph boundaries first (the bio people actually write has headings and sections),
    /// then sentence boundaries, then — only if a single sentence is longer than the whole
    /// budget — a word boundary. Never mid-word. The ellipsis is not decoration: it tells the
    /// model it is reading an extract, so it does not treat the last surviving clause as the
    /// end of what the user had to say.
    public static func profileExtract(_ raw: String, maxChars: Int) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }

        let paragraphs = text.components(separatedBy: "\n\n")
        var kept: [String] = []
        var used = 0
        var stoppedAt = paragraphs.count
        for (index, paragraph) in paragraphs.enumerated() {
            let cost = paragraph.count + (kept.isEmpty ? 0 : 2)
            if used + cost > maxChars - 1 {
                stoppedAt = index
                break
            }
            kept.append(paragraph)
            used += cost
        }
        // A bio with one short heading and one long section would otherwise stop at the
        // heading and hand back 144 characters of a 900-character budget, because whole
        // paragraphs are all-or-nothing. Spend the remainder on as many whole sentences of
        // the next section as fit — still never mid-sentence, just not wasteful.
        if stoppedAt < paragraphs.count, used + 40 < maxChars - 1 {
            let remaining = maxChars - 1 - used - (kept.isEmpty ? 0 : 2)
            let partial = sentenceSafePrefix(paragraphs[stoppedAt], maxChars: remaining)
            if partial.count >= 40 { kept.append(partial) }
        }
        // A bio written with headings ends the extract on a dangling one — "Career and
        // Technical Work…" with nothing under it — which reads like the model was told
        // something and then had it taken away. Drop a trailing heading-shaped paragraph.
        while let last = kept.last, kept.count > 1, isHeadingShaped(last) {
            kept.removeLast()
        }
        if !kept.isEmpty {
            return kept.joined(separator: "\n\n") + "…"
        }
        return sentenceSafePrefix(text, maxChars: maxChars - 1) + "…"
    }

    /// A short line with no sentence-ending punctuation: a section heading, not a statement.
    static func isHeadingShaped(_ paragraph: String) -> Bool {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60, !text.contains("\n") else { return false }
        return text.last.map { !".!?。！？:：".contains($0) } ?? false
    }

    /// The longest prefix of `text` that ends on a sentence terminator, falling back to a word
    /// boundary and finally to a hard cut for text that contains neither.
    static func sentenceSafePrefix(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        let window = String(text.prefix(maxChars))
        let terminators = CharacterSet(charactersIn: ".!?。！？\n")
        if let lastTerminator = window.unicodeScalars.lastIndex(where: { terminators.contains($0) })
        {
            let endOffset = window.unicodeScalars.distance(
                from: window.unicodeScalars.startIndex, to: lastTerminator)
            let cut = String(String.UnicodeScalarView(window.unicodeScalars.prefix(endOffset + 1)))
            let trimmed = cut.trimmingCharacters(in: .whitespacesAndNewlines)
            // A terminator in the first few characters is an initial or an abbreviation, not a
            // sentence — falling back to words beats returning "Dr.".
            if trimmed.count >= maxChars / 2 { return trimmed }
        }
        if let lastSpace = window.lastIndex(where: { $0.isWhitespace }) {
            let trimmed = String(window[window.startIndex..<lastSpace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return window.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
