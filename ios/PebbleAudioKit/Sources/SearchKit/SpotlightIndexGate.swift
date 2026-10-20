import Foundation
import os

// What the system index already holds, so a donation of unchanged content does nothing.
//
// Several paths re-donate a conversation without anything about it having changed: the
// foreground pass re-donates everything that ended since its watermark (which the pipeline
// usually donated minutes earlier), a delete re-donates its neighbours, a system reindex request
// asks for ids that are already current, a relaunch repeats the last background pass. Each of
// those used to be a full Core Spotlight write of the conversation's transcript, and on iOS 27
// a fresh entity association too. The gate turns every one of them into a dictionary lookup.
//
// It sits AFTER the visibility gate, so what it fingerprints is exactly what the index would
// receive: turning "Siri & Spotlight can see" down or up changes the gated content, and so the
// fingerprint, and so re-indexes what has to change without any special case.
//
// Under "Off" a donation becomes a removal. The gate remembers which documents it knows are
// absent, so a conversation re-enriched ten times under "Off" asks Spotlight to delete it once.

/// Per-document memory of the system index: a fingerprint of what was last indexed, or a note
/// that the document is known to be absent. Pure value; `CoreSpotlightIndexer` owns one.
public struct SpotlightIndexGate: Equatable, Sendable {
    /// Bumped whenever the mapping from a donation to an index document changes (a new
    /// attribute, a new entity property), so the first pass after an update writes everything
    /// once instead of trusting fingerprints of documents the old mapping produced.
    public static let mappingVersion: UInt64 = 2

    /// The stored marker for "known absent". Fingerprints never take this value.
    static let absent: UInt64 = 0
    /// The stored marker for "may or may not be there": a write that failed part-way. Never a
    /// fingerprint either, so the next donation of the document is always sent.
    static let unknown: UInt64 = 1

    /// uniqueIdentifier → fingerprint of the indexed document, `absent`, or `unknown`.
    public private(set) var documents: [String: UInt64]
    /// True once the whole index is known to be empty apart from what `documents` records — after
    /// a `removeAll`. Until then an id the gate has never seen may still be in the index from an
    /// earlier install of this build, so a removal of it is sent rather than skipped.
    public private(set) var baselineEmpty: Bool

    public init(documents: [String: UInt64] = [:], baselineEmpty: Bool = false) {
        self.documents = documents
        self.baselineEmpty = baselineEmpty
    }

    /// What one pass has to do once everything already true is taken out.
    public struct Plan: Equatable, Sendable {
        public var index: [SpotlightDonation]
        public var remove: [String]

        public init(index: [SpotlightDonation], remove: [String]) {
            self.index = index
            self.remove = remove
        }

        public var isEmpty: Bool { index.isEmpty && remove.isEmpty }
    }

    /// The visibility gate's outcome, minus what the index already holds. Within one batch the
    /// last donation of a document wins, the way the index itself would resolve two writes.
    public func plan(_ outcome: SpotlightVisibilityGate.Outcome) -> Plan {
        var latest: [String: SpotlightDonation] = [:]
        var order: [String] = []
        for donation in outcome.index {
            if latest[donation.uniqueIdentifier] == nil { order.append(donation.uniqueIdentifier) }
            latest[donation.uniqueIdentifier] = donation
        }
        let index = order.compactMap { id -> SpotlightDonation? in
            guard let donation = latest[id] else { return nil }
            return documents[id] == Self.fingerprint(donation) ? nil : donation
        }
        var seen = Set<String>()
        let remove = outcome.remove.filter { id in
            guard seen.insert(id).inserted, latest[id] == nil else { return false }
            return isPossiblyIndexed(id)
        }
        return Plan(index: index, remove: remove)
    }

    /// Whether the index may hold this document: it was indexed, or the gate cannot rule it out.
    public func isPossiblyIndexed(_ uniqueIdentifier: String) -> Bool {
        switch documents[uniqueIdentifier] {
        case .some(let fingerprint): return fingerprint != Self.absent
        case .none: return !baselineEmpty
        }
    }

    public mutating func didIndex(_ donations: [SpotlightDonation]) {
        for donation in donations {
            documents[donation.uniqueIdentifier] = Self.fingerprint(donation)
        }
    }

    public mutating func didRemove(_ uniqueIdentifiers: [String]) {
        for id in uniqueIdentifiers { documents[id] = Self.absent }
    }

    /// A write that threw: these documents may hold the old content, the new, or nothing.
    public mutating func didFail(_ uniqueIdentifiers: [String]) {
        for id in uniqueIdentifiers { documents[id] = Self.unknown }
    }

    /// The whole domain was emptied: nothing is indexed, and anything not seen since is absent.
    public mutating func didRemoveAll() {
        documents.removeAll()
        baselineEmpty = true
    }

