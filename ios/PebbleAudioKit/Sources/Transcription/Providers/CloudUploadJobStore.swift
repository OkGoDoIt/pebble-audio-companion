import Foundation

// Port of `core/transcription/.../CloudUploadJobStore.kt`.

public enum CloudUploadPhase: String, Codable, Sendable {
    /// The audio body is uploading on the background transport.
    case uploading = "Uploading"

    /// (Soniox) the file is uploaded; the create/poll/fetch control plane still has to run.
    case awaitingControlPlane = "AwaitingControlPlane"
}

public struct CloudUploadJob: Codable, Sendable, Equatable {
    public let jobId: String
    public let provider: CloudProvider
    public var phase: CloudUploadPhase
    /// Pre-assembled request body on disk, deleted when the job leaves the upload transport.
    public let bodyFilePath: String
    /// (Soniox) the uploaded file id, once known.
    public var sonioxFileId: String?
    public let createdAtMs: Int64

    public init(
        jobId: String,
        provider: CloudProvider,
        phase: CloudUploadPhase = .uploading,
        bodyFilePath: String,
        sonioxFileId: String? = nil,
        createdAtMs: Int64
    ) {
        self.jobId = jobId
        self.provider = provider
        self.phase = phase
        self.bodyFilePath = bodyFilePath
        self.sonioxFileId = sonioxFileId
        self.createdAtMs = createdAtMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jobId = try container.decode(String.self, forKey: .jobId)
        self.provider = try container.decode(CloudProvider.self, forKey: .provider)
        self.phase = try container.decodeIfPresent(CloudUploadPhase.self, forKey: .phase) ?? .uploading
        self.bodyFilePath = try container.decode(String.self, forKey: .bodyFilePath)
        self.sonioxFileId = try container.decodeIfPresent(String.self, forKey: .sonioxFileId)
        self.createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
    }
}

/// Durable record of background cloud-upload jobs, one JSON file per job under
/// `<root>/transcription/uploads/`, written atomically so it survives process death. The
/// coordinator uses it to reconcile in-flight uploads after a relaunch and to find the
/// pre-assembled body files to clean up.
public final class CloudUploadJobStore: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let dir: URL

    public init(root: URL) {
        self.dir = root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: true)
    }

    private func jobURL(_ jobId: String) -> URL {
        dir.appendingPathComponent("\(jobId).upload.json")
    }

    public func all() -> [CloudUploadJob] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasSuffix(".upload.json") }
            .compactMap { url -> CloudUploadJob? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CloudUploadJob.self, from: data)
            }
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    public func load(jobId: String) -> CloudUploadJob? {
        guard let data = try? Data(contentsOf: jobURL(jobId)) else { return nil }
        return try? JSONDecoder().decode(CloudUploadJob.self, from: data)
    }

    public func save(_ job: CloudUploadJob) {
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(job) else { return }
        // `.atomic` is temp-file + rename underneath — the same durability the KMP store built
        // by hand with `atomicMove`.
        try? data.write(to: jobURL(job.jobId), options: .atomic)
    }

    public func delete(jobId: String) {
        try? fileManager.removeItem(at: jobURL(jobId))
    }
}
