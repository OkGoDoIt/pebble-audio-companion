import Foundation

// Port of the KMP app-layer `IosBackgroundUploader.kt` into the provider layer.

/// iOS background-upload transport for cloud transcription. Uses a background `URLSession` so
/// uploads keep running while the app is suspended; iOS relaunches the app on completion and
/// re-delivers outcomes once `reconcile()` recreates the session by identifier.
///
/// The request body is uploaded from a file (background sessions require file bodies). Each
/// task's `taskDescription` carries the job id so outcomes correlate back to the segment across
/// relaunches.
public final class URLSessionBackgroundUploader: NSObject, BackgroundUploader, @unchecked Sendable {
    /// One background session per app (the system allows a single live session per identifier).
    public static let sessionIdentifier = "dev.audiocompanion.app.transcription-upload"

    public static let shared = URLSessionBackgroundUploader()

    public let outcomes: AsyncStream<CloudUploadOutcome>
    private let outcomeContinuation: AsyncStream<CloudUploadOutcome>.Continuation

    private let lock = NSLock()
    private var responseData: [Int: Data] = [:]
    /// Set by the AppDelegate from `handleEventsForBackgroundURLSession`; called when events
    /// drain so the system can snapshot and re-suspend the app.
    private var _backgroundEventsCompletion: (() -> Void)?

    private let sessionIdentifierValue: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifierValue)
        // The session retains its delegate (self) — intentional for this app-lifetime singleton.
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()
    private lazy var sessionDelegate = Delegate(owner: self)

    public init(sessionIdentifier: String = URLSessionBackgroundUploader.sessionIdentifier) {
        self.sessionIdentifierValue = sessionIdentifier
        (self.outcomes, self.outcomeContinuation) =
            AsyncStream<CloudUploadOutcome>.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    public var backgroundEventsCompletion: (() -> Void)? {
        get { lock.withLock { _backgroundEventsCompletion } }
        set { lock.withLock { _backgroundEventsCompletion = newValue } }
    }

    public func enqueue(_ request: CloudUploadRequest) async {
        guard let url = URL(string: request.url) else { return }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.uploadTask(
            with: urlRequest, fromFile: URL(fileURLWithPath: request.bodyFilePath)
        )
        task.taskDescription = request.jobId
        task.resume()
    }

    public func reconcile() async {
        // Touching the session recreates it with the same identifier and re-attaches its tasks.
        _ = await allTasks()
    }

    public func inFlightJobIds() async -> Set<String> {
        let tasks = await allTasks()
        return Set(
            tasks
                .filter { $0.state == .running || $0.state == .suspended }
                .compactMap(\.taskDescription)
        )
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    // MARK: - URLSession delegate plumbing

    fileprivate func didReceive(data: Data, taskIdentifier: Int) {
        lock.withLock { responseData[taskIdentifier, default: Data()].append(data) }
    }

    fileprivate func didComplete(task: URLSessionTask, error: Error?) {
        guard let jobId = task.taskDescription else { return }
        let body = lock.withLock { responseData.removeValue(forKey: task.taskIdentifier) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let outcome: CloudUploadOutcome
        if let error {
            outcome = CloudUploadOutcome(
                jobId: jobId, httpStatus: 0, error: (error as NSError).localizedDescription
            )
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            outcome = CloudUploadOutcome(jobId: jobId, httpStatus: status, responseBody: body)
        }
        outcomeContinuation.yield(outcome)
    }

    fileprivate func didFinishBackgroundEvents() {
        let completion = lock.withLock { () -> (() -> Void)? in
            let value = _backgroundEventsCompletion
            _backgroundEventsCompletion = nil
            return value
        }
        completion?()
    }

    /// Separate delegate object so the uploader itself stays a plain `NSObject` without
    /// re-entrant retain knots in the session's delegate machinery.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: URLSessionBackgroundUploader?

        init(owner: URLSessionBackgroundUploader) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            owner?.didReceive(data: data, taskIdentifier: dataTask.taskIdentifier)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            owner?.didComplete(task: task, error: error)
        }

        #if os(iOS)
            func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
                owner?.didFinishBackgroundEvents()
            }
        #endif
    }
}
