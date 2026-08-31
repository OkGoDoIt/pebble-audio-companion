import Foundation
#if canImport(CoreSpotlight)
    import CoreSpotlight
    import UniformTypeIdentifiers
#endif

// Port of `app/.../TranscriptIndexDonator.kt`, retargeted to the rebuild's entity model
// (conversations/notes/recaps/follow-ups instead of segments/digests/action items) and with the
// KMP `spotlightDonate/Remove/RemoveAll` closures replaced by the `SpotlightIndexing` protocol
// so tests fake the CSSearchableIndex.
//
// Per plan 4.7 the Spotlight donation is ported, NOT regressed: transcript text goes into the
// donation's text content, and the app index (FTS5) always receives the full text — the KMP
// `includeFullTranscript = { false }` D7 knob is gone.

/// One document handed to the OS search index (Core Spotlight).
public struct SpotlightDonation: Equatable, Sendable {
    /// Stable unique identifier ("<kind>:<entityId>") — also what deletion keys off.
    public var uniqueIdentifier: String
    public var entityId: String
    public var kind: IndexKind
    public var title: String
    public var contentDescription: String?
    /// Full text content (transcript/body) for on-device Spotlight matching.
    public var textContent: String?
    public var keywords: [String]
    /// Deep link the app opens when the result is tapped (plan 6.8 routes).
    public var deepLinkURL: String
    public var contentCreationDateMs: Int64
    public var startDateMs: Int64?

    public init(
        entityId: String,
        kind: IndexKind,
        title: String,
        contentDescription: String? = nil,
        textContent: String? = nil,
        keywords: [String] = [],
        deepLinkURL: String,
        contentCreationDateMs: Int64,
        startDateMs: Int64? = nil
    ) {
        self.uniqueIdentifier = Self.uniqueIdentifier(kind: kind, entityId: entityId)
        self.entityId = entityId
        self.kind = kind
        self.title = title
        self.contentDescription = contentDescription
        self.textContent = textContent
        self.keywords = keywords
        self.deepLinkURL = deepLinkURL
        self.contentCreationDateMs = contentCreationDateMs
        self.startDateMs = startDateMs
    }

    public static func uniqueIdentifier(kind: IndexKind, entityId: String) -> String {
        "\(kind.rawValue):\(entityId)"
    }

    /// Reverse of `uniqueIdentifier(kind:entityId:)` — the app's Spotlight continuation handler
    /// uses this to resolve a tapped result back to (kind, entityId) and then to its route.
    public static func parse(uniqueIdentifier: String) -> (kind: IndexKind, entityId: String)? {
        guard let separator = uniqueIdentifier.firstIndex(of: ":") else { return nil }
        guard let kind = IndexKind(rawValue: String(uniqueIdentifier[..<separator])) else {
            return nil
        }
        let entityId = String(uniqueIdentifier[uniqueIdentifier.index(after: separator)...])
        return entityId.isEmpty ? nil : (kind, entityId)
    }
}

/// The OS search backend seam (Core Spotlight in production, a fake in tests).
public protocol SpotlightIndexing: Sendable {
    func donate(_ donations: [SpotlightDonation]) async throws
    func remove(uniqueIdentifiers: [String]) async throws
    func removeAll() async throws
}

/// Maps enriched app content into index documents and donates them to both search backends:
/// the persistent FTS index (in-app Search) and Core Spotlight (system search). Called after
/// enrichment/recap/notes writes — never from BLE callbacks.
public final class SpotlightDonator: Sendable {
    private let index: any TranscriptIndexing
    private let spotlight: any SpotlightIndexing

    public init(index: any TranscriptIndexing, spotlight: any SpotlightIndexing) {
        self.index = index
        self.spotlight = spotlight
    }

    // MARK: - Deep links (plan 6.8 routes)

    public static func deepLink(
        kind: IndexKind,
        entityId: String,
        sourceConversationId: String? = nil
    ) -> String {
        switch kind {
        case .conversation: return "companion://conversation/\(entityId)"
        case .note: return "companion://note/\(entityId)"
        case .recap:
            // Recap ids follow the KMP `day-<dateKey>` convention.
            let dateKey = entityId.hasPrefix("day-") ? String(entityId.dropFirst(4)) : entityId
            return "companion://today?date=\(dateKey)"
        case .followUp:
            // Follow-ups have no route of their own; they open their source conversation.
            if let source = sourceConversationId {
                return "companion://conversation/\(source)"
            }
            return "companion://today"
        }
    }

    // MARK: - Donations

    public func donateConversation(
        conversationId: String,
        title: String?,
        summary: String? = nil,
        tags: [String] = [],
        fullTranscript: String? = nil,
        startDateMs: Int64? = nil,
        createdAtMs: Int64,
        excluded: Bool = false
    ) async throws {
        guard index.isAvailable else { return }
        let item = IndexItem(
            id: conversationId,
            kind: .conversation,
            // Never a raw id as a user-visible title; the neutral label matches segmentTitle().
            title: title?.nilIfBlank ?? "Conversation",
            summary: summary,
            tags: tags,
            fullText: fullTranscript,
            startDateMs: startDateMs,
            contentCreationDateMs: createdAtMs,
            excluded: excluded
        )
        try await donate(item, sourceConversationId: nil)
    }

