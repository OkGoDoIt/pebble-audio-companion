import Foundation

// Injectable HTTP seam for the cloud providers — the Swift analogue of the ktor `HttpClient`
// the KMP providers took, so every provider test runs hermetically against a fake transport
// (the KMP tests used `MockEngine` the same way). Production wiring uses
// `URLSessionHttpTransport`.

/// One outgoing HTTP request, fully assembled (multipart bodies included).
public struct HttpTransportRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    /// The body is segment audio, so the user's "Upload Audio" network choice applies to it
    /// (see `URLSessionHttpTransport.audioNetwork`). Control-plane calls — create, poll, fetch,
    /// delete — are a few hundred bytes and are not held to it.
    public var carriesAudio: Bool

    public init(
        method: String, url: String, headers: [String: String] = [:], body: Data? = nil,
        carriesAudio: Bool = false
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.carriesAudio = carriesAudio
    }
}

/// The response: HTTP status plus the raw body, and the headers for the callers that read one
/// (a 429's `Retry-After`).
public struct HttpTransportResponse: Sendable {
    public var status: Int
    public var body: Data
    /// Header names lowercased, so a lookup does not depend on how the server spelled them.
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    public init(status: Int, text: String, headers: [String: String] = [:]) {
        self.init(status: status, body: Data(text.utf8), headers: headers)
    }

    /// Body decoded as UTF-8 (lossy) — cloud APIs speak JSON/UTF-8.
    public var text: String { String(decoding: body, as: UTF8.self) }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// A header by name, case-insensitively.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Foreground HTTP transport. Implementations throw on transport-level failures (no response);
/// an HTTP error status is returned as a normal response for the caller to interpret.
public protocol HttpTransport: Sendable {
    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse
}

/// Production transport over a plain (foreground) `URLSession`.
public final class URLSessionHttpTransport: HttpTransport {
    private let session: URLSession
    /// The networks an audio-carrying request may use. Only the background uploader used to
    /// honour "Upload Audio: Wi-Fi Only"; the foreground path — a charger catch-up, a first
    /// mode's fallback, a Test Connection check — sent whole segments over cellular regardless.
    /// This is the backstop: the providers also report themselves unavailable when the policy
    /// forbids the current network, so a request normally never gets this far on cellular.
    private let audioNetwork: (@Sendable () -> CloudUploadNetwork)?

    public init(
        session: URLSession = .shared,
        audioNetwork: (@Sendable () -> CloudUploadNetwork)? = nil
    ) {
        self.session = session
        self.audioNetwork = audioNetwork
    }

    public func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        guard let url = URL(string: request.url) else {
            throw TranscriptionError.transcriptionFailed("invalid URL: \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        if request.carriesAudio, let audioNetwork {
            CloudUploadNetworkPolicy.apply(audioNetwork(), to: &urlRequest)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            guard let name = name as? String else { continue }
            headers[name] = "\(value)"
        }
        return HttpTransportResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}
