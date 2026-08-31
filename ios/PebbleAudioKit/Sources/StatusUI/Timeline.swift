import Foundation
import SegmentStore

// Row-title derivations from `app/.../ui/TodayScreen.kt` (the Compose UI around them is NOT
// ported — SwiftUI rebuilds those screens from the mockups).
//
// NOT here any more: the KMP Today TIMELINE builder (`buildTimeline`, `TimelineSegmentItem`,
// `todayGapSummary`, `todayOpenActionItems`, `dailyDigestPreviewText`). It modelled Today as a
// rolling 24-hour window of SEGMENTS; the shipped app builds Today from `ConversationQueries`
// + `CoverageComputer` as CONVERSATIONS, so the builder contradicted the screen it looked like
// it fed. It was deleted rather than left as a plausible-looking second Today engine.
//
// Structural adjustment vs KMP (mirrored in StatusUITests): `SegmentAnnotation` is a
// lightweight local value type carrying exactly the fields this layer reads; the Intelligence
// module owns the full store-backed model (module namespacing keeps both importable side by
// side).

/// AI-produced title/summary/tags for one segment (display slice).
public struct SegmentAnnotation: Equatable, Sendable {
    public let segmentId: String
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var createdAtMs: Int64

    public init(
        segmentId: String,
        title: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        createdAtMs: Int64
    ) {
        self.segmentId = segmentId
        self.title = title
        self.summary = summary
        self.tags = tags
        self.createdAtMs = createdAtMs
    }
}

/// Title preference (ux plan Sections 8/9): AI-generated title, else transcript snippet (the
/// live preview while still recording), else a neutral label. Never raw file names/ids.
public func segmentTitle(
    _ meta: SegmentMeta,
    transcriptText: String?,
    annotation: SegmentAnnotation? = nil,
    liveText: String? = nil
) -> String {
    if let cleaned = AiPlainText.clean(annotation?.title) { return cleaned }
    if let snippet = transcriptSnippet(transcriptText) { return snippet }
    // While recording, the freshest words are the interesting ones: show the tail.
    if let snippet = transcriptSnippet(liveText, tail: meta.isOpen) { return snippet }
    return meta.isOpen ? "Recording now" : "Conversation"
}

/// A ~64-char single-line transcript snippet (head or tail), or nil when blank. `tail: true` is
/// the rolling live preview: the newest words of a recording still in progress.
public func transcriptSnippet(_ text: String?, tail: Bool = false) -> String? {
    guard let text else { return nil }
    let snippet = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    if snippet.isBlank { return nil }
    if snippet.count <= 64 { return snippet }
    if tail {
        let tailText = String(snippet.suffix(64))
        return "…" + tailText.drop(while: { $0.isWhitespace })
    }
    let head = String(snippet.prefix(64))
    return head.trimmedTrailingWhitespace + "…"
}

// MARK: - AiPlainText (port of core/ai/.../AiPlainText.kt)

/// Utilities for displaying model output in compact app surfaces.
public enum AiPlainText {
    public static func clean(_ text: String?, maxChars: Int? = nil) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .components(separatedBy: .newlines)
            .compactMap { cleanLine($0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        guard let maxChars else { return cleaned }
        return String(cleaned.prefix(maxChars)).trimmedTrailingWhitespace
    }

    public static func cleanLine(_ line: String) -> String? {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        value = value
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(
                of: "(^|\\s)[*_]([^*_]+)[*_](\\s|$)", with: "$1$2$3", options: .regularExpression
            )
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(
                of: "^(?i:TITLE|SUMMARY|TAGS)\\s*:\\s*", with: "", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var trimmedTrailingWhitespace: String {
        var value = self
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }
}
