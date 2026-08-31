import Foundation
import AppDB

// Port of `app/.../ui/AnswerCitations.kt` — pure parsing/resolution for the citations an AI
// answer makes to the transcript moments it drew from. Kept UI-framework-free so the messy
// normalisation is unit-testable directly (the 8 pinned behaviors in AnswerCitationsTest).
//
// References reach us in several shapes and all fold into one resolved, numbered form so the
// UI renders a single consistent affordance instead of opaque ids:
//  - `[n]` footnote numbers keyed to the prompt's numbered source list (the preferred form Ask
//    asks the model to emit);
//  - `[seg-…](#)` markdown links the model used to invent, where the id is usually truncated;
//  - bare `seg-…` ids dropped into the prose.
//
// Truncated ids resolve against the real source list by prefix, so historical outputs still
// link.

public enum AnswerToken: Equatable, Sendable {
    /// Literal prose (may still contain `**bold**` / `*italic*`, handled at render time).
    case span(String)

    /// A resolved citation: `number` is the 1-based display index, `segmentId` the real source.
    case citation(number: Int, segmentId: String)
}

/// One rendered line of the answer: an optional list/quote `marker` plus inline `tokens`.
public struct AnswerLine: Equatable, Sendable {
    public let marker: String?
    public let tokens: [AnswerToken]

    public init(marker: String?, tokens: [AnswerToken]) {
        self.marker = marker
        self.tokens = tokens
    }
}

public struct GroundedAnswer: Equatable, Sendable {
    public let lines: [AnswerLine]
    /// Distinct cited segment ids in first-appearance order; `index + 1` is the display number.
    public let citedSegmentIds: [String]

    public init(lines: [AnswerLine], citedSegmentIds: [String]) {
        self.lines = lines
        self.citedSegmentIds = citedSegmentIds
    }
}

