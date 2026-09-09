import Foundation

/// Fetching the release feed. A protocol so the update model can be driven from fixtures in
/// tests — the live implementation is the only thing that touches the network.
public protocol FirmwareFeedFetching: Sendable {
    func fetch(from url: URL) async throws -> FirmwareFeed
}

/// `URLSession` + strict decode.
public struct URLSessionFirmwareFeedClient: FirmwareFeedFetching {
    private let session: URLSession

    public init(session: URLSession = URLSessionFirmwareFeedClient.defaultSession()) {
        self.session = session
    }

    /// The feed is a few kilobytes of JSON, so unlike the firmware asset itself it is fine to
    /// pull over cellular — the check is what makes the screen useful when someone opens it
    /// away from Wi-Fi. `reloadRevalidatingCacheData` lets the server answer 304 and keeps the
    /// bytes, while never showing a cached body the server has since replaced.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func fetch(from url: URL) async throws -> FirmwareFeed {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw FirmwareFeedError.network(error.localizedDescription)
        }
        // A `file://` fixture answers with a plain `URLResponse` and no status code; only an
        // HTTP response gets its status checked.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FirmwareFeedError.http(status: http.statusCode)
        }
        return try FirmwareFeed.decode(data)
    }
}

/// The last feed that decoded, kept on disk.
///
/// Not a performance cache: it is what lets the screen say something true when the phone is
/// offline ("checked 2 days ago"), instead of an empty screen that reads as "there is no
/// firmware". Caches directory, because losing it costs one refetch.
public struct FirmwareFeedCache: Sendable {
    public struct Entry: Sendable, Equatable {
        public let feed: FirmwareFeed
        public let fetchedAt: Date
        /// The feed URL the entry came from. A cache written against a different source is
        /// discarded rather than shown under the new one.
        public let sourceURL: URL
    }

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.fileURL = base.appendingPathComponent("firmware-feed.json", isDirectory: false)
    }

    public func load(sourceURL: URL) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.source == sourceURL.absoluteString,
              let feed = try? FirmwareFeed.decode(Data(stored.body.utf8))
        else { return nil }
        return Entry(feed: feed, fetchedAt: stored.fetchedAt, sourceURL: sourceURL)
    }

    public func store(rawBody: Data, sourceURL: URL, fetchedAt: Date = Date()) {
        guard let text = String(data: rawBody, encoding: .utf8) else { return }
        let stored = Stored(source: sourceURL.absoluteString, fetchedAt: fetchedAt, body: text)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private struct Stored: Codable {
        let source: String
        let fetchedAt: Date
        /// The feed document verbatim. Stored as text rather than as a re-encoded `FirmwareFeed`
        /// so a future build that understands more fields can read an old cache correctly.
        let body: String
    }
}

/// A fetcher that writes every successful body through to a cache. Composed rather than folded
/// into the client so tests can exercise caching without a network.
public struct CachingFirmwareFeedClient: FirmwareFeedFetching {
    private let session: URLSession
    private let cache: FirmwareFeedCache

    public init(
        session: URLSession = URLSessionFirmwareFeedClient.defaultSession(),
        cache: FirmwareFeedCache = FirmwareFeedCache()
    ) {
        self.session = session
        self.cache = cache
    }

    public func fetch(from url: URL) async throws -> FirmwareFeed {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw FirmwareFeedError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FirmwareFeedError.http(status: http.statusCode)
        }
        let feed = try FirmwareFeed.decode(data)
        // Only a body that decoded is cached, so the offline path can never serve garbage.
        cache.store(rawBody: data, sourceURL: url)
        return feed
    }

    public func cached(for url: URL) -> FirmwareFeedCache.Entry? { cache.load(sourceURL: url) }
}
