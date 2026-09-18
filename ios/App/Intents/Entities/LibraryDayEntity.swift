import AppDB
import AppIntents
import Foundation

// The `.notes.folder` the note schema requires every note to be able to name: for this app a
// folder is a logical day, which is also how the Library sections its rows. Siri can then ask
// for "today's conversations" through the schema's own folder relationship, with no
// app-specific vocabulary.

@available(iOS 27, *)
@AppEntity(schema: .notes.folder)
struct LibraryDayEntity {
    static let defaultQuery = LibraryDayEntityQuery()

    /// The `YYYY-MM-DD` logical-day key (5 AM boundary, recorded zone).
    let id: String

    var name: String
    var parentFolder: LibraryDayEntity?
    /// The schema wants an account; this app has exactly one place — this phone.
    var account: LibraryAccountEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "calendar"))
    }

    init(dateKey: String) {
        id = dateKey
        name = EntityMapping.dayFolderName(
            dateKey: dateKey,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            timeZoneID: TimeZone.current.identifier
        )
        parentFolder = nil
        account = .thisPhone
    }
}

/// The `.notes.account` the folder schema requires. There is no account in this product —
/// no server, no sign-in — so the one "account" is the phone the recordings live on, named
/// the way the privacy copy names it.
@available(iOS 27, *)
@AppEntity(schema: .notes.account)
struct LibraryAccountEntity {
    static let defaultQuery = LibraryAccountEntityQuery()
    static let thisPhoneId = "this-phone"
    static let thisPhone = LibraryAccountEntity(id: thisPhoneId, name: "This iPhone")

    let id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "iphone"))
    }

    /// Spelled out because the macro turns `name` into an `EntityProperty`, which the
    /// synthesised memberwise initialiser then expects a wrapper for.
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@available(iOS 27, *)
struct LibraryAccountEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LibraryAccountEntity] {
        identifiers.contains(LibraryAccountEntity.thisPhoneId) ? [.thisPhone] : []
    }

    func suggestedEntities() async throws -> [LibraryAccountEntity] { [.thisPhone] }
}

@available(iOS 27, *)
struct LibraryDayEntityQuery: EntityQuery {
    private static let suggestionLimit = 14

    /// Any well-formed day key is a day; the Library does not have to hold anything on it.
    func entities(for identifiers: [String]) async throws -> [LibraryDayEntity] {
        identifiers.filter(EntityMapping.isDayKey).map(LibraryDayEntity.init(dateKey:))
    }

    /// The days that actually have conversations, newest first.
    func suggestedEntities() async throws -> [LibraryDayEntity] {
        await EntityDataSources.current.libraryDayKeys(limit: Self.suggestionLimit)
            .map(LibraryDayEntity.init(dateKey:))
    }
}
