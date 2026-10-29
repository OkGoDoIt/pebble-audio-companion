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
    ///
    /// DELIBERATELY not the KMP app's `dev.audiocompanion.app.transcription-upload` (plan Part
    /// 4.8: "Use a NEW background-session identifier"). The release build installs over the old
    /// app and inherits its container; reusing the identifier would have this app adopt the dead
    /// app's still-queued upload tasks and replay their outcomes against job ids it never wrote.
    public static let sessionIdentifier = "dev.audiocompanion.app.swift-transcription-upload"

    public static let shared = URLSessionBackgroundUploader()

    public let outcomes: AsyncStream<CloudUploadOutcome>
    private let outcomeContinuation: AsyncStream<CloudUploadOutcome>.Continuation

    private let lock = NSLock()
    private var responseData: [Int: Data] = [:]
    /// Registered by the app from `handleEventsForBackgroundURLSession`; called when events drain
    /// so the system can snapshot and re-suspend the app.
    private var backgroundEventsCompletions: [@Sendable () -> Void] = []

    private let sessionIdentifierValue: String
    /// What networks uploads may use, re-read per request. See `CloudUploadNetworkPolicy` for why
    /// this is per-request state and not part of the session configuration.
    private var networkPolicy: @Sendable () -> CloudUploadNetwork
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifierValue)
        // The session retains its delegate (self) — intentional for this app-lifetime singleton.
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()
    private lazy var sessionDelegate = Delegate(owner: self)

    public init(
        sessionIdentifier: String = URLSessionBackgroundUploader.sessionIdentifier,
        networkPolicy: @escaping @Sendable () -> CloudUploadNetwork = {
            CloudUploadNetworkPolicy.default
        }
    ) {
        self.sessionIdentifierValue = sessionIdentifier
        self.networkPolicy = networkPolicy
        (self.outcomes, self.outcomeContinuation) =
            AsyncStream<CloudUploadOutcome>.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    /// Points the uploader at the live user setting.
    ///
    /// A setter rather than an init argument because the production instance is the `shared`
    /// singleton, created before any settings object exists. `AppSettings` installs a closure over
    /// its runtime box, so the next enqueued segment sees the current choice — no session rebuild,
    /// which a background session could not do anyway.
    public func setNetworkPolicy(_ policy: @escaping @Sendable () -> CloudUploadNetwork) {
        lock.withLock { networkPolicy = policy }
    }

    /// The policy the next request would be stamped with. Exposed for tests and diagnostics.
    public var currentNetworkPolicy: CloudUploadNetwork {
        lock.withLock { networkPolicy }()
    }

    /// Registers a `handleEventsForBackgroundURLSession` completion handler.
    ///
    /// Handlers ACCUMULATE rather than replace: iOS can hand over a second batch of events before
    /// the first has drained, and a handler dropped on the floor is precisely what gets the app
    /// killed ("failed to call the completion handler"). Every registered handler is called
    /// exactly once, when the session says its events are done.
    public func addBackgroundEventsCompletion(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundEventsCompletions.append(completion) }
    }

    /// Handlers still waiting on `urlSessionDidFinishEvents` (tests assert the contract).
    public var pendingBackgroundEventsCompletions: Int {
        lock.withLock { backgroundEventsCompletions.count }
    }

    public func enqueue(_ request: CloudUploadRequest) async {
        guard let urlRequest = uploadRequest(for: request) else { return }
        // URLSession answers an unreadable body with an Objective-C exception, which Swift cannot
        // catch: the app dies. Whatever removed the file, the job fails and is retried instead.
        guard FileManager.default.isReadableFile(atPath: request.bodyFilePath) else {
            outcomeContinuation.yield(
                CloudUploadOutcome(
                    jobId: request.jobId, httpStatus: 0, error: "the upload body was missing"
                )
            )
            return
        }
        let task = session.uploadTask(
            with: urlRequest, fromFile: URL(fileURLWithPath: request.bodyFilePath)
        )
        task.taskDescription = request.jobId
        task.resume()
    }

    /// The `URLRequest` for one job, network policy included.
    ///
    /// Split out so the policy is assertable without creating a real background session (as with
    /// the completion-handler contract above). The policy is stamped here, per request, rather
    /// than on the session configuration — see `CloudUploadNetworkPolicy` for why a background
    /// session cannot carry it.
    func uploadRequest(for request: CloudUploadRequest) -> URLRequest? {
        guard let url = URL(string: request.url) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        CloudUploadNetworkPolicy.apply(currentNetworkPolicy, to: &urlRequest)
        return urlRequest
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

    /// Internal (not fileprivate) so the completion-handler contract is testable without a real
    /// background session — creating one is the only other way to reach this.
    func didFinishBackgroundEvents() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            let value = backgroundEventsCompletions
            backgroundEventsCompletions.removeAll()
            return value
        }
        for completion in completions { completion() }
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
