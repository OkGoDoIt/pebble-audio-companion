import AppDB
import AppIntents
import CoreSpotlight
import Foundation
import SearchKit

// A conversation, as Siri, Spotlight and Shortcuts see it on iOS 27 (plan "Native-surface
// plan": the entity model defined at v1, filled in here). It conforms to the system's
// `.notes.note` schema so Siri understands it without any app-specific vocabulary: a
// conversation has a name (its title), content (its summary, and its transcript when the
// visibility setting allows text out), and the dates it was recorded.
//
// Ids are the `conv-…` conversation ids. They are stable except across a split or join, which
// re-derives the grouping and can retire an id — acceptable: a stale id resolves to nothing,
// and the query answers "no such conversation" rather than the wrong one.
//
// The whole type is `@available(iOS 27, *)`: the `.notes` schema domain is iOS 27, and the
// macro fixes the schema at the type, so there is no iOS 26 shape of it. Below 27 nothing here
// exists and the app behaves exactly as it did.
//
// Two things the metadata processor taught, recorded because the documentation does not say
// them: a schema entity must NOT declare `typeDisplayRepresentation` (the schema names the
// type — "Note" here — and the processor warns on an override), and every schema property must
// be present even when its type is optional (`folder` is required; `nil` is fine).

@available(iOS 27, *)
@AppEntity(schema: .notes.note)
struct ConversationEntity: IndexedEntity {
    static let defaultQuery = ConversationEntityQuery()

    let id: String

    var name: AttributedString
    var content: AttributedString?
    /// Empty for now. An `IntentFile` of the exported audio is a follow-up, not this session.
    var attachments: [IntentFile]
    var isPinned: Bool
    var creationDate: Date?
    var modificationDate: Date?
    /// The logical day the conversation belongs to — the Library's section.
    var folder: LibraryDayEntity?

    /// The words that were said, on their own, for a Shortcut that wants only them. Nil
    /// unless the visibility setting is `.full`. Not an indexing key: the schema already maps
    /// `content` — which holds the transcript under `.full` — to the item's `textContent`, and
    /// the metadata processor refuses two properties on one key.
    @Property(title: "Transcript")
    var transcript: String?

    @Property(title: "Summary", indexingKey: \.contentDescription)
    var summary: String?

    @Property(title: "Tags")
    var tags: [String]

    @Property(title: "Duration (minutes)")
    var durationMinutes: Int

    /// "Today · 9:12 AM", in the recorded time zone.
    @Property(title: "When")
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(String(name.characters))",
            subtitle: "\(subtitle)",
            image: .init(systemName: "waveform")
        )
    }

    /// The document Spotlight holds for this entity — the same fields the donation carries, so
    /// association merges cleanly rather than overwriting one with a thinner version.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = String(name.characters)
        attributes.contentDescription = summary
        attributes.textContent = transcript
        attributes.keywords = tags.isEmpty ? nil : tags
        attributes.contentCreationDate = creationDate
        attributes.startDate = creationDate
        attributes.endDate = modificationDate
        attributes.contentURL = URL(string: SpotlightDonator.deepLink(kind: .conversation, entityId: id))
        return attributes
    }

    var hideInSpotlight: Bool { EntityMapping.hideInSpotlight(EntityVisibility.current()) }

    init(snapshot: ConversationEntitySnapshot, visibility: SystemSearchVisibility) {
        id = snapshot.id
        name = AttributedString(EntityMapping.conversationTitle(snapshot.title))
        content = EntityMapping.conversationContent(
            summary: snapshot.summary, transcript: snapshot.transcript, visibility: visibility
        ).map(AttributedString.init)
        attachments = []
        isPinned = false
        creationDate = EntityMapping.date(ms: snapshot.startMs)
        modificationDate = EntityMapping.date(ms: snapshot.endMs)
        folder = LibraryDayEntity(dateKey: snapshot.dateKey)
        transcript = EntityMapping.indexedTranscript(snapshot.transcript, visibility: visibility)
        summary = snapshot.summary?.nilIfBlank
        tags = snapshot.tags
        durationMinutes = Int(max(0, snapshot.endMs - snapshot.startMs) / 60_000)
        subtitle = EntityMapping.conversationSubtitle(
            startMs: snapshot.startMs, dateKey: snapshot.dateKey, timeZoneID: snapshot.timeZoneID
        )
    }

    /// The entity for a Spotlight donation, built from the donation alone (no database round
    /// trip inside the indexing pass). The donation is already gated, so its `textContent` is
    /// exactly what the setting allows.
    init?(donation: SpotlightDonation, visibility: SystemSearchVisibility) {
        guard donation.kind == .conversation else { return nil }
        let startMs = donation.startDateMs ?? donation.contentCreationDateMs
        self.init(
            snapshot: ConversationEntitySnapshot(
                id: donation.entityId,
                title: donation.title,
                summary: donation.contentDescription,
                startMs: startMs,
                endMs: startMs,
                timeZoneID: TimeZone.current.identifier,
                dateKey: LogicalDay.dateKey(forMs: startMs, timeZoneID: TimeZone.current.identifier),
                tags: donation.keywords,
                isLive: false,
                transcript: donation.textContent
            ),
            visibility: visibility
        )
    }
}

/// The lookup seam: ids, free text, and the system's reindex requests.
@available(iOS 27, *)
struct ConversationEntityQuery: EntityStringQuery, IndexedEntityQuery {
    private static let suggestionLimit = 12
    private static let matchLimit = 20

    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [ConversationEntity] = []
        for id in identifiers {
            if let snapshot = await source.conversation(id: id) {
                out.append(ConversationEntity(snapshot: snapshot, visibility: visibility))
            }
        }
        return out
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        return await source.conversations(matching: string, limit: Self.matchLimit)
            .map { ConversationEntity(snapshot: $0, visibility: visibility) }
    }

    /// Today's conversations, newest first — what a person most likely means by "that
    /// conversation" when Siri has to offer choices.
    func suggestedEntities() async throws -> [ConversationEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        return await source.conversations(scope: .today, tag: nil, limit: Self.suggestionLimit)
            .map { ConversationEntity(snapshot: $0, visibility: visibility) }
    }

    func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        await EntityDataSources.current.reindex(conversationIds: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await EntityDataSources.current.reindexEverything()
    }
}

extension String {
    /// Shared by the entity initialisers: an empty or whitespace-only value is "absent".
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
