import AudioCompanionApp
import CoreSpotlight
import Foundation

enum SpotlightBridge {
    static func register() {
        SpotlightDonationBridgeRegistry.shared.bridge = KotlinSpotlightBridge()
    }
}

final class KotlinSpotlightBridge: NSObject, SpotlightDonationBridge {
    func donateSegment(
        id: String,
        title: String,
        summary: String?,
        tags: [String],
        creationMs: Int64
    ) {
        SpotlightDonationBridge.donate(
            id: id,
            domain: "segment",
            title: title,
            summary: summary,
            tags: tags,
            creationMs: creationMs
        )
    }

    func remove(id: String) {
        SpotlightDonationBridge.remove(id: id)
    }
}
