import Foundation
import WireProtocol

// Port of `core/storage/.../RetentionManager.kt`.

/// Platform seam for free-space queries (NSFileManager in the app; fakes in tests).
public protocol FreeSpaceProvider: Sendable {
    func freeBytes() -> Int64
}

public struct RetentionConfig: Sendable {
    /// Total cap for stored audio (default 2 GB).
    public var maxTotalBytes: Int64
    /// Maximum segment age (default 30 days).
    public var maxAgeMs: Int64
    /// Below this much free device storage the LOW_STORAGE receiver flag is set (500 MB).
    public var lowStorageFloorBytes: Int64
    /// Below this much free device storage we ask the watch to pause (200 MB).
    public var pauseFloorBytes: Int64

    public init(
        maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000,
        lowStorageFloorBytes: Int64 = 500 * 1024 * 1024,
        pauseFloorBytes: Int64 = 200 * 1024 * 1024
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxAgeMs = maxAgeMs
        self.lowStorageFloorBytes = lowStorageFloorBytes
        self.pauseFloorBytes = pauseFloorBytes
    }
}

/// Retention policy over the segment store (plan 6.2): user-configurable cap, delete oldest
/// fully-transcribed audio first, never delete the open segment, and surface low-storage /
/// pause-requested flags into the CHECKPOINT messages via `ReceiverPolicy`.
public final class RetentionManager: ReceiverPolicy, Sendable {
    private let store: SegmentStore
    private let freeSpace: FreeSpaceProvider
    private let nowMs: @Sendable () -> Int64
    private let configProvider: @Sendable () -> RetentionConfig

    /// The policy in force right now. Read through the provider on every use so a settings
    /// change ("Keep audio for N days") takes effect on the next pass, not the next launch.
    private var config: RetentionConfig { configProvider() }

    public convenience init(
        store: SegmentStore,
        freeSpace: FreeSpaceProvider,
        nowMs: @escaping @Sendable () -> Int64,
        config: RetentionConfig = RetentionConfig()
    ) {
        self.init(store: store, freeSpace: freeSpace, nowMs: nowMs, config: { config })
    }

    /// Live-policy variant: the app passes a closure over its settings so the user-configurable
    /// cap is honoured without rebuilding the manager.
    public init(
        store: SegmentStore,
        freeSpace: FreeSpaceProvider,
        nowMs: @escaping @Sendable () -> Int64,
        config: @escaping @Sendable () -> RetentionConfig
    ) {
        self.store = store
        self.freeSpace = freeSpace
        self.nowMs = nowMs
        self.configProvider = config
    }

    /// Applies age and size caps. Returns the segment ids deleted.
    public func enforce() async throws -> [String] {
        var deleted: [String] = []
        let openId = await store.openSegmentId

        // Age cap first. Audio the migration importer recovered from `quarantine/` is exempt:
        // it is older than the window by definition (that is why it was orphaned long enough to
        // outlive its sidecar), so applying the age rule would delete it again on the first
        // sweep after recovery. Nothing is done behind the user's back — the retention SETTING
        // is untouched and still governs every other segment, the size cap below still applies
        // to recovered audio, and a manual delete still removes it.
        let now = nowMs()
        var segments = await store.listSegments()
        for meta in segments
        where meta.segmentId != openId && !meta.isRecovered
            && now - meta.receivedAtMs > config.maxAgeMs
        {
            try await store.deleteSegment(meta.segmentId)
            deleted.append(meta.segmentId)
        }

        // Size cap: delete oldest fully-transcribed first, then oldest untranscribed, and
        // recovered audio last of all; the open segment is never deleted.
        segments = await store.listSegments()
        var total: Int64 = 0
        for meta in segments {
            total += await store.logSizeBytes(meta.segmentId)
        }
        if total <= config.maxTotalBytes { return deleted }
        let candidates = segments
            .enumerated()
            .filter { $0.element.segmentId != openId }
            .sorted { a, b in
                // Recovered audio is evicted LAST. The age cap already exempts it (see above);
                // letting the size cap take it first would undo a migration recovery the user
                // deliberately performed — audio that exists nowhere else, and that is older than
                // everything around it, so an "oldest first" rule would target it immediately. It
                // is still evictable: this is an ordering, not a second exemption, so a spool over
                // the cap with nothing but recovered audio in it still shrinks.
                if a.element.isRecovered != b.element.isRecovered {
                    return b.element.isRecovered  // not-recovered first
                }
                if a.element.isFullyTranscribed != b.element.isFullyTranscribed {
                    return a.element.isFullyTranscribed  // transcribed first
                }
                if a.element.receivedAtMs != b.element.receivedAtMs {
                    return a.element.receivedAtMs < b.element.receivedAtMs
                }
                return a.offset < b.offset  // stable, matching Kotlin's sortedWith
            }
            .map(\.element)
        for meta in candidates {
            if total <= config.maxTotalBytes { break }
            total -= await store.logSizeBytes(meta.segmentId)
            try await store.deleteSegment(meta.segmentId)
            deleted.append(meta.segmentId)
        }
        return deleted
    }

    public var lowStorage: Bool { freeSpace.freeBytes() < config.lowStorageFloorBytes }
    public var pauseRequested: Bool { freeSpace.freeBytes() < config.pauseFloorBytes }

    public func receiverFlags() -> UInt32 {
        var flags: UInt32 = 0
        if lowStorage { flags |= ProtocolConstants.receiverFlagLowStorage }
        if pauseRequested { flags |= ProtocolConstants.receiverFlagPauseRequested }
        return flags
    }

    public func freeStorageHintKb() -> UInt32 {
        let kb = freeSpace.freeBytes() / 1024
        if kb >= Int64(UInt32.max) { return UInt32.max }
        return UInt32(max(kb, 0))
    }
}
