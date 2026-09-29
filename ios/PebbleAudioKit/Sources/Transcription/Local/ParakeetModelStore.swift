import Foundation

// Port of `app/src/iosMain/.../IosCactusModelPathProvider.kt`: download → extract → record the
// revision, under `Caches/models/{installDirectoryName}`.
//
// The install contract, carried across unchanged:
//   • URL is `https://huggingface.co/{repository}/resolve/{revision}/{archivePath}`.
//   • The archive streams to a FILE, never through memory (an in-memory version blew up on the
//     ~700 MB archive and reported no progress).
//   • "Installed" means the runtime's marker file exists (`config.txt` for Cactus,
//     `metadata.json` for Core AI) AND the version file (`.cactus_version` / `.coreai_version`)
//     records THIS spec's revision.
//   • Cancellation and failure leave no partial install behind.
//   • Downloading is always an explicit user action — transcription never triggers one.
//
// Two additions for the Core AI runtime (iOS 27):
//   • An archive can also arrive through Files: `refresh()` looks for
//     `Documents/models-inbox/<id>.zip`, installs it through the same extractor, and consumes
//     the zip. An archive that wraps the bundle in one top-level folder is hoisted.
//   • A Core AI model is `.preparing` (busy) between extraction and the one-time foreground
//     specialization pass; only after that pass writes `.prepared` is it `.installed`. The pass
//     is never started while the app is in the background.

/// Install state of one downloadable model — what the Settings row renders.
public enum ParakeetInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    /// Archive downloaded; unpacking (no meaningful byte progress).
    case installing
    /// Unpacked; the runtime's one-time prepare pass (Core AI specialization) has not completed.
    /// Busy while the pass runs, and reported the same way while it waits for the foreground.
    case preparing
    case installed
    case failed(message: String)

    public var isInstalled: Bool { self == .installed }

    /// A download, extraction or prepare pass is in flight, so the row shows progress and a
    /// Cancel action.
    public var isBusy: Bool {
        switch self {
        case .downloading, .installing, .preparing: return true
        case .notInstalled, .installed, .failed: return false
        }
    }

    /// 0…1 while downloading, nil when there is nothing to show a bar for.
    public var fractionCompleted: Double? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return min(max(Double(received) / Double(total), 0), 1)
    }
}

/// One catalog row for the Settings picker: everything it needs to draw and act on a model.
public struct ParakeetModelEntry: Sendable, Equatable, Identifiable {
    public let spec: ParakeetModelSpec
    public let state: ParakeetInstallState

    public init(spec: ParakeetModelSpec, state: ParakeetInstallState) {
        self.spec = spec
        self.state = state
    }

    public var id: String { spec.id }
    public var displayName: String { spec.displayName }
    public var shortLabel: String { spec.shortLabel }
    public var modelDescription: String { spec.modelDescription }
    public var downloadBytes: Int64 { spec.downloadBytes }
    public var recommended: Bool { spec.recommended }
}

/// What the Settings picker talks to (mockable, like `LocalModelManaging` for Apple Speech).
public protocol ParakeetModelStoring: Sendable {
    /// Every catalog model with its current install state, catalog order.
    func entries() async -> [ParakeetModelEntry]
    func state(of modelId: String) async -> ParakeetInstallState
    /// Re-reads disk (e.g. on screen appear) and returns the refreshed rows.
    func refresh() async -> [ParakeetModelEntry]
    /// Starts (or joins) the download+install and returns the terminal state of the attempt.
    @discardableResult func install(_ modelId: String) async -> ParakeetInstallState
    func cancel(_ modelId: String) async
    @discardableResult func uninstall(_ modelId: String) async -> ParakeetInstallState
    /// Live row updates (buffered; safe to subscribe before acting).
    func states() async -> AsyncStream<[ParakeetModelEntry]>
}

/// Resolves an installed model to its directory — the read-only half of the store, so the
/// transcription provider can check availability without being able to start a download.
public protocol ParakeetModelLocating: Sendable {
    /// The install directory, or nil when this model is not installed. Never downloads.
    func installedModelPath(for spec: ParakeetModelSpec) -> URL?
    /// True when the runtime's one-time prepare pass has completed for an installed model (or
    /// the runtime needs none). A provider must not start that pass in the background.
    func isPrepared(_ spec: ParakeetModelSpec) -> Bool
    /// Records whether the prepare pass's output is still good. The provider withdraws it when
    /// the runtime's compiled cache turns out to be stale (so a background pass stops loading a
    /// model that has to be rebuilt cold) and restores it once a foreground load rebuilt it.
    /// The only write this read-mostly seam allows: it never touches the model files.
    func setPrepared(_ spec: ParakeetModelSpec, _ prepared: Bool)
}

