import AppDB
import AppIntents
import CoreSpotlight
import Foundation
import Intelligence
import SearchKit

// A day's recap: named after the day, its content the digest — present unless the visibility
// setting is off, because a recap is a summary and "titles and summaries" includes it. Ids
// are `day-<dateKey>`, the same document id the search index uses.
//
// Not a `.notes.note`. The plan wanted conversations, saved notes and recaps all on that
// schema; the metadata processor refuses more than one type per app on one schema
// ("Only 1 type per app is allowed to conform to Assistant schema identifier 'NoteEntity'"),
// and the conversation is the one Siri most needs to understand. This is a plain indexed
// entity with the same properties, so Shortcuts and Spotlight see it all the same.

@available(iOS 27, *)
struct RecapEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recap")
    static let defaultQuery = RecapEntityQuery()

    let id: String

    @Property(title: "Day")
    var name: String
    @Property(title: "Recap", indexingKey: \.textContent)
    var content: String?
    @Property(title: "Date")
    var creationDate: Date?
    @Property(title: "Updated")
    var modificationDate: Date?
    @Property(title: "Folder")
    var folder: LibraryDayEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Recap",
            image: .init(systemName: "text.book.closed")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.textContent = content
        attributes.contentDescription = content.map { String($0.prefix(500)) }
        attributes.contentCreationDate = creationDate
        attributes.contentModificationDate = modificationDate
        attributes.contentURL = URL(string: SpotlightDonator.deepLink(kind: .recap, entityId: id))
        return attributes
    }

    var hideInSpotlight: Bool { EntityMapping.hideInSpotlight(EntityVisibility.current()) }

    static func id(dateKey: String) -> String { RecapIndex.documentId(dateKey: dateKey) }

    /// The reverse of `id(dateKey:)`; nil for anything that is not a recap id.
    static func dateKey(id: String) -> String? {
        guard id.hasPrefix("day-") else { return nil }
        let key = String(id.dropFirst(4))
        return EntityMapping.isDayKey(key) ? key : nil
    }

    init(snapshot: RecapEntitySnapshot, visibility: SystemSearchVisibility) {
        id = Self.id(dateKey: snapshot.dateKey)
        name = EntityMapping.recapTitle(dateKey: snapshot.dateKey)
        content = visibility.donates ? snapshot.text?.nilIfBlank : nil
        let bounds = LogicalDay.bounds(ofDateKey: snapshot.dateKey, timeZoneID: TimeZone.current.identifier)
        creationDate = bounds.map { EntityMapping.date(ms: $0.startMs) }
        modificationDate = EntityMapping.date(ms: snapshot.updatedAtMs)
        folder = LibraryDayEntity(dateKey: snapshot.dateKey)
    }

    init?(donation: SpotlightDonation, visibility: SystemSearchVisibility) {
        guard donation.kind == .recap, let dateKey = Self.dateKey(id: donation.entityId) else {
            return nil
        }
        self.init(
            snapshot: RecapEntitySnapshot(
                dateKey: dateKey,
                text: donation.textContent ?? donation.contentDescription,
                shortText: nil,
                updatedAtMs: donation.contentCreationDateMs
            ),
            visibility: visibility
        )
    }
}

@available(iOS 27, *)
struct RecapEntityQuery: EntityStringQuery, IndexedEntityQuery {
    private static let suggestionLimit = 14

    func entities(for identifiers: [String]) async throws -> [RecapEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [RecapEntity] = []
        for id in identifiers {
            guard let dateKey = RecapEntity.dateKey(id: id),
                let snapshot = await source.recap(dateKey: dateKey)
            else { continue }
            out.append(RecapEntity(snapshot: snapshot, visibility: visibility))
        }
        return out
    }

    /// Recaps are named by day, so a string matches on the day's name ("today",
    /// "September 17") — searching their text is the Search screen's job, not a picker's.
    func entities(matching string: String) async throws -> [RecapEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return try await suggestedEntities().filter {
            $0.name.lowercased().contains(needle) || $0.id.contains(needle)
        }
    }

    func suggestedEntities() async throws -> [RecapEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        return await source.recaps(limit: Self.suggestionLimit)
            .map { RecapEntity(snapshot: $0, visibility: visibility) }
    }

    func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        await EntityDataSources.current.reindex(
            recapDateKeys: identifiers.compactMap(RecapEntity.dateKey(id:)))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await EntityDataSources.current.reindexEverything()
    }
}
