import Foundation

// Port of `app/src/iosMain/.../IosCactusModelPathProvider.kt`: download → extract → record the
// revision, under `Caches/models/{installDirectoryName}`.
//
// The install contract, carried across unchanged:
//   • URL is `https://huggingface.co/{repository}/resolve/{revision}/{archivePath}`.
//   • The archive streams to a FILE, never through memory (an in-memory version blew up on the
//     ~700 MB archive and reported no progress).
//   • "Installed" means `config.txt` exists AND `.cactus_version` records THIS spec's revision.
//   • Cancellation and failure leave no partial install behind.
//   • Downloading is always an explicit user action — transcription never triggers one.

/// Install state of one downloadable model — what the Settings row renders.
public enum ParakeetInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    /// Archive downloaded; unpacking (no meaningful byte progress).
    case installing
    case installed
    case failed(message: String)

    public var isInstalled: Bool { self == .installed }

    /// A download or extraction is in flight, so the row shows progress and a Cancel action.
    public var isBusy: Bool {
        switch self {
        case .downloading, .installing: return true
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
}

/// Disk layout of the model cache (`Caches/models/{installDirectoryName}`).
public struct ParakeetModelLocation: ParakeetModelLocating, Sendable {
    /// Written after a successful extraction; holds the spec revision it was installed from.
    public static let versionFileName = ".cactus_version"
    /// The file Cactus itself needs — its presence is what "extracted successfully" means.
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

    /// Installed = the model unpacked (`config.txt`) AND the recorded revision matches the
    /// spec. A revision bump therefore reads as "not installed" and re-downloads.
    public func isInstalled(_ spec: ParakeetModelSpec) -> Bool {
        let root = directory(for: spec)
        let manager = FileManager.default
        guard
            manager.fileExists(
                atPath: root.appendingPathComponent(Self.configFileName).path
            )
        else { return false }
        return recordedVersion(for: spec) == spec.revision
    }

    public func recordedVersion(for spec: ParakeetModelSpec) -> String? {
        let url = directory(for: spec).appendingPathComponent(Self.versionFileName)
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func installedModelPath(for spec: ParakeetModelSpec) -> URL? {
        isInstalled(spec) ? directory(for: spec) : nil
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
    private let location: ParakeetModelLocation
    private let downloader: any ParakeetArchiveDownloading
    private let extractor: any ParakeetArchiveExtracting
    private let temporaryDirectory: URL

    private var stateById: [String: ParakeetInstallState] = [:]
    private var installs: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[ParakeetModelEntry]>.Continuation] = [:]

    public init(
        location: ParakeetModelLocation = ParakeetModelLocation(),
        downloader: (any ParakeetArchiveDownloading)? = nil,
        extractor: any ParakeetArchiveExtracting = ZipArchiveExtractor(),
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) {
        self.location = location
        self.downloader = downloader ?? URLSessionArchiveDownloader()
        self.extractor = extractor
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - Reading

    public func entries() -> [ParakeetModelEntry] {
        ParakeetModelCatalog.all.map { ParakeetModelEntry(spec: $0, state: resolvedState($0)) }
    }

    public func state(of modelId: String) -> ParakeetInstallState {
        guard let spec = ParakeetModelCatalog.spec(id: modelId) else { return .notInstalled }
        return resolvedState(spec)
    }

    public func refresh() -> [ParakeetModelEntry] {
        for spec in ParakeetModelCatalog.all where !(stateById[spec.id]?.isBusy ?? false) {
            // Keep a failure message visible until the user retries or the install succeeds.
            if case .failed = stateById[spec.id], !location.isInstalled(spec) { continue }
            stateById[spec.id] = location.isInstalled(spec) ? .installed : .notInstalled
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
        if location.isInstalled(spec) {
            set(spec.id, .installed)
            return .installed
        }
        if let running = installs[spec.id] {
            await running.value
            return resolvedState(spec)
        }
        set(spec.id, .downloading(receivedBytes: 0, totalBytes: spec.downloadBytes))
        let task = Task { await self.performInstall(spec) }
        installs[spec.id] = task
        await task.value
        installs[spec.id] = nil
        return resolvedState(spec)
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

    private func performInstall(_ spec: ParakeetModelSpec) async {
        let target = location.directory(for: spec)
        let archive = temporaryDirectory.appendingPathComponent("cactus_download_\(spec.id).zip")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: archive) }
        do {
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
            set(spec.id, .installing)
            try? manager.removeItem(at: target)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try extractor.extract(archiveAt: archive, into: target)
            try Task.checkCancellation()
            // Version file LAST: it is what makes the install count as installed, so a partial
            // extraction can never be mistaken for a complete one.
            try Data(spec.revision.utf8).write(
                to: target.appendingPathComponent(ParakeetModelLocation.versionFileName)
            )
            set(spec.id, .installed)
        } catch {
            try? manager.removeItem(at: target)
            // A cancelled install is not a failure: it leaves no message and no partial dir.
            if Self.isCancellation(error) || Task.isCancelled {
                set(spec.id, .notInstalled)
            } else {
                set(spec.id, .failed(message: Self.message(for: error)))
            }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func message(for error: Error) -> String {
        if error is ZipExtractionError {
            return "The download finished but the model couldn't be unpacked. Try again."
        }
        return "The download didn't finish. Check your connection and try again."
    }

    // MARK: - State plumbing

    private func resolvedState(_ spec: ParakeetModelSpec) -> ParakeetInstallState {
        if let known = stateById[spec.id], known.isBusy { return known }
        if location.isInstalled(spec) { return .installed }
        if let known = stateById[spec.id], case .failed = known { return known }
        return .notInstalled
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
