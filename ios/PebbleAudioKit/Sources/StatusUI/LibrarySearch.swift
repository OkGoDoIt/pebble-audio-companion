import Foundation

// Port of the pure tag/query helpers from `app/.../ui/LibraryScreen.kt`.
//
// Scope note (plan 4.7): the KMP hand-rolled fuzzy search ENGINE (scoring, snippets, ranking)
// is deliberately not ported — Swift search is SearchKit's persistent index. What is ported
// here is the boolean matching CONTRACT that the KMP tests pin: phrase match, all-terms match
// within one source, typo tolerance (bounded edit distance), and the multi-term
// across-sources fallback.

/// A library tag with how many segments carry it, frequency-sorted.
public struct LibraryTagCount: Equatable, Sendable {
    public let tag: String
    public let count: Int

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

public func libraryTagCounts(_ annotations: [SegmentAnnotation]) -> [LibraryTagCount] {
    // Keyed by lowercase; first-seen casing is the display form (matches KMP).
    var order = [String]()
    var counts = [String: (display: String, count: Int)]()
    for tag in annotations.flatMap({ $0.tags }) {
        guard let cleaned = AiPlainText.clean(tag, maxChars: 32) else { continue }
        let key = cleaned.lowercased()
        if let existing = counts[key] {
            counts[key] = (existing.display, existing.count + 1)
        } else {
            order.append(key)
            counts[key] = (cleaned, 1)
        }
    }
    return order
        .compactMap { counts[$0] }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.display.lowercased() < rhs.display.lowercased()
        }
        .map { LibraryTagCount(tag: $0.display, count: $0.count) }
}

public func libraryTags(_ annotations: [SegmentAnnotation]) -> [String] {
    libraryTagCounts(annotations).map { $0.tag }
}

public func annotationHasTag(_ annotation: SegmentAnnotation?, tag: String?) -> Bool {
    guard let annotation, let tag, !tag.isBlank else { return false }
    return annotation.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
}

public func actionItemsForSegment(_ actionItems: [ActionItem], segmentId: String) -> [ActionItem] {
    actionItems.filter { $0.sourceSegmentId == segmentId }
}

public func aiOutputsForSegment(_ aiOutputs: [AiOutput], segmentId: String) -> [AiOutput] {
    aiOutputs.filter { $0.segmentIds.contains(segmentId) }
}

/// Whether a segment's text surfaces (transcript, annotation, follow-ups, AI outputs) match
/// the library search query. A blank query matches everything.
public func segmentMatchesLibraryQuery(
    _ query: String,
    transcriptText: String?,
    annotation: SegmentAnnotation?,
    actionItems: [ActionItem],
    aiOutputs: [AiOutput]
) -> Bool {
    guard let parts = libraryQueryParts(query) else { return true }
    var searchableText: [String?] = [
        transcriptText,
        annotation?.title,
        annotation?.summary,
    ]
    searchableText.append(contentsOf: (annotation?.tags ?? []).map { $0 })
    searchableText.append(contentsOf: actionItems.map { $0.text })
    for output in aiOutputs {
        searchableText.append(output.promptTitle)
        searchableText.append(output.text)
    }
    if searchableText.contains(where: { textMatchesQuery(parts, $0) }) { return true }
    return parts.terms.count > 1
        && parts.terms.allSatisfy { term in
            searchableText.contains(where: { textMatchesTerm(term, $0) })
        }
}

// MARK: - Matching internals

private struct LibraryQueryParts {
    let phrase: String
    let terms: [String]
}

private struct SearchToken {
    let text: String
}

private let maxFuzzyTokensPerField = 2_500
private let maxFuzzyTokenChars = 36

private func libraryQueryParts(_ query: String) -> LibraryQueryParts? {
    let phrase = normalizeSearchText(query)
    if phrase.isBlank { return nil }
    var seen = Set<String>()
    var terms = [String]()
    for token in searchTokens(phrase) {
        let term = token.text.lowercased()
        guard term.count >= 2, !seen.contains(term) else { continue }
        seen.insert(term)
        terms.append(term)
    }
    return LibraryQueryParts(phrase: phrase, terms: terms)
}

/// The whole query matches one text: the phrase appears verbatim, or every term matches
/// (exactly or within the typo threshold).
private func textMatchesQuery(_ parts: LibraryQueryParts, _ text: String?) -> Bool {
    let normalized = normalizeSearchText(text)
    if normalized.isBlank { return false }
    if normalized.range(of: parts.phrase, options: .caseInsensitive) != nil { return true }
    if parts.terms.isEmpty { return false }
    let tokens = searchTokens(normalized)
    return parts.terms.allSatisfy { term in
        exactTermMatch(normalized, term) || fuzzyTermMatch(tokens, term)
    }
}

private func textMatchesTerm(_ term: String, _ text: String?) -> Bool {
    let normalized = normalizeSearchText(text)
    if normalized.isBlank { return false }
    return exactTermMatch(normalized, term) || fuzzyTermMatch(searchTokens(normalized), term)
}

private func exactTermMatch(_ text: String, _ term: String) -> Bool {
    text.range(of: term, options: .caseInsensitive) != nil
}

private func fuzzyTermMatch(_ tokens: [SearchToken], _ term: String) -> Bool {
    if term.count < 3 { return false }
    let threshold = fuzzyDistanceThreshold(term)
    return tokens
        .prefix(maxFuzzyTokensPerField)
        .contains { token in
            token.text.count <= maxFuzzyTokenChars
                && abs(token.text.count - term.count) <= threshold
                && levenshteinDistanceAtMost(term, token.text.lowercased(), maxDistance: threshold)
                    <= threshold
        }
}

private func fuzzyDistanceThreshold(_ term: String) -> Int {
    switch term.count {
    case ...4: return 1
    case ...8: return 2
    default: return 3
    }
}

private func levenshteinDistanceAtMost(_ a: String, _ b: String, maxDistance: Int) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    if abs(aChars.count - bChars.count) > maxDistance { return maxDistance + 1 }
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }
    var previous = Array(0...bChars.count)
    var current = Array(repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
        current[0] = i
        var rowMin = current[0]
        for j in 1...bChars.count {
            let substitutionCost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
            current[j] = Swift.min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + substitutionCost
            )
            rowMin = Swift.min(rowMin, current[j])
        }
        if rowMin > maxDistance { return maxDistance + 1 }
        swap(&previous, &current)
    }
    return previous[bChars.count]
}

private func normalizeSearchText(_ text: String?) -> String {
    guard let text else { return "" }
    return text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

private func searchTokens(_ text: String) -> [SearchToken] {
    var tokens = [SearchToken]()
    var currentToken = ""
    for char in text {
        if char.isLetter || char.isNumber {
            currentToken.append(char)
        } else if !currentToken.isEmpty {
            tokens.append(SearchToken(text: currentToken))
            currentToken = ""
        }
    }
    if !currentToken.isEmpty { tokens.append(SearchToken(text: currentToken)) }
    return tokens
}
