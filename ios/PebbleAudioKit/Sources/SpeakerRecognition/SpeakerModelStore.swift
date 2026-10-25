import CryptoKit
import Foundation
import Transcription

public enum SpeakerModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case installing
    case installed
    case failed(message: String)
}

/// Installs only public models on explicit request; never receives or uploads audio/voiceprints.
/// The embedding archive and every installed model file are verified before the installation is published.
public actor SpeakerModelStore {
    public static let downloadBytes: Int64 = 18_343_754
    public nonisolated let root: URL
    public nonisolated var embeddingDirectory: URL { root.appendingPathComponent("embedding", isDirectory: true) }
    public nonisolated var segmentationDirectory: URL { root.appendingPathComponent("Segmentation.mlmodelc", isDirectory: true) }
    private let downloader: any ParakeetArchiveDownloading
    private let extractor: any ParakeetArchiveExtracting
    private var current: SpeakerModelInstallState = .notInstalled
    private var attempt: Task<Void, Error>?
    private var attemptID: UUID?
    private var progressObservers: [UUID: @Sendable (Double) -> Void] = [:]
    private var verifiedInstallation = false

    public init(root: URL = SpeakerModelStore.defaultRoot,
                downloader: any ParakeetArchiveDownloading = URLSessionArchiveDownloader(),
                extractor: any ParakeetArchiveExtracting = ZipArchiveExtractor()) {
        self.root = root; self.downloader = downloader; self.extractor = extractor
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speaker-models", isDirectory: true)
    }
    public func state() -> SpeakerModelInstallState { current }

    public func isInstalled() -> Bool {
        if verifiedInstallation,
           FileManager.default.fileExists(atPath: embeddingDirectory.appendingPathComponent("config.txt").path),
           FileManager.default.fileExists(atPath: segmentationDirectory.appendingPathComponent("model.mil").path) {
            return true
        }
        verifiedInstallation = false
        do {
            try CactusSpeakerModel(directory: embeddingDirectory).verify()
            try CoreMLSegmentationModel(directory: segmentationDirectory).verify()
            if attempt == nil { current = .installed }
            verifiedInstallation = true
            return true
        } catch {
            if attempt == nil, case .installed = current { current = .notInstalled }
            return false
        }
    }

    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let observerID = UUID()
        progressObservers[observerID] = progress
        defer { progressObservers.removeValue(forKey: observerID) }
        if case .downloading(let bytes, let total) = current { progress(Double(bytes) / Double(total)) }
        if let attempt { return try await attempt.value }
        if isInstalled() { progress(1); return }
        let id = UUID()
        attemptID = id
        let job = Task { try await self.performInstall(id: id) }
        attempt = job
        do {
            try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            if attemptID == id {
                attempt = nil; attemptID = nil; current = .installed
                verifiedInstallation = true
                for observer in progressObservers.values { observer(1) }
            }
        } catch {
            if attemptID == id {
                attempt = nil; attemptID = nil
                current = error is CancellationError ? .notInstalled : .failed(message: "The voice models couldn't be installed. Try again.")
            }
            throw error
        }
    }

    public func cancel() async {
        attempt?.cancel()
        if let attempt { _ = try? await attempt.value }
    }

    /// The runtime must disable/release its analyzer before removing installed models.
    public func uninstall() async throws {
        await cancel()
        verifiedInstallation = false
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        current = .notInstalled
    }

    private func performInstall(id: UUID) async throws {
        let manager = FileManager.default
        let staging = root.deletingLastPathComponent().appendingPathComponent(".speaker-models-\(id.uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var stagingURL = staging
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try stagingURL.setResourceValues(resources)
        defer { try? manager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("embedding.zip")
        current = .downloading(receivedBytes: 0, totalBytes: Self.downloadBytes)
        try await downloader.download(from: CactusSpeakerModel.archiveURL, to: archive) { received, _ in
            Task { await self.progress(id: id, received: min(max(received, 0), 12_336_866)) }
        }
        try Task.checkCancellation()
        let archiveData = try Data(contentsOf: archive)
        guard archiveData.count == 12_336_866,
              SHA256.hash(data: archiveData).map({ String(format: "%02x", $0) }).joined()
                == CactusSpeakerModel.recipe.weightsSHA256 else {
            throw SpeakerRecognitionError.modelVerificationFailed("Downloaded model checksum mismatch")
        }
        current = .installing
        let embedding = staging.appendingPathComponent("embedding", isDirectory: true)
        try extractor.extract(archiveAt: archive, into: embedding)
        try CactusSpeakerModel(directory: embedding).verify()
        try manager.removeItem(at: archive)
        let segmentation = staging.appendingPathComponent("Segmentation.mlmodelc", isDirectory: true)
        var completed: Int64 = 12_336_866
        for file in CoreMLSegmentationModel.files {
            try Task.checkCancellation()
            let destination = segmentation.appendingPathComponent(file.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = completed
            current = .downloading(receivedBytes: completed, totalBytes: Self.downloadBytes)
            try await downloader.download(from: file.url, to: destination) { received, _ in
                Task { await self.progress(id: id, received: before + min(max(received, 0), file.bytes)) }
            }
            completed += file.bytes
        }
        current = .installing
        try CoreMLSegmentationModel(directory: segmentation).verify()
        try Task.checkCancellation()
        // Stage the whole pair; no caller can observe one model from an incomplete install.
        let old = root.deletingLastPathComponent().appendingPathComponent(".speaker-models-old-\(id.uuidString)")
        let existed = manager.fileExists(atPath: root.path)
        if existed { try manager.moveItem(at: root, to: old) }
        do { try manager.moveItem(at: staging, to: root) }
        catch {
            if existed { try? manager.moveItem(at: old, to: root) }
            throw error
        }
        if existed { try? manager.removeItem(at: old) }
        var installedURL = root
        try installedURL.setResourceValues(resources)
    }

    private func progress(id: UUID, received: Int64) {
        guard attemptID == id, case .downloading(let previous, _) = current,
              received >= previous else { return }
        current = .downloading(receivedBytes: received, totalBytes: Self.downloadBytes)
        for observer in progressObservers.values { observer(Double(received) / Double(Self.downloadBytes)) }
    }
}