    /// The system dropped the index under us (a failed write, a reset): forget everything,
    /// including the empty baseline, so every next donation and removal is sent.
    public mutating func forgetEverything() {
        documents.removeAll()
        baselineEmpty = false
    }

    // MARK: - Fingerprint

    /// A stable 64-bit FNV-1a over every field that reaches the index, in a fixed order with
    /// separators, seeded with `mappingVersion`. Stable across launches on purpose — Swift's
    /// `Hasher` is reseeded per process and would make every relaunch look like a change.
    public static func fingerprint(_ donation: SpotlightDonation) -> UInt64 {
        var hash = FNV1a()
        hash.add(mappingVersion)
        hash.add(donation.uniqueIdentifier)
        hash.add(donation.title)
        hash.add(donation.contentDescription)
        hash.add(donation.textContent)
        hash.add(donation.keywords)
        hash.add(donation.people)
        hash.add(donation.deepLinkURL)
        hash.add(UInt64(bitPattern: donation.contentCreationDateMs))
        hash.add(donation.startDateMs.map { UInt64(bitPattern: $0) })
        hash.add(donation.endDateMs.map { UInt64(bitPattern: $0) })
        hash.add(donation.timeZoneID)
        hash.add(donation.dueDateMs.map { UInt64(bitPattern: $0) })
        hash.add(donation.completionDateMs.map { UInt64(bitPattern: $0) })
        hash.add(UInt64(donation.isCompleted ? 1 : 0) | UInt64(donation.isFlagged ? 2 : 0))
        // Never one of the two markers.
        return hash.value <= unknown ? hash.value + 2 : hash.value
    }

    private struct FNV1a {
        private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

        mutating func byte(_ byte: UInt8) {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }

        mutating func add(_ number: UInt64) {
            var n = number
            for _ in 0..<8 {
                byte(UInt8(truncatingIfNeeded: n))
                n >>= 8
            }
        }

        mutating func add(_ string: String) {
            add(UInt64(string.utf8.count))
            for unit in string.utf8 { byte(unit) }
        }

        /// A nil and an empty string fingerprint differently: the index treats them differently.
        mutating func add(_ string: String?) {
            guard let string else {
                byte(0)
                return
            }
            byte(1)
            add(string)
        }

        mutating func add(_ number: UInt64?) {
            guard let number else {
                byte(0)
                return
            }
            byte(1)
            add(number)
        }

        mutating func add(_ strings: [String]) {
            add(UInt64(strings.count))
            for string in strings { add(string) }
        }
    }
}

// MARK: - Persistence

/// Where the gate is kept between launches. Without it every relaunch would re-index each
/// document once, the first time anything donated it again.
public protocol SpotlightIndexGateStore: Sendable {
    func load() -> SpotlightIndexGate
    func save(_ gate: SpotlightIndexGate)
}

/// Keeps nothing: the gate lives only as long as the process. The default for tests and for
/// indexers built without a home on disk.
public struct EphemeralSpotlightIndexGateStore: SpotlightIndexGateStore {
    public init() {}
    public func load() -> SpotlightIndexGate { SpotlightIndexGate() }
    public func save(_ gate: SpotlightIndexGate) {}
}

/// One small JSON file. It must live in the app's OWN container, never the App Group: the
/// side-by-side Debug build shares the group with the main app but has its own Spotlight index,
/// and a shared gate would let one app's writes stand in for the other's.
public final class FileSpotlightIndexGateStore: SpotlightIndexGateStore {
    private let url: URL
    private let lock = OSAllocatedUnfairLock()

    public init(url: URL) {
        self.url = url
    }

    private struct Stored: Codable {
        var version: UInt64
        var baselineEmpty: Bool
        /// Hex strings: a JSON number cannot carry every UInt64 exactly.
        var documents: [String: String]
    }

    public func load() -> SpotlightIndexGate {
        lock.withLock {
            guard let data = try? Data(contentsOf: url),
                let stored = try? JSONDecoder().decode(Stored.self, from: data),
                stored.version == SpotlightIndexGate.mappingVersion
            else { return SpotlightIndexGate() }
            var documents: [String: UInt64] = [:]
            documents.reserveCapacity(stored.documents.count)
            for (id, hex) in stored.documents {
                if let value = UInt64(hex, radix: 16) { documents[id] = value }
            }
            return SpotlightIndexGate(documents: documents, baselineEmpty: stored.baselineEmpty)
        }
    }

    public func save(_ gate: SpotlightIndexGate) {
        lock.withLock {
            let stored = Stored(
                version: SpotlightIndexGate.mappingVersion,
                baselineEmpty: gate.baselineEmpty,
                documents: gate.documents.mapValues { String($0, radix: 16) })
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
