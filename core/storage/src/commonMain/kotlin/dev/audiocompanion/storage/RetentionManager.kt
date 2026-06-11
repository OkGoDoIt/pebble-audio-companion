package dev.audiocompanion.storage

import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.transport.ReceiverPolicy

/** Platform seam for free-space queries (StatFs / NSFileManager later; fakes in tests). */
interface FreeSpaceProvider {
    fun freeBytes(): Long
}

data class RetentionConfig(
    /** Total cap for stored audio (default 2 GB). */
    val maxTotalBytes: Long = 2L * 1024 * 1024 * 1024,
    /** Maximum segment age (default 30 days). */
    val maxAgeMs: Long = 30L * 24 * 60 * 60 * 1000,
    /** Below this much free device storage the LOW_STORAGE receiver flag is set (500 MB). */
    val lowStorageFloorBytes: Long = 500L * 1024 * 1024,
    /** Below this much free device storage we ask the watch to pause (200 MB). */
    val pauseFloorBytes: Long = 200L * 1024 * 1024,
)

/**
 * Retention policy over the segment store (plan 6.2): user-configurable cap, delete oldest
 * fully-transcribed audio first, never delete the open segment, and surface low-storage /
 * pause-requested flags into the CHECKPOINT messages via [ReceiverPolicy].
 */
class RetentionManager(
    private val store: SegmentStore,
    private val freeSpace: FreeSpaceProvider,
    private val nowMs: () -> Long,
    private val config: RetentionConfig = RetentionConfig(),
) : ReceiverPolicy {

    /** Applies age and size caps. Returns the segment ids deleted. */
    fun enforce(): List<String> {
        val deleted = mutableListOf<String>()
        val openId = store.openSegmentId

        fun delete(meta: SegmentMeta) {
            store.deleteSegment(meta.segmentId)
            deleted += meta.segmentId
        }

        // Age cap first.
        val now = nowMs()
        var segments = store.listSegments()
        segments.filter { it.segmentId != openId && now - it.receivedAtMs > config.maxAgeMs }
            .forEach { delete(it) }

        // Size cap: delete oldest fully-transcribed first, then oldest untranscribed;
        // the open segment is never deleted.
        segments = store.listSegments()
        var total = segments.sumOf { store.logSizeBytes(it.segmentId) }
        if (total <= config.maxTotalBytes) return deleted
        val candidates = segments
            .filter { it.segmentId != openId }
            .sortedWith(compareByDescending<SegmentMeta> { it.isFullyTranscribed }.thenBy { it.receivedAtMs })
        for (meta in candidates) {
            if (total <= config.maxTotalBytes) break
            total -= store.logSizeBytes(meta.segmentId)
            delete(meta)
        }
        return deleted
    }

    val lowStorage: Boolean get() = freeSpace.freeBytes() < config.lowStorageFloorBytes
    val pauseRequested: Boolean get() = freeSpace.freeBytes() < config.pauseFloorBytes

    override fun receiverFlags(): UInt {
        var flags = 0u
        if (lowStorage) flags = flags or ProtocolConstants.RECEIVER_FLAG_LOW_STORAGE
        if (pauseRequested) flags = flags or ProtocolConstants.RECEIVER_FLAG_PAUSE_REQUESTED
        return flags
    }

    override fun freeStorageHintKb(): UInt {
        val kb = freeSpace.freeBytes() / 1024
        return if (kb >= UInt.MAX_VALUE.toLong()) UInt.MAX_VALUE else kb.coerceAtLeast(0).toUInt()
    }
}
