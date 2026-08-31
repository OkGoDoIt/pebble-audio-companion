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

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// The response: HTTP status plus the raw body.
public struct HttpTransportResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public init(status: Int, text: String) {
        self.init(status: status, body: Data(text.utf8))
    }

    /// Body decoded as UTF-8 (lossy) — cloud APIs speak JSON/UTF-8.
    public var text: String { String(decoding: body, as: UTF8.self) }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Foreground HTTP transport. Implementations throw on transport-level failures (no response);
/// an HTTP error status is returned as a normal response for the caller to interpret.
public protocol HttpTransport: Sendable {
    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse
}

/// Production transport over a plain (foreground) `URLSession`.
public final class URLSessionHttpTransport: HttpTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
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
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HttpTransportResponse(status: status, body: data)
    }
}
