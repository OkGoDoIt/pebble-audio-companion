import Foundation
import SegmentStore

// The iCloud Drive cold tier (2026-10-13, Roger: "I don't want to lose recordings or other data
// once we hit the cap … back up to iCloud and clear some of the older data locally. Something
// automatic would be ideal.").
//
// WHAT IT DOES. Audio that is old enough and fully transcribed leaves the phone for the app's
// iCloud Drive container: the frame log is moved there (one rename on the same volume), the
// system's upload daemon carries it up — with no help from this process — and once the upload
// is confirmed the local copy is evicted, which is what frees the space. The sidecar, the
// transcript, the conversation and everything derived stay on the phone untouched, so History,
// Ask, search and every status line read exactly as before. Playing the audio fetches the copy
// back down (`fetch`), and a fetched copy is evicted again once it has sat unused.
//
// NOTHING IS DELETED by this tier, ever. The age cap ("Keep audio") still deletes, from iCloud
// too, and says so; this tier only moves.
//
// WHY THE SIDECAR MARK COMES FIRST. `SegmentMeta.coldStorage` is written before the file moves.
// A crash between the two then leaves a MARKED segment with its local log still present, which
// the next sweep simply finishes moving — rather than a moved log with no mark, which recovery
// would read as a sidecar whose audio was lost, and the Storage screen would count as gone.
//
// HONESTY. The Storage screen shows what is in iCloud, what is uploading and what would move;
// a conversation whose audio is in iCloud says so and offers to fetch it; a container that
// cannot be reached (no account, iCloud Drive off) is a named state, never "no audio".

/// The user's rule: on or off, and how old audio must be before it moves.
public struct ColdStoragePolicy: Equatable, Sendable {
    public var enabled: Bool
    public var minAgeMs: Int64

    public init(enabled: Bool, minAgeMs: Int64) {
        self.enabled = enabled
        self.minAgeMs = minAgeMs
    }
}

/// What the system says about one file in the container.
public struct UbiquitousFileStatus: Equatable, Sendable {
    /// The item exists in the container (whether or not its bytes are on this device).
    public var exists: Bool
    public var isUploaded: Bool
    public var isUploading: Bool
    /// The bytes are on this device and readable.
    public var isDownloaded: Bool
    public var isDownloading: Bool
    public var uploadError: String?
    public var downloadError: String?

    public init(
        exists: Bool, isUploaded: Bool = false, isUploading: Bool = false,
        isDownloaded: Bool = false, isDownloading: Bool = false,
        uploadError: String? = nil, downloadError: String? = nil
    ) {
        self.exists = exists
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.uploadError = uploadError
        self.downloadError = downloadError
    }

    public static let missing = UbiquitousFileStatus(exists: false)
}

/// The iCloud Drive file operations the tier needs, as a seam: `FileManagerUbiquity` in the
/// app, a fake in tests. Every call may touch the disk; none touches the network itself.
public protocol UbiquityFiles: Sendable {
    /// False when no iCloud account is signed in on this phone.
    var hasAccount: Bool { get }
    /// The app's container, or nil while iCloud Drive is unavailable to it. Can take a moment
    /// the first time; never called on the main thread.
    func containerURL() -> URL?
    /// Moves a local file into the container. Not a copy: the local path is gone afterwards.
    func moveIntoCloud(from local: URL, to cloud: URL) throws
    /// Moves a (downloaded) container file back to a local path.
    func moveOutOfCloud(from cloud: URL, to local: URL) throws
    func status(of url: URL) -> UbiquitousFileStatus
    /// Removes the local bytes of an uploaded item; the item stays in iCloud.
    func evict(_ url: URL) throws
    func startDownload(_ url: URL) throws
    /// Deletes the item from iCloud.
    func remove(_ url: URL) throws
    func contents(of directory: URL) -> [URL]
    func createDirectory(_ url: URL) throws
}

/// Resolves where a segment's cold copy is. Shared by the store (which reads through it) and
/// the tier (which moves through it); the container URL is cached once found.
public final class ColdAudioLocator: ColdAudioLocating, @unchecked Sendable {
    public static let folder = "cold"

    private let files: any UbiquityFiles
    private let nowMs: @Sendable () -> Int64
    private let lock = NSLock()
    private var container: URL?
    private var lastMissAtMs: Int64?
    /// How long a "no container" answer is remembered before asking the system again.
    public static let missTtlMs: Int64 = 60_000

    public init(files: any UbiquityFiles, nowMs: @escaping @Sendable () -> Int64) {
        self.files = files
        self.nowMs = nowMs
    }

