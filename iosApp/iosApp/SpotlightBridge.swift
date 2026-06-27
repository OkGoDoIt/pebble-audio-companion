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
        NativeSpotlightDonation.donate(
            id: id,
            domain: "segment",
            title: title,
            summary: summary,
            tags: tags,
            creationMs: creationMs
        )
    }

    func remove(id: String) {
        NativeSpotlightDonation.remove(id: id)
    }

    func donateDigest(digest: AiDailyDigest) {
        NativeSpotlightDonation.donate(
            id: "day-\(digest.dateKey)",
            domain: "day",
            title: digest.dateKey,
            summary: String(digest.text.prefix(500)),
            tags: [],
            creationMs: digest.createdAtMs
        )
    }

    func donateActionItem(item: AiActionItem) {
        NativeSpotlightDonation.donate(
            id: item.id,
            domain: "action",
            title: item.text,
            summary: nil,
            tags: [],
            creationMs: item.createdAtMs
        )
    }
}
