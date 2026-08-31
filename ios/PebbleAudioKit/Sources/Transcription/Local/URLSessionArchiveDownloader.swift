import Foundation

// Port of `IosCactusModelPathProvider.DownloadDelegate`: an `NSURLSession` DOWNLOAD task, so the
// ~700 MB archive lands in a file and never passes through memory, with real byte progress and
// task cancellation. (The KMP comment records that an earlier `dataWithContentsOfURL` version
// held the whole archive in RAM and reported no progress at all.)

/// Downloads an archive to `destination` over URLSession, reporting bytes as they land.
public final class URLSessionArchiveDownloader: ParakeetArchiveDownloading {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let handle = TaskHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let delegate = ArchiveDownloadDelegate(
                    destination: destination,
                    onProgress: onProgress,
                    onFinished: { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
                let session = URLSession(
                    configuration: configuration, delegate: delegate, delegateQueue: nil
                )
                let task = session.downloadTask(with: url)
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
    }
}

/// Cancellation bridge between the structured-concurrency cancellation handler and the task.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func store(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class ArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked
    Sendable
{
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
        // The system deletes `location` when this callback returns, so move it synchronously.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            moveError = TranscriptionError.transcriptionFailed("Model download failed: HTTP \(status)")
            return
        }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            moveError = TranscriptionError.transcriptionFailed(
                "Failed to store the downloaded model archive", underlying: error
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if finished { return }
        finished = true
        session.finishTasksAndInvalidate()
        onFinished(error ?? moveError)
    }
}