    /// The container root, or nil while iCloud Drive is unavailable.
    public func containerURL() -> URL? {
        let cached: URL?? = lock.withLock {
            if let container { return .some(container) }
            if let lastMissAtMs, nowMs() - lastMissAtMs < Self.missTtlMs { return .some(nil) }
            return nil
        }
        if let cached { return cached }
        let resolved = files.hasAccount ? files.containerURL() : nil
        lock.withLock {
            container = resolved
            lastMissAtMs = resolved == nil ? nowMs() : nil
        }
        return resolved
    }

    public var isAvailable: Bool { containerURL() != nil }

    public func coldDirectory() -> URL? {
        containerURL()?.appendingPathComponent(Self.folder, isDirectory: true)
    }

    public func coldLogURL(segmentId: String) -> URL? {
        coldDirectory()?.appendingPathComponent(segmentId + SegmentStore.logSuffix, isDirectory: false)
    }

    public func isLocallyAvailable(_ url: URL) -> Bool { files.status(of: url).isDownloaded }

    public func removeColdCopy(at url: URL) throws { try files.remove(url) }

    /// Forgets a cached container so the next question asks the system again (an account that
    /// was just signed in).
    public func invalidate() {
        lock.withLock {
            container = nil
            lastMissAtMs = nil
        }
    }
}

/// Where a conversation's audio is, for the screen that wants to play it.
public enum AudioAvailability: Equatable, Sendable {
    /// Every piece is readable right now (on the phone, or fetched).
    case onPhone
    /// At least one piece is in iCloud and not downloaded; it can be fetched.
    case inCloud
    /// At least one piece is in iCloud and the container cannot be reached from this phone.
    case inCloudUnreachable
}

