import Foundation

// The two ways the sync talks to the server.
//
//  - Small requests (link, requests, results, status, wipe) are ordinary data tasks on an
//    ephemeral session: they are made while the app is awake and answered in a second.
//  - Batches and clips are file bodies on a BACKGROUND session, so a batch submitted in the
//    seconds before the app is suspended still reaches the server, and its answer reaches the
//    app — now, or after iOS relaunches it (`handleEventsForBackgroundURLSession`). Each task's
//    `taskDescription` says what it carries (`batch:<id>` / `clip:<requestId>`), which is all an
//    answer delivered to a later process has to go on.

public struct ArchiveHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol ArchiveHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse
}

public struct URLSessionArchiveHTTP: ArchiveHTTP {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        let (data, response) = try await session.data(for: request)
        return ArchiveHTTPResponse(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// One finished background task: what it carried, and the server's answer (or why there was
/// none).
public struct ArchiveUploadOutcome: Sendable, Equatable {
    public var description: String
    public var status: Int
    public var body: Data
    public var error: String?

    public init(description: String, status: Int, body: Data, error: String? = nil) {
        self.description = description
        self.status = status
        self.body = body
        self.error = error
    }
}

public protocol ArchiveUploading: Sendable {
    var outcomes: AsyncStream<ArchiveUploadOutcome> { get }
    func upload(_ request: URLRequest, fromFile file: URL, description: String) async
    /// Descriptions of the tasks the session still holds (running or suspended).
    func inFlight() async -> Set<String>
    func reconnect() async
    /// Cancels every task whose description starts with `prefix` (a Delete All cancels the
    /// batches still uploading, so none lands after the server's wipe).
    func cancel(descriptionsWithPrefix prefix: String) async
}

/// The archive sync's background session. Its own identifier, never the transcription
/// uploader's: a session belongs to one owner, and that one's outcomes are about segments.
public final class URLSessionArchiveUploader: NSObject, ArchiveUploading, @unchecked Sendable {
    public static let sessionIdentifier = "dev.audiocompanion.app.archive-sync"
    public static let shared = URLSessionArchiveUploader()

    public let outcomes: AsyncStream<ArchiveUploadOutcome>
    private let continuation: AsyncStream<ArchiveUploadOutcome>.Continuation
    private let lock = NSLock()
    private var responseData: [Int: Data] = [:]
    private var backgroundEventsCompletions: [@Sendable () -> Void] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Text is small: send it whenever the system can, cellular included. Clips are capped
        // by the server at twenty minutes of Speex (about 2 MB).
        config.allowsCellularAccess = true
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private lazy var delegate = Delegate(owner: self)

    public override init() {
        (outcomes, continuation) = AsyncStream<ArchiveUploadOutcome>.makeStream(
            bufferingPolicy: .unbounded)
        super.init()
    }

    public func upload(_ request: URLRequest, fromFile file: URL, description: String) async {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    public func inFlight() async -> Set<String> {
        let tasks = await withCheckedContinuation { (done: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { done.resume(returning: $0) }
        }
        return Set(
            tasks.filter { $0.state == .running || $0.state == .suspended }
                .compactMap(\.taskDescription))
    }

    /// Touching the session recreates it with the same identifier, which re-attaches its tasks
    /// and delivers whatever finished while the app was not running.
    public func reconnect() async { _ = await inFlight() }

    public func cancel(descriptionsWithPrefix prefix: String) async {
        let tasks = await withCheckedContinuation { (done: CheckedContinuation<[URLSessionTask], Never>) in
            session.getAllTasks { done.resume(returning: $0) }
        }
        for task in tasks where task.taskDescription?.hasPrefix(prefix) == true {
            task.cancel()
        }
    }

    /// `handleEventsForBackgroundURLSession`'s handler, called once the session's events drain.
    public func addBackgroundEventsCompletion(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundEventsCompletions.append(completion) }
        // Make sure the session exists so its events are delivered at all.
        _ = session
    }

    fileprivate func didReceive(_ data: Data, task: Int) {
        lock.withLock { responseData[task, default: Data()].append(data) }
    }

    fileprivate func didComplete(_ task: URLSessionTask, error: Error?) {
        let body = lock.withLock { responseData.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let description = task.taskDescription else { return }
        continuation.yield(
            ArchiveUploadOutcome(
                description: description,
                status: (task.response as? HTTPURLResponse)?.statusCode ?? 0, body: body,
                error: error.map { ($0 as NSError).localizedDescription }))
    }

    fileprivate func didFinishEvents() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            defer { backgroundEventsCompletions.removeAll() }
            return backgroundEventsCompletions
        }
        for completion in completions { completion() }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: URLSessionArchiveUploader?
        init(owner: URLSessionArchiveUploader) { self.owner = owner }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.didReceive(data, task: dataTask.taskIdentifier)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.didComplete(task, error: error)
        }

        #if os(iOS)
            func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
                owner?.didFinishEvents()
            }
        #endif
    }
}

/// The server's address and this phone's credentials, and the requests built from them.
public struct ArchiveEndpoint: Sendable, Equatable {
    public var origin: URL
    public var deviceId: String
    public var token: String

    public init(origin: URL, deviceId: String, token: String) {
        self.origin = origin
        self.deviceId = deviceId
        self.token = token
    }

    public var host: String { origin.host ?? origin.absoluteString }

    public func request(_ method: String, _ path: String, json: Bool = true) -> URLRequest {
        var request = URLRequest(url: ArchiveEndpoint.url(origin, path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ArchiveSyncProtocol.version, forHTTPHeaderField: "X-Sync-Protocol")
        if json { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func url(_ origin: URL, _ path: String) -> URL {
        var base = origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? origin
    }

    /// The server a link may be made to: `https`, or plain `http` to this Mac's own loopback
    /// for a development server. Anything else is refused before a code is sent anywhere.
    public static func acceptableOrigin(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed), let host = components.host,
            !host.isEmpty, let scheme = components.scheme?.lowercased()
        else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
            || host.lowercased().hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        return origin.url
    }
}

/// `pebbleaudio://link?code=…&origin=…`, the QR code the server's admin page shows.
public struct ArchiveLinkInvitation: Equatable, Sendable {
    public static let scheme = "pebbleaudio"

    public var code: String
    public var origin: URL

    public init(code: String, origin: URL) {
        self.code = code
        self.origin = origin
    }

    public var host: String { origin.host ?? origin.absoluteString }

    public static func parse(_ url: URL) -> ArchiveLinkInvitation? {
        // The universal-link form, `https://<server>/link?code=…`: the server is the page's own
        // origin (a link to one server can never name another).
        if url.scheme?.lowercased() == "https", url.path == "/link" || url.path == "/link/" {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                let code = items.first(where: { $0.name == "code" })?.value.map(normalizedCode),
                !code.isEmpty, let host = url.host,
                let origin = ArchiveEndpoint.acceptableOrigin(
                    "https://\(host)\(url.port.map { ":\($0)" } ?? "")")
            else { return nil }
            return ArchiveLinkInvitation(code: code, origin: origin)
        }
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "link",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let code = items.first(where: { $0.name == "code" })?.value.map(normalizedCode),
            !code.isEmpty
        else { return nil }
        let originText = items.first(where: { $0.name == "origin" })?.value
            ?? ArchiveSyncProtocol.defaultOrigin
        guard let origin = ArchiveEndpoint.acceptableOrigin(originText) else { return nil }
        return ArchiveLinkInvitation(code: code, origin: origin)
    }

    /// What a person might type for a code: spaces and dashes are not part of it.
    public static func normalizedCode(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
