import AppDB
import CompanionRuntime
import Foundation

/// One item ready to go into a batch: the phone's own envelope (`ArchiveBatchItem.encoded`).
public struct PreparedItem: Sendable {
    public var key: ArchiveItemKey
    public var encoded: Data

    public init(key: ArchiveItemKey, encoded: Data) {
        self.key = key
        self.encoded = encoded
    }
}

/// Fills batches by the phone's rule (`ArchiveSyncService.buildBatch`): at most `maxItems`
/// items, and the body (512 bytes allowed for the envelope, plus each item and its comma) within
/// `maxBytes`, whichever comes first. An item that could never fit is refused on its own.
public struct BatchAssembler: Sendable {
    public var maxItems: Int
    public let maxBytes: Int
    public private(set) var items: [PreparedItem] = []
    private var bytes = BatchAssembler.envelopeBytes

    static let envelopeBytes = 512

    public init(
        maxItems: Int = ArchiveSyncProtocol.maxItemsPerBatch,
        maxBytes: Int = ArchiveSyncProtocol.maxBatchBytes
    ) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
    }

    /// Whether an item is too large to send in any batch.
    public func fitsAlone(_ item: PreparedItem) -> Bool {
        item.encoded.count + Self.envelopeBytes <= maxBytes
    }

    /// Adds `item`. When it does not fit beside what is waiting, the waiting batch is returned
    /// to be sent first and `item` starts the next one.
    public mutating func add(_ item: PreparedItem) -> [PreparedItem]? {
        var full: [PreparedItem]?
        if !items.isEmpty,
            items.count >= maxItems || bytes + item.encoded.count + 1 > maxBytes
        {
            full = drain()
        }
        items.append(item)
        bytes += item.encoded.count + 1
        return full
    }

    /// What is waiting, as the last batch.
    public mutating func drain() -> [PreparedItem]? {
        guard !items.isEmpty else { return nil }
        defer {
            items = []
            bytes = Self.envelopeBytes
        }
        return items
    }
}
