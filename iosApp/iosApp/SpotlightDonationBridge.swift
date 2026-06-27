import CoreSpotlight
import Foundation

/// Donates searchable items to Core Spotlight from the Swift shell (M3).
enum SpotlightDonationBridge {
    static let indexName = "dev.audiocompanion.transcripts"

    static func donate(
        id: String,
        domain: String,
        title: String,
        summary: String?,
        tags: [String],
        creationMs: Int64
    ) {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = title
        attrs.contentDescription = summary
        if !tags.isEmpty { attrs.keywords = tags }
        attrs.contentCreationDate = Date(timeIntervalSince1970: Double(creationMs) / 1000.0)
        let item = CSSearchableItem(
            uniqueIdentifier: id,
            domainIdentifier: domain,
            attributeSet: attrs
        )
        item.isUpdate = true
        CSSearchableIndex(name: indexName).indexSearchableItems([item]) { error in
            if let error { NSLog("Spotlight donate failed: \(error)") }
        }
    }

    static func remove(id: String) {
        CSSearchableIndex(name: indexName).deleteSearchableItems(withIdentifiers: [id]) { _ in }
    }
}