public actor ColdAudioTier {
    /// What the tier holds and is doing, for Diagnostics and the Storage screen.
    public struct Summary: Equatable, Sendable {
        /// iCloud Drive is reachable for this app right now.
        public var available: Bool
        /// Audio whose bytes are on the phone: never moved, or moved and still uploading.
        public var onPhoneBytes: Int64 = 0
        public var onPhoneCount: Int = 0
        /// Audio evicted to iCloud.
        public var inCloudBytes: Int64 = 0
        public var inCloudCount: Int = 0
        /// Moved, still uploading (bytes on the phone AND counted in `onPhoneBytes`).
        public var uploadingBytes: Int64 = 0
        public var uploadingCount: Int = 0
        /// Restore in progress: done of total.
        public var restoring: Restore?
        /// The last thing that went wrong, until the next sweep that goes right.
        public var lastError: String?

        public struct Restore: Equatable, Sendable {
            public var done: Int
            public var total: Int
            public init(done: Int, total: Int) {
                self.done = done
                self.total = total
            }
        }

        public init(available: Bool) { self.available = available }
    }

    /// Moves per sweep: each is one rename, but the upload daemon starts on each at once, and
    /// a first sweep over months of audio should not hand it a thousand files in one go.
    public static let movesPerSweep = 25
    public static let restoresPerSweep = 10
    /// The ordinary cadence; sooner while uploads or a restore are pending.
    public static let sweepIntervalMs: Int64 = 10 * 60_000
    public static let pendingIntervalMs: Int64 = 60_000
    /// A copy fetched for playback is evicted again after sitting unused for this long.
    public static let refetchKeepMs: Int64 = 6 * 60 * 60_000
    /// How long `fetch` waits for the bytes before giving up.
    public static let fetchTimeoutMs: Int64 = 180_000
    public static let fetchPollMs: Int64 = 500

    private let store: SegmentStore
    private let files: any UbiquityFiles
    private let locator: ColdAudioLocator
    private let policy: @Sendable () -> ColdStoragePolicy
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let log: RuntimeLog

    private var lastSweepAtMs: Int64?
    private var lastSweptPolicy: ColdStoragePolicy?
    private var lastError: String?
    private var pendingAfterLastSweep = false
    /// When each evicted copy was last fetched (or first seen downloaded), for the re-evict.
    private var fetchedAtMs: [String: Int64] = [:]
    private var restore: Summary.Restore?
    private var restoreQueue: [String] = []
    /// The last availability the log was told about, so it is said on change and not per sweep.
    private var availabilityLogged: Bool?

    public init(
        store: SegmentStore,
        files: any UbiquityFiles,
        locator: ColdAudioLocator,
        policy: @escaping @Sendable () -> ColdStoragePolicy,
        nowMs: @escaping @Sendable () -> Int64,
        sleep: @escaping @Sendable (Int64) async throws -> Void = { ms in
            try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
        },
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.files = files
        self.locator = locator
        self.policy = policy
        self.nowMs = nowMs
        self.sleep = sleep
        self.log = log
    }

    public nonisolated var audioLocator: ColdAudioLocator { locator }

    // MARK: Reading

    /// Whether a closed, transcribed segment is old enough to move under `minAgeMs` at `now`.
    public static func isEligible(_ meta: SegmentMeta, minAgeMs: Int64, now: Int64) -> Bool {
        !meta.isOpen && meta.isFullyTranscribed && meta.frameCount > 0 && meta.logBytes > 0
            && meta.coldStorage == nil && now - meta.startWallMs >= minAgeMs
    }

    /// What would move under a rule — the Storage screen's preview as the person moves the
    /// picker. Pure over the index; no file is touched.
    public func eligible(minAgeMs: Int64) async -> (bytes: Int64, count: Int) {
        let now = nowMs()
        var bytes: Int64 = 0
        var count = 0
        for meta in await store.listSegments() where Self.isEligible(meta, minAgeMs: minAgeMs, now: now) {
            bytes += meta.logBytes
            count += 1
        }
        return (bytes, count)
    }

    public func summary() async -> Summary {
        var summary = Summary(available: locator.isAvailable)
        for meta in await store.listSegments() where !meta.isOpen {
            if let cold = meta.coldStorage {
                if cold.isEvicted {
                    summary.inCloudBytes += cold.bytes
                    summary.inCloudCount += 1
                } else {
                    summary.uploadingBytes += cold.bytes
                    summary.uploadingCount += 1
                    summary.onPhoneBytes += cold.bytes
                    summary.onPhoneCount += 1
                }
            } else {
                summary.onPhoneBytes += meta.logBytes
                summary.onPhoneCount += 1
            }
        }
        summary.restoring = restore
        summary.lastError = lastError
        return summary
    }

    /// Where a conversation's audio is: every piece readable, or some of it in iCloud.
    public func availability(segmentIds: [String]) async -> AudioAvailability {
        var inCloud = false
        for id in segmentIds {
            guard let meta = await store.readMeta(id), meta.coldStorage != nil else { continue }
            if await store.localLogExists(id) { continue }
            guard let url = locator.coldLogURL(segmentId: id) else { return .inCloudUnreachable }
            if !files.status(of: url).isDownloaded { inCloud = true }
        }
        return inCloud ? .inCloud : .onPhone
    }

    // MARK: Pacing

    public var isDue: Bool {
        let policy = policy()
        if lastSweptPolicy != policy { return true }
        if restore != nil { return true }
        guard let lastSweepAtMs else { return true }
        let interval = pendingAfterLastSweep ? Self.pendingIntervalMs : Self.sweepIntervalMs
        return nowMs() - lastSweepAtMs >= interval
    }

    /// The pipeline stage. True when it moved, evicted or restored something.
    @discardableResult
    public func sweepIfDue() async -> Bool {
        guard isDue else { return false }
        return await sweep()
    }

    // MARK: The sweep

    /// One pass: finish interrupted moves, evict confirmed uploads, re-evict stale fetches,
    /// advance a restore, move newly eligible audio, drop orphans. Bounded per call.
    @discardableResult
    public func sweep() async -> Bool {
        let policy = policy()
        lastSweepAtMs = nowMs()
        lastSweptPolicy = policy
        guard locator.isAvailable, let coldDir = locator.coldDirectory() else {
            // Nothing can move either way. Not an error: a named state the screens show —
            // and said once in the log, so a support report answers "did iCloud ever work?".
            if availabilityLogged != false {
                availabilityLogged = false
                log.write("cold storage: iCloud Drive is not available to this app (no account, or iCloud Drive off)")
            }
            pendingAfterLastSweep = false
            return false
        }
        if availabilityLogged != true {
            availabilityLogged = true
            log.write("cold storage: iCloud Drive container available at \(coldDir.path)")
        }
        do { try files.createDirectory(coldDir) } catch {
            lastError = "\(error)"
            return false
        }
        var changed = false
        var pending = false
        var sweepError: String?
        let now = nowMs()
        let metas = await store.listSegments()
        var known = Set<String>()

        for meta in metas where !meta.isOpen {
            known.insert(meta.segmentId)
            guard let cold = meta.coldStorage,
                let url = locator.coldLogURL(segmentId: meta.segmentId)
            else { continue }
            let id = meta.segmentId
            // Restores first: a segment on the restore list is coming home, whatever its state.
            if restore != nil, let index = restoreQueue.firstIndex(of: id) {
                switch await restoreOne(id, url: url) {
                case .done:
                    restoreQueue.remove(at: index)
                    restore?.done += 1
                    changed = true
                case .waiting: pending = true
                case .failed(let reason): sweepError = reason
                }
                continue
            }
            // An interrupted move: marked, file still local. Finish it.
            if await store.localLogExists(id) {
                do {
                    try files.moveIntoCloud(from: store.localLogURL(id), to: url)
                    changed = true
                    pending = true
                } catch {
                    sweepError = "move \(id): \(error)"
                }
                continue
            }
            let status = files.status(of: url)
            if !status.exists {
                // Neither here nor there. The audio is gone and the record of it stays: the
                // sidecar keeps its frames, so the timeline shows recorded time with no audio
                // to play rather than a hole.
                sweepError = "\(id): the iCloud copy is missing"
                continue
            }
            if !cold.isEvicted {
                if let error = status.uploadError {
                    sweepError = "upload \(id): \(error)"
                    pending = true
                } else if status.isUploaded, !status.isUploading {
                    do {
                        try files.evict(url)
                        var evicted = cold
                        evicted.state = ColdStorageMeta.stateEvicted
                        try await store.setColdStorage(id, evicted)
                        changed = true
                    } catch {
                        sweepError = "evict \(id): \(error)"
                        pending = true
                    }
                } else {
                    pending = true
                }
            } else if status.isDownloaded {
                // A fetched copy. Keep it for a while (it was fetched to be played), then let
                // it go again.
                let since = fetchedAtMs[id] ?? now
                fetchedAtMs[id] = since
                if now - since >= Self.refetchKeepMs {
                    do {
                        try files.evict(url)
                        fetchedAtMs[id] = nil
                        changed = true
                    } catch {
                        sweepError = "re-evict \(id): \(error)"
                    }
                } else {
                    pending = true
                }
            }
        }

        if let restore, restore.done >= restore.total || restoreQueue.isEmpty {
            log.write("cold storage: restore finished, \(restore.done) recording(s) back on the phone")
            self.restore = nil
            restoreQueue = []
        }

        // New moves, oldest first, when the rule is on and nothing is being brought back.
        if policy.enabled, restore == nil {
            let candidates = metas
                .filter { Self.isEligible($0, minAgeMs: policy.minAgeMs, now: now) }
                .sorted { $0.startWallMs < $1.startWallMs }
                .prefix(Self.movesPerSweep)
            var moved = 0
            var movedBytes: Int64 = 0
            for meta in candidates {
                let id = meta.segmentId
                guard await store.localLogExists(id), let url = locator.coldLogURL(segmentId: id)
                else { continue }
                let mark = ColdStorageMeta(movedAtMs: now, bytes: meta.logBytes)
                do {
                    try await store.setColdStorage(id, mark)
                } catch {
                    sweepError = "mark \(id): \(error)"
                    continue
                }
                do {
                    try files.moveIntoCloud(from: store.localLogURL(id), to: url)
                    moved += 1
                    movedBytes += meta.logBytes
                } catch {
                    // Un-mark: the audio is where it was, and the next sweep may try again.
                    try? await store.setColdStorage(id, nil)
                    sweepError = "move \(id): \(error)"
                }
            }
            if moved > 0 {
                changed = true
                pending = true
                log.write(
                    "cold storage: moved \(moved) recording(s), \(movedBytes / 1_048_576) MB, to iCloud"
                        + " (uploading)")
            }
            // The budget was filled: there is very likely more, so come straight back.
            if candidates.count >= Self.movesPerSweep { lastSweepAtMs = nil }
        }

        // Orphans: a cold file whose segment is gone (deleted while the container was
        // unreachable, or a crash between the two halves of a delete).
        if !metas.isEmpty {
            for file in files.contents(of: coldDir)
            where file.lastPathComponent.hasSuffix(SegmentStore.logSuffix) {
                let id = String(file.lastPathComponent.dropLast(SegmentStore.logSuffix.count))
                guard !known.contains(id) else { continue }
                do {
                    try files.remove(file)
                    log.write("cold storage: removed the orphaned iCloud copy of \(id)")
                } catch {
                    sweepError = "orphan \(id): \(error)"
                }
            }
        }

        pendingAfterLastSweep = pending
        lastError = sweepError
        if let sweepError { log.write("cold storage: \(sweepError)") }
        return changed
    }

    private enum RestoreStep { case done, waiting, failed(String) }

    private func restoreOne(_ id: String, url: URL) async -> RestoreStep {
        if await store.localLogExists(id) {
            // Marked but never moved, or already back: just clear the mark.
            do {
                try await store.setColdStorage(id, nil)
                return .done
            } catch { return .failed("restore \(id): \(error)") }
        }
        let status = files.status(of: url)
        guard status.exists else { return .failed("restore \(id): the iCloud copy is missing") }
        if !status.isDownloaded {
            if let error = status.downloadError { return .failed("download \(id): \(error)") }
            if !status.isDownloading {
                do { try files.startDownload(url) } catch { return .failed("download \(id): \(error)") }
            }
            return .waiting
        }
        do {
            try files.moveOutOfCloud(from: url, to: store.localLogURL(id))
            try await store.setColdStorage(id, nil)
            fetchedAtMs[id] = nil
            return .done
        } catch {
            return .failed("restore \(id): \(error)")
        }
    }

    // MARK: Fetching for playback

    public enum FetchError: Error, Equatable {
        case unreachable
        case missing(segmentId: String)
        case timedOut(segmentId: String)
        case failed(segmentId: String, reason: String)
    }

    /// Brings the bytes of these segments' audio back to the phone (the copies stay in iCloud)
    /// and returns when they are readable. Segments whose audio is on the phone already return
    /// at once.
    public func fetch(segmentIds: [String]) async throws {
        for id in segmentIds {
            guard let meta = await store.readMeta(id), meta.coldStorage != nil else { continue }
            if await store.localLogExists(id) { continue }
            guard let url = locator.coldLogURL(segmentId: id) else { throw FetchError.unreachable }
            var status = files.status(of: url)
            guard status.exists else { throw FetchError.missing(segmentId: id) }
            if !status.isDownloaded, !status.isDownloading {
                do { try files.startDownload(url) } catch {
                    throw FetchError.failed(segmentId: id, reason: "\(error)")
                }
            }
            let deadline = nowMs() + Self.fetchTimeoutMs
            while !status.isDownloaded {
                if let error = status.downloadError {
                    throw FetchError.failed(segmentId: id, reason: error)
                }
                if nowMs() >= deadline { throw FetchError.timedOut(segmentId: id) }
                try await sleep(Self.fetchPollMs)
                status = files.status(of: url)
            }
            fetchedAtMs[id] = nowMs()
        }
    }

    // MARK: Restore

    /// Starts bringing every evicted recording back to the phone. Advances a few per sweep,
    /// oldest last, so the most recent audio is home first.
    public func beginRestoreAll() async {
        let ids = await store.listSegments()
            .filter { $0.coldStorage != nil }
            .sorted { $0.startWallMs > $1.startWallMs }
            .map(\.segmentId)
        guard !ids.isEmpty else { return }
        restoreQueue = ids
        restore = Summary.Restore(done: 0, total: ids.count)
        lastSweepAtMs = nil
        log.write("cold storage: bringing \(ids.count) recording(s) back from iCloud")
    }

    public func cancelRestore() {
        restore = nil
        restoreQueue = []
    }

    public var isRestoring: Bool { restore != nil }
}

