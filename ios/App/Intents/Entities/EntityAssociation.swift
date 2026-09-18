import AppIntents
import CoreSpotlight
import Foundation
import SearchKit

// The iOS 27 half of Spotlight donation: every `CSSearchableItem` the indexer writes gets the
// App Intents entity that stands behind it attached (`associateAppEntity`), so Spotlight
// shows ONE result per document and Siri, asked about it, resolves the entity rather than a
// bare search hit. The entity is built from the donation alone — no database round trip
// inside the indexing pass — and the donation is already gated, so its text is exactly what
// the visibility setting allows.

@available(iOS 27, *)
enum EntityAssociation {
    /// `CoreSpotlightIndexer.AssociationHook`.
    static func associate(_ item: CSSearchableItem, donation: SpotlightDonation) {
        let visibility = EntityVisibility.current()
        switch donation.kind {
        case .conversation:
            if let entity = ConversationEntity(donation: donation, visibility: visibility) {
                item.associateAppEntity(entity)
            }
        case .note:
            if let entity = SavedNoteEntity(donation: donation, visibility: visibility) {
                item.associateAppEntity(entity)
            }
        case .recap:
            if let entity = RecapEntity(donation: donation, visibility: visibility) {
                item.associateAppEntity(entity)
            }
        case .followUp:
            if let entity = FollowUpEntity(donation: donation) {
                item.associateAppEntity(entity)
            }
        }
    }

    /// `CoreSpotlightIndexer`'s `purgeEntities` hook: anything indexed under an entity type's
    /// own name rather than our domain (a system-driven reindex can do that) goes too, so a
    /// flip to "off" leaves nothing of ours behind under either name.
    static func purgeAll() async {
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: ConversationEntity.self)
        try? await index.deleteAppEntities(ofType: SavedNoteEntity.self)
        try? await index.deleteAppEntities(ofType: RecapEntity.self)
        try? await index.deleteAppEntities(ofType: FollowUpEntity.self)
    }
}
