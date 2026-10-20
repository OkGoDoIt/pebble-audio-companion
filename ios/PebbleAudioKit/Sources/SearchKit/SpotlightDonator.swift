import Foundation
import os
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
    /// The people in it: the names given to its speakers. Conversations only. The index carries
    /// them as participants, so "the call with Sam" finds a conversation whose transcript only
    /// ever says "Speaker 2".
    public var people: [String]
    /// Deep link the app opens when the result is tapped (plan 6.8 routes).
    public var deepLinkURL: String
    public var contentCreationDateMs: Int64
    public var startDateMs: Int64?
    /// When a conversation ended. Without it the entity built from a donation had ended the
    /// moment it began: zero minutes long, modified at its start.
    public var endDateMs: Int64?

    public init(
        entityId: String,
        kind: IndexKind,
        title: String,
        contentDescription: String? = nil,
        textContent: String? = nil,
        keywords: [String] = [],
        people: [String] = [],
        deepLinkURL: String,
        contentCreationDateMs: Int64,
        startDateMs: Int64? = nil,
        endDateMs: Int64? = nil
    ) {
        self.endDateMs = endDateMs
        self.uniqueIdentifier = Self.uniqueIdentifier(kind: kind, entityId: entityId)
        self.entityId = entityId
        self.kind = kind
        self.title = title
        self.contentDescription = contentDescription
        self.textContent = textContent
        self.keywords = keywords
        self.people = people
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

/// What the SYSTEM index may hold of a donation at a given `SystemSearchVisibility`.
///
/// A pure function so the rule is testable without Core Spotlight, and so it is written down
/// once: the app's own FTS index is never gated (in-app search always has the full text —
/// `SpotlightDonator.donate` upserts it before this runs), this is about what leaves the
/// sandbox for Spotlight and, on iOS 27, Siri's semantic index.
public enum SpotlightVisibilityGate {
    public struct Outcome: Equatable, Sendable {
        /// Donations to index, already trimmed to what the setting allows.
        public var index: [SpotlightDonation]
        /// Unique identifiers to DELETE instead — the setting says these documents may not
        /// exist in the system index, so a donation becomes a removal of whatever an earlier,
        /// more permissive pass left there.
        public var remove: [String]

        public init(index: [SpotlightDonation], remove: [String]) {
            self.index = index
            self.remove = remove
        }
    }

    public static func apply(
        _ visibility: SystemSearchVisibility, to donations: [SpotlightDonation]
    ) -> Outcome {
        switch visibility {
        case .off:
            return Outcome(index: [], remove: donations.map(\.uniqueIdentifier))
        case .summaries:
            // Titles, summaries (`contentDescription`), tags and dates survive; the transcript
            // or note body (`textContent`) does not. A recap's `contentDescription` is the
            // first 500 characters of the digest — a summary of the day, which is what this
            // setting promises to keep.
            return Outcome(
                index: donations.map { donation in
                    var trimmed = donation
                    trimmed.textContent = nil
                    return trimmed
                },
                remove: []
            )
        case .full:
            return Outcome(index: donations, remove: [])
        }
    }
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

    /// The system-index backend, so the app can configure it AFTER construction: the
    /// composition builds the indexer before the settings that gate it and the entity model
    /// that annotates it are wired (see `CoreSpotlightIndexer.configure`).
    public var systemIndex: any SpotlightIndexing { spotlight }

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
            // The follow-up's own screen. It used to open the source conversation — or Today,
            // which shows three of them — so a Spotlight hit landed on a transcript, or on a
            // list that might not even contain the item that was searched for.
            return "companion://followup/\(entityId)"
        }
    }

    // MARK: - Donations

    public func donateConversation(
        conversationId: String,
        title: String?,
        summary: String? = nil,
        tags: [String] = [],
        people: [String] = [],
        fullTranscript: String? = nil,
        startDateMs: Int64? = nil,
        endDateMs: Int64? = nil,
        createdAtMs: Int64,
        excluded: Bool = false,
        systemIndex: Bool = true
    ) async throws {
        try await donateConversations([
            ConversationDonation(
                conversationId: conversationId, title: title, summary: summary, tags: tags,
                people: people, fullTranscript: fullTranscript, startDateMs: startDateMs,
                endDateMs: endDateMs, createdAtMs: createdAtMs, excluded: excluded,
                systemIndex: systemIndex)
        ])
    }

    /// One conversation's part of a batched donation.
    public struct ConversationDonation: Equatable, Sendable {
        public var conversationId: String
        public var title: String?
        public var summary: String?
        public var tags: [String]
        public var people: [String]
        public var fullTranscript: String?
        public var startDateMs: Int64?
        public var endDateMs: Int64?
        public var createdAtMs: Int64
        public var excluded: Bool
        /// False keeps the conversation out of the SYSTEM index for now while the app's own
        /// search still gets it. A live conversation is still growing: Spotlight and Siri get it
        /// once it has closed, not a new partial copy at every provisional refresh.
        public var systemIndex: Bool

        public init(
            conversationId: String, title: String?, summary: String? = nil, tags: [String] = [],
            people: [String] = [], fullTranscript: String? = nil, startDateMs: Int64? = nil,
            endDateMs: Int64? = nil, createdAtMs: Int64, excluded: Bool = false,
            systemIndex: Bool = true
        ) {
            self.conversationId = conversationId
            self.title = title
            self.summary = summary
            self.tags = tags
            self.people = people
            self.fullTranscript = fullTranscript
            self.startDateMs = startDateMs
            self.endDateMs = endDateMs
            self.createdAtMs = createdAtMs
            self.excluded = excluded
            self.systemIndex = systemIndex
        }
    }

    /// Many conversations in one write to each backend (one FTS transaction, one system-index
    /// pass) instead of a round trip per conversation.
    public func donateConversations(_ batch: [ConversationDonation]) async throws {
        guard index.isAvailable, !batch.isEmpty else { return }
        let items = batch.map { input in
            IndexItem(
                id: input.conversationId,
                kind: .conversation,
                // Never a raw id as a user-visible title; the neutral label matches segmentTitle().
                title: input.title?.nilIfBlank ?? "Conversation",
                summary: input.summary,
                tags: input.tags,
                fullText: input.fullTranscript,
                startDateMs: input.startDateMs,
                contentCreationDateMs: input.createdAtMs,
                excluded: input.excluded
            )
        }
        let people = Dictionary(
            batch.map { ($0.conversationId, $0.people) }, uniquingKeysWith: { _, last in last })
        let ends = Dictionary(
            batch.map { ($0.conversationId, $0.endDateMs) }, uniquingKeysWith: { _, last in last })
        let heldBack = Set(batch.filter { !$0.systemIndex }.map(\.conversationId))
        try await donate(
            items,
            people: { people[$0.id] ?? [] },
            endDateMs: { ends[$0.id] ?? nil },
            systemIndex: { !heldBack.contains($0.id) })
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
        try await donate(
            [item], people: { _ in [] }, endDateMs: { _ in nil }, systemIndex: { _ in true },
            sourceConversationId: { _ in sourceConversationId })
    }

    /// FTS first, always and in full; then the system index, where an excluded item becomes a
    /// removal and an item held back (`systemIndex` false) is left as the index already has it.
    private func donate(
        _ items: [IndexItem],
        people: (IndexItem) -> [String],
        endDateMs: (IndexItem) -> Int64?,
        systemIndex: (IndexItem) -> Bool,
        sourceConversationId: (IndexItem) -> String? = { _ in nil }
    ) async throws {
        guard !items.isEmpty else { return }
        try index.upsert(items)
        let removals = items.filter(\.excluded).map {
            SpotlightDonation.uniqueIdentifier(kind: $0.kind, entityId: $0.id)
        }
        if !removals.isEmpty {
            try await spotlight.remove(uniqueIdentifiers: removals)
        }
        let donations = items.filter { !$0.excluded && systemIndex($0) }.map { item in
            SpotlightDonation(
                entityId: item.id,
                kind: item.kind,
                title: item.title,
                contentDescription: item.summary,
                textContent: item.fullText,
                keywords: item.tags,
                people: people(item),
                deepLinkURL: Self.deepLink(
                    kind: item.kind,
                    entityId: item.id,
                    sourceConversationId: sourceConversationId(item)
                ),
                contentCreationDateMs: item.contentCreationDateMs,
                startDateMs: item.startDateMs,
                endDateMs: endDateMs(item)
            )
        }
        if !donations.isEmpty {
            try await spotlight.donate(donations)
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
    ///
    /// An actor because `CSSearchableIndex` is not marked `Sendable` (it is a thread-safe
    /// Objective-C class the framework has not annotated), and `SpotlightIndexing` is. Isolating
    /// the handle says the same thing the framework's documentation does, without a
    /// `@preconcurrency` import that would also silence every future Sendable finding from the
    /// module. Every protocol method was already `async`, so no call site changed.
    public actor CoreSpotlightIndexer: SpotlightIndexing {
        public static let domainIdentifier = "dev.audiocompanion.app.search"

        /// Called with every item about to be indexed, so the app can attach its App Intents
        /// entity to it (`CSSearchableItem.associateAppEntity`). Spotlight then shows ONE
        /// result per document and Siri sees the entity behind it. The donation is the
        /// already-gated one — what the hook is handed is exactly what the index receives.
        public typealias AssociationHook = @Sendable (CSSearchableItem, SpotlightDonation) -> Void

        /// Everything the app may set after construction, behind one lock: the composition
        /// builds this indexer before the settings box and the entity model exist, and a
        /// donation can already be in flight from another task when `configure` runs.
        private struct Configuration {
            var visibility: @Sendable () -> SystemSearchVisibility = { .default }
            var associate: AssociationHook?
            var purgeEntities: (@Sendable () async -> Void)?
        }

        private let index: CSSearchableIndex
        private let configuration = OSAllocatedUnfairLock(initialState: Configuration())
        /// What the index already holds (`SpotlightIndexGate`), loaded on first use so building
        /// the indexer at launch reads nothing from disk.
        private let gateStore: any SpotlightIndexGateStore
        private var loadedGate: SpotlightIndexGate?
        private let log: @Sendable (String) -> Void

        /// Items per `indexSearchableItems` call. A rebuild hands over the whole library at once;
        /// Core Spotlight takes it in pieces, and a failure costs one piece rather than all.
        public static let batchSize = 50

        public init(
            index: CSSearchableIndex = .default(),
            gateStore: any SpotlightIndexGateStore = EphemeralSpotlightIndexGateStore(),
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.index = index
            self.gateStore = gateStore
            self.log = log
        }

        private var gate: SpotlightIndexGate {
            get {
                if let loadedGate { return loadedGate }
                let loaded = gateStore.load()
                loadedGate = loaded
                return loaded
            }
            set { loadedGate = newValue }
        }

        /// Installs the visibility rule and the optional entity hooks. Synchronous and
        /// nonisolated on purpose: the app calls it from its main-actor composition, and the
        /// next donation on any task sees the new configuration.
        ///
        /// - `visibility`: read on EVERY pass, so a Settings change takes effect on the next
        ///   donation rather than at the next launch.
        /// - `associate`: the iOS 27 entity association (nil below iOS 27, or in tests).
        /// - `purgeEntities`: run by `removeAll()` after the domain is emptied, for anything the
        ///   entity layer indexed under its own type rather than this domain.
        public nonisolated func configure(
            visibility: @escaping @Sendable () -> SystemSearchVisibility,
            associate: AssociationHook? = nil,
            purgeEntities: (@Sendable () async -> Void)? = nil
        ) {
            configuration.withLock {
                $0.visibility = visibility
                $0.associate = associate
                $0.purgeEntities = purgeEntities
            }
        }

        public nonisolated var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

        public func donate(_ donations: [SpotlightDonation]) async throws {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            let (visibility, associate) = configuration.withLock { ($0.visibility(), $0.associate) }
            let gated = SpotlightVisibilityGate.apply(visibility, to: donations)

            // What the index already holds comes out here, so a donation of unchanged content
            // costs a lookup and nothing reaches Core Spotlight at all.
            var gate = self.gate
            let plan = gate.plan(gated)
            let skipped = donations.count - plan.index.count - plan.remove.count
            guard !plan.isEmpty else { return }
            defer {
                self.gate = gate
                gateStore.save(gate)
            }

            // `.off` turns each donation into a removal: an earlier pass under a more
            // permissive setting may have left the document there, and "off" has to mean the
            // system index holds nothing of ours, not merely that we stopped adding to it. The
            // gate drops removals of documents it knows are already gone.
            if !plan.remove.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: plan.remove)
                gate.didRemove(plan.remove)
            }

            var start = 0
            while start < plan.index.count {
                let chunk = Array(plan.index[start..<min(start + Self.batchSize, plan.index.count)])
                start += chunk.count
                let items = chunk.map { Self.item(for: $0, associate: associate) }
                do {
                    try await index.indexSearchableItems(items)
                } catch {
                    // Whether any of these landed is unknown; the next donation sends them again.
                    gate.didFail(chunk.map(\.uniqueIdentifier))
                    throw error
                }
                gate.didIndex(chunk)
            }
            if plan.index.count + plan.remove.count > 1 || skipped > 0 {
                log(
                    "spotlight  indexed=\(plan.index.count) removed=\(plan.remove.count) "
                        + "unchanged=\(max(0, skipped))")
            }
        }

        /// One index document. People go in twice: as participants, which is what they are, and
        /// among the keywords, which is what a typed name is matched against.
        private static func item(
            for donation: SpotlightDonation, associate: AssociationHook?
        ) -> CSSearchableItem {
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = donation.title
            attributes.contentDescription = donation.contentDescription
            attributes.textContent = donation.textContent
            var keywords = donation.keywords
            for person in donation.people where !keywords.contains(person) {
                keywords.append(person)
            }
            attributes.keywords = keywords.isEmpty ? nil : keywords
            attributes.participants = donation.people.isEmpty ? nil : donation.people
            attributes.contentCreationDate = Date(
                timeIntervalSince1970: Double(donation.contentCreationDateMs) / 1000.0
            )
            if let startMs = donation.startDateMs {
                attributes.startDate = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
            }
            if let endMs = donation.endDateMs {
                attributes.endDate = Date(timeIntervalSince1970: Double(endMs) / 1000.0)
            }
            attributes.contentURL = URL(string: donation.deepLinkURL)
            let item = CSSearchableItem(
                uniqueIdentifier: donation.uniqueIdentifier,
                domainIdentifier: Self.domainIdentifier,
                attributeSet: attributes
            )
            associate?(item, donation)
            return item
        }

        /// Never gated: a removal is a delete the person asked for, or retention ageing content
        /// out, and it must reach the index whatever the gate believes.
        public func remove(uniqueIdentifiers: [String]) async throws {
            guard CSSearchableIndex.isIndexingAvailable(), !uniqueIdentifiers.isEmpty else {
                return
            }
            try await index.deleteSearchableItems(withIdentifiers: uniqueIdentifiers)
            var gate = self.gate
            gate.didRemove(uniqueIdentifiers)
            self.gate = gate
            gateStore.save(gate)
        }

        public func removeAll() async throws {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            try await index.deleteSearchableItems(
                withDomainIdentifiers: [Self.domainIdentifier]
            )
            var gate = self.gate
            gate.didRemoveAll()
            self.gate = gate
            gateStore.save(gate)
            // The entity associations live on the items just deleted; this covers anything the
            // entity layer may have indexed under its own type (a system-driven reindex, say)
            // so a flip to "off" leaves nothing of ours behind under either name.
            if let purge = configuration.withLock({ $0.purgeEntities }) {
                await purge()
            }
        }
    }
#endif