/// The real thing: `FileManager`'s ubiquity API.
public final class FileManagerUbiquity: UbiquityFiles {
    private let containerIdentifier: String?

    /// `nil` picks the first container in the app's entitlements.
    public init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
    }

    public var hasAccount: Bool { FileManager.default.ubiquityIdentityToken != nil }

    public func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    public func moveIntoCloud(from local: URL, to cloud: URL) throws {
        try FileManager.default.setUbiquitous(true, itemAt: local, destinationURL: cloud)
    }

    public func moveOutOfCloud(from cloud: URL, to local: URL) throws {
        try FileManager.default.setUbiquitous(false, itemAt: cloud, destinationURL: local)
    }

    public func status(of url: URL) -> UbiquitousFileStatus {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .missing }
        let downloading = values.ubiquitousItemDownloadingStatus
        return UbiquitousFileStatus(
            exists: true,
            isUploaded: values.ubiquitousItemIsUploaded ?? false,
            isUploading: values.ubiquitousItemIsUploading ?? false,
            isDownloaded: downloading == .current || downloading == .downloaded,
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            uploadError: values.ubiquitousItemUploadingError.map { "\($0.localizedDescription)" },
            downloadError: values.ubiquitousItemDownloadingError.map { "\($0.localizedDescription)" }
        )
    }

    public func evict(_ url: URL) throws { try FileManager.default.evictUbiquitousItem(at: url) }

    public func startDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    public func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