extension ParakeetModelLocating {
    /// Runtimes without a prepare step are always prepared; fakes inherit this.
    public func isPrepared(_ spec: ParakeetModelSpec) -> Bool { true }
    public func setPrepared(_ spec: ParakeetModelSpec, _ prepared: Bool) {}
}

/// Disk layout of the model cache (`Caches/models/{installDirectoryName}`).
public struct ParakeetModelLocation: ParakeetModelLocating, Sendable {
    /// The Cactus version file — see `ParakeetModelSpec.versionFileName` for the per-runtime rule.
    public static let versionFileName = ".cactus_version"
    /// The file Cactus itself needs — see `ParakeetModelSpec.installMarkerFileName`.
    public static let configFileName = "config.txt"

    public let modelsDirectory: URL

    public init(modelsDirectory: URL = ParakeetModelLocation.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public static var defaultModelsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("models", isDirectory: true)
    }

    public func directory(for spec: ParakeetModelSpec) -> URL {
        modelsDirectory.appendingPathComponent(spec.installDirectoryName, isDirectory: true)
    }

    /// Installed = the model unpacked (the runtime's marker file) AND the recorded revision
    /// matches the spec. A revision bump therefore reads as "not installed" and re-downloads.
    public func isInstalled(_ spec: ParakeetModelSpec) -> Bool {
        let root = directory(for: spec)
        let manager = FileManager.default
        guard
            manager.fileExists(
                atPath: root.appendingPathComponent(spec.installMarkerFileName).path
            )
        else { return false }
        return recordedVersion(for: spec) == spec.revision
    }

