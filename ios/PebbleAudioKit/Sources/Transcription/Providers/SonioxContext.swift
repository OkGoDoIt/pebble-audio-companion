import Foundation

// Port of `core/transcription/.../SonioxContext.kt`.

/// Soniox transcription `context` object (real-time config + async REST body).
public struct SonioxContext: Codable, Sendable, Equatable {
    public var text: String?
    public var terms: [String]?

    public init(text: String? = nil, terms: [String]? = nil) {
        self.text = text
        self.terms = terms
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(terms, forKey: .terms)
    }
}

/// Builds Soniox `context` JSON for WebSocket config when text or terms are present.
func buildSonioxContextJsonObject(
    contextText: String?,
    contextTerms: [String]
) -> [String: Any]? {
    guard let context = sonioxContextFrom(contextText: { contextText }, contextTerms: { contextTerms })
    else { return nil }
    var object: [String: Any] = [:]
    if let text = context.text { object["text"] = text }
    if let terms = context.terms { object["terms"] = terms }
    return object
}

/// Maps closures into a `SonioxContext` for async REST requests (nil when there is no context).
func sonioxContextFrom(
    contextText: @Sendable () -> String?,
    contextTerms: @Sendable () -> [String]
) -> SonioxContext? {
    let text = contextText()?.trimmingCharacters(in: .whitespacesAndNewlines).ifEmptyNil
    var seen = Set<String>()
    let terms = contextTerms().filter { term in
        let isBlank = term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isBlank && seen.insert(term).inserted
    }
    if text == nil && terms.isEmpty { return nil }
    return SonioxContext(text: text, terms: terms.isEmpty ? nil : terms)
}

extension String {
    fileprivate var ifEmptyNil: String? { isEmpty ? nil : self }
}
