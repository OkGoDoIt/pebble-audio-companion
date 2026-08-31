import Foundation

// Port of `core/ai/.../AiPlainText.kt`.
//
// StatusUI carries its own public `AiPlainText` (Timeline.swift) for row rendering; this copy
// is deliberately `internal` so the two modules never export colliding public symbols. The KMP
// file has exactly the two functions both copies carry — keep them in sync.

/// Utilities for displaying model output in compact app surfaces.
enum AiPlainText {
    static func clean(_ text: String?, maxChars: Int? = nil) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .components(separatedBy: .newlines)
            .compactMap { cleanLine($0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        guard let maxChars else { return cleaned }
        var bounded = String(cleaned.prefix(maxChars))
        while let last = bounded.last, last.isWhitespace { bounded.removeLast() }
        return bounded
    }

    static func cleanLine(_ line: String) -> String? {
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