    public func recordedVersion(for spec: ParakeetModelSpec) -> String? {
        let url = directory(for: spec).appendingPathComponent(spec.versionFileName)
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func installedModelPath(for spec: ParakeetModelSpec) -> URL? {
        isInstalled(spec) ? directory(for: spec) : nil
    }

    /// The `.prepared` marker, present once the prepare pass ran for this install. Written last
    /// by the store, after the version file, so it can never outrun the files it vouches for.
    public func isPrepared(_ spec: ParakeetModelSpec) -> Bool {
        guard spec.requiresPreparation else { return true }
        return FileManager.default.fileExists(
            atPath: directory(for: spec).appendingPathComponent(spec.preparedMarkerFileName).path
        )
    }

    /// Writes or removes the `.prepared` marker — only for an installed model that has a prepare
    /// step, so it can never make a half-extracted directory look ready.
    public func setPrepared(_ spec: ParakeetModelSpec, _ prepared: Bool) {
        guard spec.requiresPreparation, isInstalled(spec) else { return }
        let marker = directory(for: spec).appendingPathComponent(spec.preparedMarkerFileName)
        if prepared {
            try? Data("prepared".utf8).write(to: marker, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}

/// Streams one archive to a file, reporting byte progress. A seam so the store's state machine
/// is testable without a network (or a 700 MB transfer).
public protocol ParakeetArchiveDownloading: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws
}

public actor ParakeetModelStore: ParakeetModelStoring, ParakeetModelLocating {
    /// The one store over the one on-disk model cache. Settings must use this rather than
    /// constructing its own: a download started on the picker keeps reporting progress after
    /// the user navigates away and comes back.
    public static let shared = ParakeetModelStore()

    private let location: ParakeetModelLocation
    private let downloader: any ParakeetArchiveDownloading
    private let extractor: any ParakeetArchiveExtracting
    private let temporaryDirectory: URL
    private let inboxDirectory: URL?
    private let preparer: @Sendable (LocalEngineRuntime) -> any ParakeetModelPreparing
    private let supportedRuntimes: Set<LocalEngineRuntime>
    private var isForeground: @Sendable () -> Bool
    private var log: @Sendable (String) -> Void = { _ in }

    private var stateById: [String: ParakeetInstallState] = [:]
    private var installs: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[ParakeetModelEntry]>.Continuation] = [:]

    /// `Documents/models-inbox`, the folder Files exposes (`UIFileSharingEnabled`) where an
    /// archive can be dropped for `refresh()` to install.
    public static var defaultInboxDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("models-inbox", isDirectory: true)
    }

    /// Runtimes this build can run, from the engine factory. A model of any other runtime is
    /// neither downloaded nor picked up from the inbox.
    public static var runtimesSupportedHere: Set<LocalEngineRuntime> {
        Set(LocalEngineRuntime.allCases.filter { ParakeetEngineFactory.isSupported($0) })
    }

    public init(
        location: ParakeetModelLocation = ParakeetModelLocation(),
        downloader: (any ParakeetArchiveDownloading)? = nil,
        extractor: any ParakeetArchiveExtracting = ZipArchiveExtractor(),
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        inboxDirectory: URL? = ParakeetModelStore.defaultInboxDirectory,
        preparer: (@Sendable (LocalEngineRuntime) -> any ParakeetModelPreparing)? = nil,
        supportedRuntimes: Set<LocalEngineRuntime>? = nil,
        isForeground: @escaping @Sendable () -> Bool = { true }
    ) {
        self.location = location
        self.downloader = downloader ?? URLSessionArchiveDownloader()
        self.extractor = extractor
        self.temporaryDirectory = temporaryDirectory
        self.inboxDirectory = inboxDirectory
        self.preparer = preparer ?? { ParakeetEngineFactory.makePreparer(runtime: $0) }
        self.supportedRuntimes = supportedRuntimes ?? ParakeetModelStore.runtimesSupportedHere
        self.isForeground = isForeground
    }

    /// Where the store's one-line records go (house style: lowercase `key=value`). The app wires
    /// its runtime log in; unset, nothing is recorded.
    public func setLog(_ log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// The foreground signal `refresh()` consults before starting a prepare pass. The app wires
    /// its own probe into the shared store; the initializer's default (`{ true }`) is for
    /// callers that construct their own store and know they are on screen.
    public func setForeground(_ isForeground: @escaping @Sendable () -> Bool) {
        self.isForeground = isForeground
    }

    /// The archive `refresh()` would install for `spec`, when one is waiting in the inbox.
    public nonisolated func inboxArchive(for spec: ParakeetModelSpec) -> URL? {
        guard let inboxDirectory else { return nil }
        let url = inboxDirectory.appendingPathComponent("\(spec.id).zip")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Reading

    public func entries() -> [ParakeetModelEntry] {
        ParakeetModelCatalog.all.map { ParakeetModelEntry(spec: $0, state: resolvedState($0)) }
    }

    public func state(of modelId: String) -> ParakeetInstallState {
        guard let spec = ParakeetModelCatalog.spec(id: modelId) else { return .notInstalled }
        return resolvedState(spec)
    }

    /// Re-reads the disk, and starts the work the disk asks for: an archive waiting in the
    /// inbox is installed; an unpacked Core AI model that was never prepared is prepared — but
    /// only in the foreground, because the specialization pass is seconds of CPU and a burst of
    /// memory that a background wake must not spend.
    public func refresh() -> [ParakeetModelEntry] {
        for spec in ParakeetModelCatalog.all where installs[spec.id] == nil {
            // The state is set here, not by the task: the rows this call returns must already
            // say what has been started.
            if let archive = inboxArchive(for: spec), supportedRuntimes.contains(spec.runtime),
                !location.isInstalled(spec)
            {
                set(spec.id, .installing)
                start(spec) { await self.performInstall(spec, archive: archive) }
                continue
            }
            if location.isInstalled(spec), !location.isPrepared(spec),
                supportedRuntimes.contains(spec.runtime), isForeground()
            {
                if case .failed = stateById[spec.id] { continue }  // wait for an explicit retry
                set(spec.id, .preparing)
                start(spec) { await self.performPrepare(spec) }
                continue
            }
            // Keep a failure message visible until the user retries or the install succeeds.
            if case .failed = stateById[spec.id], !(location.isInstalled(spec) && location.isPrepared(spec)) {
                continue
            }
            stateById[spec.id] = resolvedState(spec)
        }
        publish()
        return entries()
    }

    public nonisolated func installedModelPath(for spec: ParakeetModelSpec) -> URL? {
        location.installedModelPath(for: spec)
    }

    public func states() -> AsyncStream<[ParakeetModelEntry]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[ParakeetModelEntry]>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(entries())
        return stream
    }

    // MARK: - Installing

    @discardableResult
    public func install(_ modelId: String) async -> ParakeetInstallState {
        guard let spec = ParakeetModelCatalog.spec(id: modelId) else { return .notInstalled }
        if let running = installs[spec.id] {
            await running.value
            return resolvedState(spec)
        }
        guard supportedRuntimes.contains(spec.runtime) else {
            // The rows never offer this, but a stale selection can still ask.
            set(spec.id, .failed(message: Self.unsupportedRuntimeMessage))
            return resolvedState(spec)
        }
        if location.isInstalled(spec) {
            if location.isPrepared(spec) {
                set(spec.id, .installed)
                return .installed
            }
            // Unpacked but never prepared (an interrupted or failed pass): prepare only.
            return await run(spec) { await self.performPrepare(spec) }
        }
        if let archive = inboxArchive(for: spec) {
            return await run(spec) { await self.performInstall(spec, archive: archive) }
        }
        guard spec.hasDownloadSource else {
            // Nothing is hosted for this model yet: the only way in is the Files inbox, and a
            // download attempt would end in an HTTP error that says nothing useful.
            set(spec.id, .failed(message: Self.importRequiredMessage(spec)))
            return resolvedState(spec)
        }
        set(spec.id, .downloading(receivedBytes: 0, totalBytes: spec.downloadBytes))
        return await run(spec) { await self.performInstall(spec, archive: nil) }
    }

    /// Runs `work` as the one install task for `spec` and reports the state it ended in.
    private func run(
        _ spec: ParakeetModelSpec, _ work: @escaping @Sendable () async -> Void
    ) async -> ParakeetInstallState {
        start(spec, work)
        await installs[spec.id]?.value
        return resolvedState(spec)
    }

    /// Starts `work` as the install task for `spec` (fire and forget — `refresh()`'s callers
    /// watch `states()`), clearing the slot when it ends.
    private func start(_ spec: ParakeetModelSpec, _ work: @escaping @Sendable () async -> Void) {
        guard installs[spec.id] == nil else { return }
        // Inherits the actor, so the slot is cleared on the actor once the work ends.
        installs[spec.id] = Task {
            await work()
            self.finished(spec.id)
        }
    }

    private func finished(_ modelId: String) {
        installs[modelId] = nil
    }

    public func cancel(_ modelId: String) {
        installs[modelId]?.cancel()
    }

    @discardableResult
    public func uninstall(_ modelId: String) async -> ParakeetInstallState {
        guard let spec = ParakeetModelCatalog.spec(id: modelId) else { return .notInstalled }
        installs[spec.id]?.cancel()
        await installs[spec.id]?.value
        try? FileManager.default.removeItem(at: location.directory(for: spec))
        set(spec.id, .notInstalled)
        return .notInstalled
    }

    /// Download (unless `archive` names one already on disk — the inbox path), extract, record
    /// the revision, then run the runtime's prepare pass.
    private func performInstall(_ spec: ParakeetModelSpec, archive inboxArchive: URL?) async {
        let target = location.directory(for: spec)
        let downloaded = temporaryDirectory.appendingPathComponent("cactus_download_\(spec.id).zip")
        let archive = inboxArchive ?? downloaded
        let manager = FileManager.default
        // The staged download is cleaned up either way; an inbox archive is consumed either
        // way too — a corrupt one must not be retried on every refresh.
        defer { try? manager.removeItem(at: archive) }
        do {
            if inboxArchive == nil {
                try? manager.removeItem(at: archive)
                try manager.createDirectory(
                    at: archive.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let expected = spec.downloadBytes
                try await downloader.download(from: spec.downloadURL, to: archive) {
                    [weak self] received, total in
                    guard let self else { return }
                    // A server that omits Content-Length reports total 0/-1; fall back to the
                    // catalog size so the bar still moves against a sane denominator.
                    let denominator = total > 1024 ? total : expected
                    Task { await self.advanceProgress(spec.id, received: received, total: denominator) }
                }
                try Task.checkCancellation()
            } else {
                log("local model install source=inbox id=\(spec.id)")
            }
            set(spec.id, .installing)
            try? manager.removeItem(at: target)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try extractor.extract(archiveAt: archive, into: target)
            try Task.checkCancellation()
            try Self.hoistSingleWrapperDirectory(in: target, marker: spec.installMarkerFileName)
            guard manager.fileExists(atPath: target.appendingPathComponent(spec.installMarkerFileName).path)
            else { throw ZipExtractionError.corruptArchive("no \(spec.installMarkerFileName) in archive") }
            // Version file LAST: it is what makes the install count as installed, so a partial
            // extraction can never be mistaken for a complete one.
            try Data(spec.revision.utf8).write(
                to: target.appendingPathComponent(spec.versionFileName)
            )
            log("local model installed id=\(spec.id) runtime=\(spec.runtime.rawValue)")
        } catch {
            try? manager.removeItem(at: target)
            // A cancelled install is not a failure: it leaves no message and no partial dir.
            if Self.isCancellation(error) || Task.isCancelled {
                set(spec.id, .notInstalled)
            } else {
                log("local model install failed id=\(spec.id) error=\(error)")
                set(spec.id, .failed(message: Self.message(for: error)))
            }
            return
        }
        guard spec.requiresPreparation else {
            set(spec.id, .installed)
            return
        }
        await performPrepare(spec)
    }

    /// The runtime's one-time pass over an unpacked model (Core AI: load + warm, which writes
    /// the specialization cache), then the `.prepared` marker. A failure keeps the files — the
    /// next attempt is a prepare, not a re-download — except a cancel, which removes them like
    /// any cancelled install.
    private func performPrepare(_ spec: ParakeetModelSpec) async {
        let target = location.directory(for: spec)
        set(spec.id, .preparing)
        do {
            try Task.checkCancellation()
            try await preparer(spec.runtime).prepare(spec: spec, directory: target)
            try Task.checkCancellation()
            try Data("prepared".utf8).write(
                to: target.appendingPathComponent(spec.preparedMarkerFileName)
            )
            log("local model prepared id=\(spec.id)")
            set(spec.id, .installed)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled {
                try? FileManager.default.removeItem(at: target)
                set(spec.id, .notInstalled)
            } else {
                log("local model prepare failed id=\(spec.id) error=\(error)")
                set(spec.id, .failed(message: Self.message(for: error)))
            }
        }
    }

    /// An archive that wraps the bundle in one top-level folder (`zip -r name.zip bundle/`)
    /// extracts to `target/bundle/<marker>`; move that folder's contents up so the model lives
    /// at `target/<marker>` like a flat archive's would. Anything else is left alone.
    static func hoistSingleWrapperDirectory(in target: URL, marker: String) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: target.appendingPathComponent(marker).path) { return }
        let children = try manager.contentsOfDirectory(
            at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        guard children.count == 1, let wrapper = children.first,
            (try? wrapper.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
            manager.fileExists(atPath: wrapper.appendingPathComponent(marker).path)
        else { return }
        for item in try manager.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil) {
            try manager.moveItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
        }
        try manager.removeItem(at: wrapper)
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static let unsupportedRuntimeMessage = "This model needs iOS 27 on an iPhone."

    static func importRequiredMessage(_ spec: ParakeetModelSpec) -> String {
        "No download is published for this model yet. Put \(spec.id).zip in Files › On My "
            + "iPhone › Pebble Audio › models-inbox, then choose the model again."
    }

    static func message(for error: Error) -> String {
        if error is ZipExtractionError {
            return "The download finished but the model couldn't be unpacked. Try again."
        }
        if let engine = error as? ParakeetEngineError {
            switch engine {
            case .unsupportedPlatform:
                return unsupportedRuntimeMessage
            case .insufficientMemory:
                return "Not enough memory to prepare the model right now. Close other apps and try again."
            case .modelLoadFailed, .nativeFailure:
                return "The model couldn't be prepared. Try again."
            }
        }
        return "The download didn't finish. Check your connection and try again."
    }

    // MARK: - State plumbing

    private func resolvedState(_ spec: ParakeetModelSpec) -> ParakeetInstallState {
        if let known = stateById[spec.id], known.isBusy, installs[spec.id] != nil { return known }
        let installed = location.isInstalled(spec)
        if installed, location.isPrepared(spec) { return .installed }
        if let known = stateById[spec.id], case .failed = known { return known }
        // Unpacked, never prepared, nothing running: still not usable, and `refresh()` (in the
        // foreground) is what starts the pass.
        return installed ? .preparing : .notInstalled
    }

    /// Progress arrives on the URLSession delegate queue and reaches the actor through a hop,
    /// so a late callback could otherwise resurrect `.downloading` after the install finished,
    /// or move the bar backwards. Both are dropped here.
    private func advanceProgress(_ modelId: String, received: Int64, total: Int64) {
        guard case .downloading(let current, _) = stateById[modelId], received >= current else {
            return
        }
        set(modelId, .downloading(receivedBytes: received, totalBytes: total))
    }

    private func set(_ modelId: String, _ state: ParakeetInstallState) {
        guard stateById[modelId] != state else { return }
        stateById[modelId] = state
        publish()
    }

    private func publish() {
        let snapshot = entries()
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