/// Parse `text` into renderable lines with citations resolved against `sourceIds` (the answer's
/// real source segment ids, in the order the model was shown them). Numbering is assigned by
/// first appearance so inline chips and the "Based on" list share one stable set of numbers.
public func parseGroundedAnswer(_ text: String, sourceIds: [String]) -> GroundedAnswer {
    let patterns = CitationPatterns()
    var numberOrder: [String] = []
    var numberBySegment: [String: Int] = [:]
    func numberFor(_ segmentId: String) -> Int {
        if let existing = numberBySegment[segmentId] { return existing }
        numberOrder.append(segmentId)
        let number = numberOrder.count
        numberBySegment[segmentId] = number
        return number
    }

    let lines = splitAnswerBlocks(text).compactMap { block -> AnswerLine? in
        let tokens = cleanupConnectors(
            tokenizeLine(block.text, sourceIds: sourceIds, patterns: patterns, numberFor: numberFor)
        )
        let meaningful = tokens.contains { token in
            switch token {
            case .citation: return true
            case .span(let s): return !s.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        if block.marker == nil && !meaningful { return nil }
        return AnswerLine(marker: block.marker, tokens: tokens)
    }
    return GroundedAnswer(lines: lines, citedSegmentIds: numberOrder)
}

/// Citations for an answer the UI renders VERBATIM (Saved Notes, the Ask answer card): the
/// model's own `[n]` numbers are kept and mapped straight back to the excerpt they label, so a
/// chip reading "2" always navigates to the segment the prompt called `[2]`.
///
/// `parseGroundedAnswer` renumbers by first appearance instead, which is correct only when the
/// answer is re-rendered from its `lines`. Storing those numbers against text that still says
/// `[2]` is what sent a chip to the wrong moment whenever a model's first citation was not
/// `[1]`.
///
/// Numbers with no matching excerpt are dropped rather than guessed: a chip that navigates
/// nowhere is worse than no chip.
public func renderedAnswerCitations(_ text: String, sourceIds: [String]) -> [AskCitation] {
    let footnote = regex(#"\[(\d{1,3})]"#)
    let ns = text as NSString
    var seen = Set<Int>()
    var citations: [AskCitation] = []
    for match in footnote.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let number = Int(ns.substring(with: match.range(at: 1))),
            sourceIds.indices.contains(number - 1),
            seen.insert(number).inserted
        else { continue }
        citations.append(AskCitation(segmentId: sourceIds[number - 1], number: number))
    }
    return citations.sorted { $0.number < $1.number }
}

// MARK: - Internals

private struct CitationPatterns {
    let markdownLink = regex(#"\[([^\]\n]*)]\(([^)\n]*)\)"#)
    let footnote = regex(#"\[(\d{1,3})]"#)
    let segToken = regex(#"seg-[A-Za-z0-9_-]+"#)
    /// Earliest-wins union of every citation shape, scanned left to right across a line.
    let anyCitation = regex(#"\[[^\]\n]*]\([^)\n]*\)|\[\d{1,3}]|seg-[A-Za-z0-9_-]+"#)
}

private func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns are compile-time constants; a failure is a programmer error.
    try! NSRegularExpression(pattern: pattern)
}

private func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

private func matchEntire(
    _ re: NSRegularExpression, _ s: String
) -> NSTextCheckingResult? {
    guard let match = re.firstMatch(in: s, range: fullRange(s)) else { return nil }
    return match.range == fullRange(s) ? match : nil
}

private func group(_ match: NSTextCheckingResult, _ index: Int, in s: String) -> String {
    guard let range = Range(match.range(at: index), in: s) else { return "" }
    return String(s[range])
}

/// Separator-only spans between two adjacent citations that we collapse away.
private let connectorSpans: Set<String> = [",", ";", "·", "/", "&", "and", "+"]

private struct RawBlock {
    let marker: String?
    let text: String
}

private let numberedLine = regex(#"^\d+[.)]\s+.*"#)
private let numberedMarkerPrefix = regex(#"^\d+[.)]\s+"#)

/// Split markdown-ish answer text into list/quote blocks. Mirrors the bullet/number/checkbox
/// handling the answer view needs; continuation lines (indented) fold into the prior block.
private func splitAnswerBlocks(_ text: String) -> [RawBlock] {
    var blocks: [RawBlock] = []
    for rawUntrimmed in text.components(separatedBy: "\n") {
        let rawLine = String(
            rawUntrimmed.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("- [ ] ") {
            blocks.append(RawBlock(
                marker: "☐",
                text: String(line.dropFirst("- [ ] ".count)).trimmingCharacters(in: .whitespaces)))
        } else if line.lowercased().hasPrefix("- [x] ") {
            let after = line.range(of: "] ").map { String(line[$0.upperBound...]) } ?? ""
            blocks.append(RawBlock(marker: "☑", text: after.trimmingCharacters(in: .whitespaces)))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            blocks.append(RawBlock(
                marker: "•", text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        } else if matchEntire(numberedLine, line) != nil {
            let head = line.split(separator: " ", maxSplits: 1)[0]
            let marker = (head.hasSuffix(".") || head.hasSuffix(")")) ? String(head) : head + "."
            let body = numberedMarkerPrefix.stringByReplacingMatches(
                in: line, range: fullRange(line), withTemplate: "")
            blocks.append(RawBlock(marker: marker, text: body))
        } else if blocks.last?.marker != nil && rawLine.hasPrefix("  ") {
            let previous = blocks.removeLast()
            blocks.append(RawBlock(marker: previous.marker, text: previous.text + " " + line))
        } else {
            blocks.append(RawBlock(marker: nil, text: line))
        }
    }
    return blocks
}

private func tokenizeLine(
    _ line: String,
    sourceIds: [String],
    patterns: CitationPatterns,
    numberFor: (String) -> Int
) -> [AnswerToken] {
    var out: [AnswerToken] = []
    let ns = line as NSString
    var index = 0
    while index < ns.length {
        let searchRange = NSRange(location: index, length: ns.length - index)
        guard let match = patterns.anyCitation.firstMatch(in: line, range: searchRange) else {
            out.append(.span(ns.substring(from: index)))
            break
        }
        if match.range.location > index {
            out.append(.span(ns.substring(
                with: NSRange(location: index, length: match.range.location - index))))
        }
        let raw = ns.substring(with: match.range)
        if let resolved = resolveCitation(raw, sourceIds: sourceIds, patterns: patterns) {
            out.append(.citation(number: numberFor(resolved), segmentId: resolved))
        } else if let fallback = fallbackText(raw, patterns: patterns) {
            out.append(.span(fallback))
        }
        index = match.range.location + match.range.length
    }
    return out
}

/// What to keep when a citation can't be resolved: link/number text stays, opaque ids are
/// dropped.
private func fallbackText(_ raw: String, patterns: CitationPatterns) -> String? {
    if let link = matchEntire(patterns.markdownLink, raw) {
        let label = group(link, 1, in: raw)
        // A real hyperlink keeps its human label; an unresolved seg-link contributes nothing.
        let labelIsNumber = Int(label.trimmingCharacters(in: .whitespaces)) != nil
        let labelHasSeg =
            patterns.segToken.firstMatch(in: label, range: fullRange(label)) != nil
        return (labelHasSeg || labelIsNumber) ? nil : label
    }
    if raw.hasPrefix("seg-") { return nil }
    return raw // e.g. a genuine "[12]" bracketed number, not a footnote
}

private func resolveCitation(
    _ raw: String, sourceIds: [String], patterns: CitationPatterns
) -> String? {
    if let link = matchEntire(patterns.markdownLink, raw) {
        let label = group(link, 1, in: raw)
        let url = group(link, 2, in: raw)
        if let segMatch = patterns.segToken.firstMatch(in: label, range: fullRange(label)),
           let range = Range(segMatch.range, in: label) {
            return resolveSeg(String(label[range]), sourceIds: sourceIds)
        }
        if let segMatch = patterns.segToken.firstMatch(in: url, range: fullRange(url)),
           let range = Range(segMatch.range, in: url) {
            return resolveSeg(String(url[range]), sourceIds: sourceIds)
        }
        if let number = Int(label.trimmingCharacters(in: .whitespaces)) {
            return sourceIds.indices.contains(number - 1) ? sourceIds[number - 1] : nil
        }
        return nil
    }
    if let footnote = matchEntire(patterns.footnote, raw),
       let number = Int(group(footnote, 1, in: raw)) {
        return sourceIds.indices.contains(number - 1) ? sourceIds[number - 1] : nil
    }
    if raw.hasPrefix("seg-") { return resolveSeg(raw, sourceIds: sourceIds) }
    return nil
}

/// Resolve a (possibly truncated) `seg-…` token to a real source id: exact, then either-way
/// prefix.
private func resolveSeg(_ token: String, sourceIds: [String]) -> String? {
    var trimmed = token
    while let last = trimmed.last, ".,);:".contains(last) { trimmed.removeLast() }
    if let exact = sourceIds.first(where: { $0 == trimmed }) { return exact }
    if let prefix = sourceIds.first(where: { $0.hasPrefix(trimmed) }) { return prefix }
    return sourceIds.first(where: { trimmed.hasPrefix($0) })
}

private let trailingOpenParen = regex(#"\(\s*$"#)
private let leadingCloseParen = regex(#"^\s*\)"#)

/// Strip the punctuation that historically wrapped citations — `(`, `)`, and `, ` separators
/// that the model put around `([seg…](#), [seg…](#))` — so chips hug the sentence cleanly:
/// "…committed¹²."
private func cleanupConnectors(_ tokens: [AnswerToken]) -> [AnswerToken] {
    var out: [AnswerToken] = []
    for (i, token) in tokens.enumerated() {
        guard case .span(let rawText) = token else {
            out.append(token)
            continue
        }
        let prevIsCitation: Bool
        if case .citation = out.last { prevIsCitation = true } else { prevIsCitation = false }
        let nextIsCitation: Bool
        if i + 1 < tokens.count, case .citation = tokens[i + 1] {
            nextIsCitation = true
        } else {
            nextIsCitation = false
        }
        var text = rawText
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if prevIsCitation && nextIsCitation && (trimmed.isEmpty || connectorSpans.contains(trimmed)) {
            continue // drop a pure separator sitting between two chips
        }
        if nextIsCitation {
            text = trailingOpenParen.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "")
        }
        if prevIsCitation {
            text = leadingCloseParen.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "")
        }
        if !text.isEmpty { out.append(.span(text)) }
    }
    return out
}