    /// Recaps regenerate during the day under the same dateKey; both writes land on the same
    /// `day-<dateKey>` document so the index holds one entry per day, not a copy per refresh.
    public func donateRecap(
        dateKey: String,
        text: String,
        createdAtMs: Int64,
        excluded: Bool = false
    ) async throws {
        guard index.isAvailable else { return }
        let item = IndexItem(
            id: "day-\(dateKey)",
            kind: .recap,
            title: dateKey,
            summary: String(text.prefix(500)),
            fullText: text,
            contentCreationDateMs: createdAtMs,
            excluded: excluded
        )
        try await donate(item, sourceConversationId: nil)
    }

    public func donateFollowUp(
        id: String,
        text: String,
        sourceConversationId: String? = nil,
        createdAtMs: Int64,
        excluded: Bool = false
    ) async throws {
        guard index.isAvailable else { return }
        let item = IndexItem(
            id: id,
            kind: .followUp,
            title: text,
            contentCreationDateMs: createdAtMs,
            excluded: excluded
        )
        try await donate(item, sourceConversationId: sourceConversationId)
    }

    public func donateNote(
        id: String,
        title: String,
        body: String? = nil,
        createdAtMs: Int64,
        excluded: Bool = false
    ) async throws {
        guard index.isAvailable else { return }
        let item = IndexItem(
            id: id,
            kind: .note,
            title: title,
            fullText: body,
            contentCreationDateMs: createdAtMs,
            excluded: excluded
        )
        try await donate(item, sourceConversationId: nil)
    }

    public func remove(id: String, kind: IndexKind) async throws {
        guard index.isAvailable else { return }
        try index.remove(id: id, kind: kind)
        try await spotlight.remove(
            uniqueIdentifiers: [SpotlightDonation.uniqueIdentifier(kind: kind, entityId: id)]
        )
    }

    public func removeAll() async throws {
        guard index.isAvailable else { return }
        try index.removeAll()
        try await spotlight.removeAll()
    }

    private func donate(_ item: IndexItem, sourceConversationId: String?) async throws {
        try index.upsert([item])
        if item.excluded {
            try await spotlight.remove(
                uniqueIdentifiers: [
                    SpotlightDonation.uniqueIdentifier(kind: item.kind, entityId: item.id)
                ]
            )
        } else {
            try await spotlight.donate([
                SpotlightDonation(
                    entityId: item.id,
                    kind: item.kind,
                    title: item.title,
                    contentDescription: item.summary,
                    textContent: item.fullText,
                    keywords: item.tags,
                    deepLinkURL: Self.deepLink(
                        kind: item.kind,
                        entityId: item.id,
                        sourceConversationId: sourceConversationId
                    ),
                    contentCreationDateMs: item.contentCreationDateMs,
                    startDateMs: item.startDateMs
                )
            ])
        }
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(CoreSpotlight)
    /// Production Core Spotlight backend. Donations are searchable on-device only (system
    /// index); tapping a result hands the app the `uniqueIdentifier`, which the deep-link
    /// router resolves via `SpotlightDonation.parse(uniqueIdentifier:)`.
    public final class CoreSpotlightIndexer: SpotlightIndexing {
        public static let domainIdentifier = "dev.audiocompanion.app.search"

        private let index: CSSearchableIndex

        public init(index: CSSearchableIndex = .default()) {
            self.index = index
        }

        public var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

        public func donate(_ donations: [SpotlightDonation]) async throws {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            let items = donations.map { donation -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = donation.title
                attributes.contentDescription = donation.contentDescription
                attributes.textContent = donation.textContent
                attributes.keywords = donation.keywords.isEmpty ? nil : donation.keywords
                attributes.contentCreationDate = Date(
                    timeIntervalSince1970: Double(donation.contentCreationDateMs) / 1000.0
                )
                if let startMs = donation.startDateMs {
                    attributes.startDate = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
                }
                attributes.contentURL = URL(string: donation.deepLinkURL)
                let item = CSSearchableItem(
                    uniqueIdentifier: donation.uniqueIdentifier,
                    domainIdentifier: Self.domainIdentifier,
                    attributeSet: attributes
                )
                return item
            }
            try await index.indexSearchableItems(items)
        }

        public func remove(uniqueIdentifiers: [String]) async throws {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            try await index.deleteSearchableItems(withIdentifiers: uniqueIdentifiers)
        }

        public func removeAll() async throws {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            try await index.deleteSearchableItems(
                withDomainIdentifiers: [Self.domainIdentifier]
            )
        }
    }
#endif
