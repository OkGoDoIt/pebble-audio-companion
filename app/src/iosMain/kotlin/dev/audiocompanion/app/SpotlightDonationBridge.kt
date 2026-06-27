package dev.audiocompanion.app

import dev.audiocompanion.ai.ActionItem
import dev.audiocompanion.ai.DailyDigest
import dev.audiocompanion.ai.SegmentAnnotation

/**
 * Swift bridge hook for Core Spotlight donation on iOS. Registered from [AppDelegate].
 */
interface SpotlightDonationBridge {
    fun donateSegment(
        id: String,
        title: String,
        summary: String?,
        tags: List<String>,
        creationMs: Long,
    )

    fun donateDigest(digest: DailyDigest) {
        donateSegment(
            id = "day-${digest.dateKey}",
            title = digest.dateKey,
            summary = digest.text.take(500),
            tags = emptyList(),
            creationMs = digest.createdAtMs,
        )
    }

    fun donateActionItem(item: ActionItem) {
        donateSegment(
            id = item.id,
            title = item.text,
            summary = null,
            tags = emptyList(),
            creationMs = item.createdAtMs,
        )
    }

    fun remove(id: String)
}

object SpotlightDonationBridgeRegistry {
    var bridge: SpotlightDonationBridge? = null
}
