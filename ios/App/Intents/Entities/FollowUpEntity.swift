import AppDB
import AppIntents
import CoreSpotlight
import Foundation
import GeoToolbox
import SearchKit

// A follow-up as a `.reminders.reminder`: the sentence is the title, the extractor's "why" is
// the note, done/due/flagged map onto what the schema has (priority collapses to `isFlagged`
// — the schema knows no levels). Only the ENTITY is adopted; none of the reminders intents
// are, so Siri can read and open follow-ups but the app's own screens stay the only place
// they are created, completed or deleted.
//
// The schema requires a list, so every follow-up sits in one fixed list ("Follow-ups") and a
// list type, both of which exist only to satisfy it.

@available(iOS 27, *)
@AppEntity(schema: .reminders.reminder)
struct FollowUpEntity: IndexedEntity {
    static let defaultQuery = FollowUpEntityQuery()

    let id: String

    var title: String
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: FollowUpListEntity
    /// Always nil: follow-ups are never tied to a place. The schema still needs the type.
    var locationTrigger: FollowUpLocationTriggerEntity?

    /// The conversation it was extracted from, when that is known.
    @Property(title: "Conversation")
    var conversation: ConversationEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: .init(systemName: isCompleted ? "checkmark.circle" : "circle")
        )
    }

    /// "Done" / "Due Today" / nothing — the row meta, one word at a time.
    private var subtitle: String? {
        if isCompleted { return "Done" }
        guard let due = dueDate.flatMap(Calendar.current.date(from:)) else { return nil }
        return "Due \(TimeFmt.dayLabel(for: due))"
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = note.map { String($0.characters) }
        attributes.contentCreationDate = creationDate
        attributes.completionDate = completionDate
        attributes.dueDate = dueDate.flatMap(Calendar.current.date(from:))
        attributes.contentURL = URL(string: SpotlightDonator.deepLink(kind: .followUp, entityId: id))
        return attributes
    }

    var hideInSpotlight: Bool { EntityMapping.hideInSpotlight(EntityVisibility.current()) }

    init(snapshot: FollowUpEntitySnapshot, conversation: ConversationEntity?) {
        id = snapshot.id
        title = snapshot.text
        note = EntityMapping.followUpNote(why: snapshot.why).map(AttributedString.init)
        tags = []
        urls = []
        dueDate = EntityMapping.dueDateComponents(dueAtMs: snapshot.dueAtMs)
        recurrence = nil
        isCompleted = snapshot.done
        isFlagged = EntityMapping.isFlagged(priority: snapshot.priority)
        creationDate = EntityMapping.date(ms: snapshot.createdAtMs)
        completionDate = EntityMapping.optionalDate(ms: snapshot.completedAtMs)
        list = .followUps
        locationTrigger = nil
        self.conversation = conversation
    }

    /// From a donation alone (the indexing pass): a follow-up donation carries only its text
    /// and creation date, so the entity is the open, undated shape of it.
    init?(donation: SpotlightDonation) {
        guard donation.kind == .followUp else { return nil }
        self.init(
            snapshot: FollowUpEntitySnapshot(
                id: donation.entityId,
                text: donation.title,
                done: false,
                dueAtMs: nil,
                priority: .normal,
                createdAtMs: donation.contentCreationDateMs,
                completedAtMs: nil,
                sourceConversationId: nil,
                why: nil
            ),
            conversation: nil
        )
    }
}

@available(iOS 27, *)
struct FollowUpEntityQuery: EntityStringQuery, IndexedEntityQuery {
    private static let suggestionLimit = 12
    private static let matchLimit = 20

    func entities(for identifiers: [String]) async throws -> [FollowUpEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [FollowUpEntity] = []
        for id in identifiers {
            if let snapshot = await source.followUp(id: id) {
                out.append(await Self.entity(snapshot, visibility: visibility, source: source))
            }
        }
        return out
    }

    func entities(matching string: String) async throws -> [FollowUpEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [FollowUpEntity] = []
        for snapshot in await source.followUps(matching: string, limit: Self.matchLimit) {
            out.append(await Self.entity(snapshot, visibility: visibility, source: source))
        }
        return out
    }

    /// The open list, in its own order (due first, then priority, then newest).
    func suggestedEntities() async throws -> [FollowUpEntity] {
        let source = await EntityDataSources.current
        let visibility = await source.visibility()
        var out: [FollowUpEntity] = []
        for snapshot in await source.followUps(
            scope: .everything, includeDone: false, limit: Self.suggestionLimit)
        {
            out.append(await Self.entity(snapshot, visibility: visibility, source: source))
        }
        return out
    }

    static func entity(
        _ snapshot: FollowUpEntitySnapshot, visibility: SystemSearchVisibility,
        source: any EntityDataSource
    ) async -> FollowUpEntity {
        var conversation: ConversationEntity?
        if let conversationId = snapshot.sourceConversationId,
            let conversationSnapshot = await source.conversation(id: conversationId)
        {
            conversation = ConversationEntity(snapshot: conversationSnapshot, visibility: visibility)
        }
        return FollowUpEntity(snapshot: snapshot, conversation: conversation)
    }

    func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        await EntityDataSources.current.reindex(followUpIds: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await EntityDataSources.current.reindexEverything()
    }
}

// MARK: - The list and list type the schema requires

@available(iOS 27, *)
@AppEntity(schema: .reminders.list)
struct FollowUpListEntity {
    static let defaultQuery = FollowUpListEntityQuery()
    static let followUps = FollowUpListEntity(
        id: EntityMapping.followUpListId, name: EntityMapping.followUpListName)

    let id: String
    var name: String
    var type: FollowUpListType

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "checklist"))
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.type = .standard
    }
}

@available(iOS 27, *)
struct FollowUpListEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FollowUpListEntity] {
        identifiers.contains(EntityMapping.followUpListId) ? [.followUps] : []
    }

    func suggestedEntities() async throws -> [FollowUpListEntity] { [.followUps] }
}

@available(iOS 27, *)
@AppEnum(schema: .reminders.listType)
enum FollowUpListType: String {
    case standard

    static let caseDisplayRepresentations: [FollowUpListType: DisplayRepresentation] = [
        .standard: "Standard"
    ]
}

/// The schema names a location-trigger entity type even though this app never sets one:
/// `FollowUpEntity.locationTrigger` is always nil and this query answers nothing. It exists
/// because the metadata processor requires the property, and the property requires a type.
@available(iOS 27, *)
@AppEntity(schema: .reminders.locationTrigger)
struct FollowUpLocationTriggerEntity {
    static let defaultQuery = FollowUpLocationTriggerEntityQuery()

    let id: String
    var place: PlaceDescriptor
    var event: FollowUpLocationTriggerEvent

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Location")
    }
}

@available(iOS 27, *)
struct FollowUpLocationTriggerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FollowUpLocationTriggerEntity] { [] }
}

@available(iOS 27, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum FollowUpLocationTriggerEvent: String {
    case arrive
    case depart

    static let caseDisplayRepresentations: [FollowUpLocationTriggerEvent: DisplayRepresentation] = [
        .arrive: "Arrive",
        .depart: "Depart",
    ]
}
