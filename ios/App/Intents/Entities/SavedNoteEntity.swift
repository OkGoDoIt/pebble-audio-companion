import AppDB
import AppIntents
import CoreSpotlight
import Foundation
import SearchKit

// A saved note (an AI-written or hand-edited note attached to a conversation). Its body is
// its content — and only when the visibility setting lets text out; under `.summaries` a note
// is its title, exactly as the Spotlight gate leaves it.
//
// Not a `.notes.note` either, for the reason `RecapEntity` records: one type per schema per
// app, and the conversation took it. Same properties, plain indexed entity.

@available(iOS 27, *)
struct SavedNoteEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Note")
    static let defaultQuery = SavedNoteEntityQuery()

    let id: String

    @Property(title: "Title")
    var name: String
    @Property(title: "Body", indexingKey: \.textContent)
    var content: String?
    @Property(title: "Created")
    var creationDate: Date?
    @Property(title: "Edited")
    var modificationDate: Date?
    @Property(title: "Folder")
    var folder: LibraryDayEntity?

    /// The conversation the note was written about.
    @Property(title: "Conversation")
    var conversation: ConversationEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: creationDate.map { "\(TimeFmt.dayLabel(for: $0))" },
            image: .init(systemName: "note.text")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.textContent = content
        attributes.contentCreationDate = creationDate
        attributes.contentModificationDate = modificationDate
        attributes.contentURL = URL(string: SpotlightDonator.deepLink(kind: .note, entityId: id))
        return attributes
    }

    var hideInSpotlight: Bool { EntityMapping.hideInSpotlight(EntityVisibility.current()) }

    init(snapshot: NoteEntitySnapshot, visibility: SystemSearchVisibility, conversation: ConversationEntity?) {
        id = snapshot.id
        name = snapshot.title.nilIfBlank ?? "Note"
        content = EntityMapping.indexedTranscript(snapshot.body, visibility: visibility)
        creationDate = EntityMapping.date(ms: snapshot.createdAtMs)
        modificationDate = EntityMapping.optionalDate(ms: snapshot.editedAtMs) ?? creationDate
        folder = conversation?.folder
        self.conversation = conversation
    }

    /// From a donation alone (the indexing pass); the conversation link is left out because
    /// the donation does not carry it and the pass must not go back to the database.
    init?(donation: SpotlightDonation, visibility: SystemSearchVisibility) {
        guard donation.kind == .note else { return nil }
        self.init(
            snapshot: NoteEntitySnapshot(
                id: donation.entityId,
                conversationId: "",
                title: donation.title,
                body: donation.textContent,
                createdAtMs: donation.contentCreationDateMs,
                editedAtMs: nil
            ),
            visibility: visibility,
            conversation: nil
        )
    }
}

@available(iOS 27, *)
struct SavedNoteEntityQuery: EntityStringQuery, IndexedEntityQuery {
    private static let suggestionLimit = 12
    private static let matchLimit = 20

    func entities(for identifiers: [String]) async throws -> [SavedNoteEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [SavedNoteEntity] = []
        for id in identifiers {
            if let snapshot = await source.note(id: id) {
                out.append(await Self.entity(snapshot, visibility: visibility, source: source))
            }
        }
        return out
    }

    func entities(matching string: String) async throws -> [SavedNoteEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [SavedNoteEntity] = []
        for snapshot in await source.notes(matching: string, limit: Self.matchLimit) {
            out.append(await Self.entity(snapshot, visibility: visibility, source: source))
        }
        return out
    }

    func suggestedEntities() async throws -> [SavedNoteEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [SavedNoteEntity] = []
        for snapshot in await source.notes(limit: Self.suggestionLimit) {
            out.append(await Self.entity(snapshot, visibility: visibility, source: source))
        }
        return out
    }

    private static func entity(
        _ snapshot: NoteEntitySnapshot, visibility: SystemSearchVisibility,
        source: any EntityDataSource
    ) async -> SavedNoteEntity {
        let conversation = await source.conversation(id: snapshot.conversationId)
            .map { ConversationEntity(snapshot: $0, visibility: visibility) }
        return SavedNoteEntity(snapshot: snapshot, visibility: visibility, conversation: conversation)
    }

    func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        await EntityDataSources.current.reindex(noteIds: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await EntityDataSources.current.reindexEverything()
    }
}
