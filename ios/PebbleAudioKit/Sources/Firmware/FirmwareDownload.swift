import CryptoKit
import Foundation

public enum FirmwareDownloadError: Error, Equatable, Sendable {
    case http(status: Int)
    case network(String)
    /// The bytes that arrived are not the bytes the feed promised. The file is deleted before
    /// this is thrown.
    case checksumMismatch(expected: String, actual: String)
    /// The feed stated a size and the download is a different one. Cheaper than hashing and a
    /// clearer diagnosis when a CDN serves an error page with a 200.
    case sizeMismatch(expected: Int64, actual: Int64)
    case storage(String)
}

/// Fetching one release's `.pbz`. A protocol so hand-off can be tested without a network.
public protocol FirmwareAssetDownloading: Sendable {
    /// Downloads and **verifies**, returning the verified file. Throwing means nothing usable is
    /// left on disk.
    func download(
        _ release: FirmwareRelease,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL
}

// MARK: - Verification

public enum FirmwareChecksum {
    /// Streaming SHA-256 of a file. Streamed rather than `Data(contentsOf:)` because the thing
    /// being hashed is an arbitrary-size binary from the internet, and reading it whole to
    /// check it would be the one place this feature could be made to exhaust memory.
    public static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies a downloaded file against its release, **deleting it on any failure**.
    ///
    /// The delete is the point of this function existing at all. An unverified `.pbz` sitting in
    /// the staging directory is one stray share-sheet tap away from being flashed, and the
    /// share sheet cannot tell a verified file from an unverified one. So the invariant is:
    /// a file in the staging directory has passed this check, or it is not there.
    public static func verify(fileAt url: URL, matches release: FirmwareRelease) throws {
        func discard() { try? FileManager.default.removeItem(at: url) }

        if let expectedSize = release.sizeBytes {
            let actual = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                .flatMap { ($0 as? NSNumber)?.int64Value } ?? -1
            if actual != expectedSize {
                discard()
                throw FirmwareDownloadError.sizeMismatch(expected: expectedSize, actual: actual)
            }
        }
        let actual: String
        do {
            actual = try sha256Hex(ofFileAt: url)
        } catch {
            discard()
            throw FirmwareDownloadError.storage("Could not read the downloaded file")
        }
        guard actual == release.sha256 else {
            discard()
            throw FirmwareDownloadError.checksumMismatch(
                expected: release.sha256, actual: actual
            )
        }
    }
}

// MARK: - Staging

/// The directory downloaded firmware waits in between "verified" and "handed over".
///
/// Caches, not Documents: these files are disposable, must never appear in the person's own
/// files, and must not be swept into an iCloud backup. Everything here has passed
/// `FirmwareChecksum.verify` — see the invariant on that function.
public struct FirmwareStagingArea: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PendingFirmware", isDirectory: true)
        self.directory = base
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// Where this release's file goes. The name — and specifically its `.pbz` suffix — is what
    /// makes the hand-off work at all; see `FirmwareRelease.suggestedFileName`.
    public func location(for release: FirmwareRelease) -> URL {
        directory.appendingPathComponent(release.suggestedFileName, isDirectory: false)
    }

    /// A previously verified download for this release, if one is still here.
    public func existingDownload(for release: FirmwareRelease) -> URL? {
        let url = location(for: release)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes everything that is not this release — one pending firmware at a time, so an old
    /// build cannot be picked by mistake from a share sheet or a Files browser.
    public func removeAll(except release: FirmwareRelease? = nil) {
        let keep = release.map { location(for: $0).lastPathComponent }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in contents where file.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Live downloader

/// `URLSession` download task → file → verify.
///
/// A download task (not `data(from:)`) so the image lands straight in a file with real byte
/// progress, the same shape `URLSessionArchiveDownloader` uses for the speech models.
public final class URLSessionFirmwareDownloader: FirmwareAssetDownloading {
    private let configuration: URLSessionConfiguration

    /// Deliberately NOT Wi-Fi-only, unlike the speech-model downloader. A firmware `.pbz` is a
    /// couple of megabytes, and the moment someone wants one is usually the moment they are
    /// reading the release notes — refusing on cellular would trade a trivial amount of data
    /// for a dead button with no explanation the person can act on.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func download(
        _ release: FirmwareRelease,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let handle = DownloadHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let delegate = FirmwareDownloadDelegate(
                    destination: destination,
                    onProgress: onProgress,
                    onFinished: { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                )
                let session = URLSession(
                    configuration: configuration, delegate: delegate, delegateQueue: nil
                )
                let task = session.downloadTask(with: release.assetURL)
                handle.store(task)
                if handle.isCancelled {
                    task.cancel()
                    session.finishTasksAndInvalidate()
                }
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
        // Verification is inside the downloader, not left to the caller, so there is no code
        // path that produces an unverified file at all.
        try FirmwareChecksum.verify(fileAt: destination, matches: release)
        return destination
    }
}

private final class DownloadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func store(_ task: URLSessionDownloadTask) {
        lock.lock(); self.task = task; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class FirmwareDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinished: @Sendable (Error?) -> Void
    private var moveError: Error?
    private var finished = false

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Error?) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` the moment this returns, so the move is synchronous.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200...299).contains(status) else {
            moveError = FirmwareDownloadError.http(status: status)
            return
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            moveError = FirmwareDownloadError.storage(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finished { return }
        finished = true
        session.finishTasksAndInvalidate()
        if let error {
            onFinished(FirmwareDownloadError.network(error.localizedDescription))
        } else {
            onFinished(moveError)
        }
    }
}
