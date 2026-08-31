import Foundation

// Port of `core/ai/.../PersonalContext.kt`.
//
// JSON compatibility note: the KMP app wrote `ai/personal_context.json` with
// kotlinx.serialization and `encodeDefaults = false`, so any field whose value equals its
// Kotlin default (nil optionals, empty lists, `true` gates) is OMITTED from the JSON. The
// custom Codable implementations below reproduce that exactly — this file is user-authored
// data the migration importer reads, and the old app's parser must remain able to read ours.

/// Provenance for a fact imported into personal context (M5). Raw values match the Kotlin
/// enum constant names as serialized.
public enum ContextSourceKind: String, Codable, CaseIterable, Sendable {
    case manual = "Manual"
    case contacts = "Contacts"
    case calendar = "Calendar"
    case derived = "Derived"
}

/// One imported or derived fact with provenance (M5).
public struct ContextSource: Equatable, Codable, Sendable {
    public var id: String
    public var kind: ContextSourceKind
    public var label: String
    public var importedAtMs: Int64

    public init(id: String, kind: ContextSourceKind, label: String, importedAtMs: Int64) {
        self.id = id
        self.kind = kind
        self.label = label
        self.importedAtMs = importedAtMs
    }
}

/// A person the user knows (M5 speaker naming / people memory).
public struct KnownPerson: Equatable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var relationship: String?
    public var role: String?
    public var organization: String?

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        relationship: String? = nil,
        role: String? = nil,
        organization: String? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.relationship = relationship
        self.role = role
        self.organization = organization
    }
}

extension KnownPerson: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, aliases, relationship, role, organization
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
        try c.encodeIfPresent(relationship, forKey: .relationship)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(organization, forKey: .organization)
    }
}

/// Custom vocabulary term for transcription biasing.
public struct VocabTerm: Equatable, Sendable {
    public var text: String
    public var pronunciationHint: String?

    public init(text: String, pronunciationHint: String? = nil) {
        self.text = text
        self.pronunciationHint = pronunciationHint
    }
}

extension VocabTerm: Codable {
    private enum CodingKeys: String, CodingKey { case text, pronunciationHint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        pronunciationHint = try c.decodeIfPresent(String.self, forKey: .pronunciationHint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(pronunciationHint, forKey: .pronunciationHint)
    }
}

/// User-owned background facts that improve transcription accuracy and AI quality.
/// M1 ships paste-only `profileText`; M5 populates people/orgs and import `sources`.
public struct PersonalContext: Equatable, Sendable {
    /// Free-form "About you" text pasted by the user.
    public var profileText: String?
    /// Cached keyword list extracted from `profileText` for OpenAI STT steering.
    public var derivedTerms: [String]
    /// Hash of `profileText` when `derivedTerms` was last computed; avoids re-extraction.
    public var derivedTermsSourceHash: String?
    public var people: [KnownPerson]
    public var orgs: [String]
    public var places: [String]
    public var topics: [String]
    public var terms: [VocabTerm]
    public var sources: [ContextSource]
    public var biasTranscription: Bool
    public var groundAi: Bool

    public init(
        profileText: String? = nil,
        derivedTerms: [String] = [],
        derivedTermsSourceHash: String? = nil,
        people: [KnownPerson] = [],
        orgs: [String] = [],
        places: [String] = [],
        topics: [String] = [],
        terms: [VocabTerm] = [],
        sources: [ContextSource] = [],
        biasTranscription: Bool = true,
        groundAi: Bool = true
    ) {
        self.profileText = profileText
        self.derivedTerms = derivedTerms
        self.derivedTermsSourceHash = derivedTermsSourceHash
        self.people = people
        self.orgs = orgs
        self.places = places
        self.topics = topics
        self.terms = terms
        self.sources = sources
        self.biasTranscription = biasTranscription
        self.groundAi = groundAi
    }

    public var hasProfileText: Bool {
        guard let profileText else { return false }
        return !profileText.isBlank
    }

    /// Stable hash for change detection (simple djb2 over trimmed profile text).
    public func profileTextHash() -> String? {
        guard let trimmed = profileText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return PersonalContextHash.of(trimmed)
    }
}

extension PersonalContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case profileText, derivedTerms, derivedTermsSourceHash, people, orgs, places, topics
        case terms, sources, biasTranscription, groundAi
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileText = try c.decodeIfPresent(String.self, forKey: .profileText)
        derivedTerms = try c.decodeIfPresent([String].self, forKey: .derivedTerms) ?? []
        derivedTermsSourceHash = try c.decodeIfPresent(
            String.self, forKey: .derivedTermsSourceHash)
        people = try c.decodeIfPresent([KnownPerson].self, forKey: .people) ?? []
        orgs = try c.decodeIfPresent([String].self, forKey: .orgs) ?? []
        places = try c.decodeIfPresent([String].self, forKey: .places) ?? []
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        terms = try c.decodeIfPresent([VocabTerm].self, forKey: .terms) ?? []
        sources = try c.decodeIfPresent([ContextSource].self, forKey: .sources) ?? []
        biasTranscription = try c.decodeIfPresent(Bool.self, forKey: .biasTranscription) ?? true
        groundAi = try c.decodeIfPresent(Bool.self, forKey: .groundAi) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(profileText, forKey: .profileText)
        if !derivedTerms.isEmpty { try c.encode(derivedTerms, forKey: .derivedTerms) }
        try c.encodeIfPresent(derivedTermsSourceHash, forKey: .derivedTermsSourceHash)
        if !people.isEmpty { try c.encode(people, forKey: .people) }
        if !orgs.isEmpty { try c.encode(orgs, forKey: .orgs) }
        if !places.isEmpty { try c.encode(places, forKey: .places) }
        if !topics.isEmpty { try c.encode(topics, forKey: .topics) }
        if !terms.isEmpty { try c.encode(terms, forKey: .terms) }
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
        if !biasTranscription { try c.encode(biasTranscription, forKey: .biasTranscription) }
        if !groundAi { try c.encode(groundAi, forKey: .groundAi) }
    }
}

/// Lightweight string hash for cache keys (no crypto dependency). Kotlin iterated UTF-16
/// chars; matching that keeps hashes identical to files the old app wrote.
enum PersonalContextHash {
    static func of(_ text: String) -> String {
        var hash: UInt64 = 5381
        for unit in text.utf16 {
            hash = ((hash << 5) &+ hash) &+ UInt64(unit)
        }
        return String(hash, radix: 16)
    }
}
