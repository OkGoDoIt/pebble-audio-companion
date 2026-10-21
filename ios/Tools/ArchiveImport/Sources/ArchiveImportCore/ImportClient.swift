import AppDB
import CompanionRuntime
import Foundation

/// The server, over a plain `URLSession`: a Mac stays awake for the whole import, so batches are
/// ordinary uploads and need no background session. Every request is built by the phone's own
/// `ArchiveEndpoint` (token, `X-Sync-Protocol: 1`, content types).
public struct ImportClient: Sendable {
    public let origin: URL
    private let session: URLSession

    public init(origin: URL) {
        self.origin = origin
        let config = URLSessionConfiguration.ephemeral
        // A full batch is 8 MB; over a slow uplink that is more than the default minute.
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case codeRefused
        case tooManyCodes
        case unauthorized
        case upgradeRequired
        case server(status: Int, message: String?)
        case network(String)
        case malformed

        public var description: String {
            switch self {
            case .codeRefused:
                return "The server did not accept that code. Codes last ten minutes and work once; "
                    + "show a new one on the admin page (Phones › Show a code)."
            case .tooManyCodes:
                return "Too many wrong codes from this address. Try again in a few minutes."
            case .unauthorized:
                return "The server no longer accepts this import's link. Show a new code on the "
                    + "admin page (Phones › Show a code) and run again with --code."
            case .upgradeRequired:
                return "The server needs a newer sync protocol than this tool speaks. Update the "
                    + "repository and rebuild."
            case .server(let status, let message):
                return "The server answered \(status)" + (message.map { ": \($0)" } ?? ".")
            case .network(let message):
                return "Could not reach the server: \(message)"
            case .malformed:
                return "The server's answer could not be read."
            }
        }

        /// Worth sending the same request again after a pause.
        public var isTransient: Bool {
            switch self {
            case .network: return true
            case .server(let status, _): return status >= 500 || status == 429
            default: return false
            }
        }
    }

    // MARK: - §1 linking

    /// `POST /link`, exactly as `ArchiveSyncService.link` sends it.
    public func link(code: String, deviceName: String) async throws -> ArchiveLinkResponse {
        var request = URLRequest(url: url("/link"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ArchiveSyncProtocol.version, forHTTPHeaderField: "X-Sync-Protocol")
        // `ArchiveLinkRequest`'s fields; its initializer is the kit's own.
        struct LinkBody: Encodable {
            var code: String
            var deviceName: String
            var appVersion: String
            var appBuild: String
        }
        request.httpBody = try JSONEncoder().encode(
            LinkBody(
                code: ArchiveLinkInvitation.normalizedCode(code), deviceName: deviceName,
                appVersion: "1.0", appBuild: "archive-import"))
        let (status, body) = try await send(request)
        switch status {
        case 200, 201:
            guard let linked = try? JSONDecoder().decode(ArchiveLinkResponse.self, from: body),
                linked.deviceToken.hasPrefix("pad_")
            else { throw Failure.malformed }
            return linked
        case 400, 404, 409, 410: throw Failure.codeRefused
        case 429: throw Failure.tooManyCodes
        case 426: throw Failure.upgradeRequired
        default: throw Failure.server(status: status, message: Self.errorText(body))
        }
    }

    // MARK: - §5 the sharing scope the person chose, when the server carries one

    public func storedScope(_ endpoint: ArchiveEndpoint) async throws -> ImportScope? {
        let (status, body) = try await send(endpoint.request("GET", "/sync/preferences", json: false))
        switch status {
        case 200:
            let value = try? JSONDecoder().decode(ArchiveJSONValue.self, from: body)
            return ImportScope.fromServer(value?["scope"])
        // A server from before preferences existed holds no scope.
        case 404: return nil
        case 401: throw Failure.unauthorized
        case 426: throw Failure.upgradeRequired
        default: throw Failure.server(status: status, message: Self.errorText(body))
        }
    }

    /// What the server says about the phone's own archive (`GET /sync/status`, §5): where what a
    /// phone sent begins, and when the archive was last deleted. Both are nil on a server from
    /// before they existed, and then the import behaves as if no phone had synced.
    public struct Holdings: Equatable, Sendable {
        public var phoneSinceMs: Int64?
        public var wipedAtMs: Int64?

        public init(phoneSinceMs: Int64?, wipedAtMs: Int64?) {
            self.phoneSinceMs = phoneSinceMs
            self.wipedAtMs = wipedAtMs
        }
    }

    public func holdings(_ endpoint: ArchiveEndpoint) async throws -> Holdings {
        let (status, body) = try await send(endpoint.request("GET", "/sync/status", json: false))
        switch status {
        case 200:
            let value = try? JSONDecoder().decode(ArchiveJSONValue.self, from: body)
            return Holdings(
                phoneSinceMs: ArchiveTime.ms(value?["phoneSince"]?.string),
                wipedAtMs: ArchiveTime.ms(value?["wipedAt"]?.string))
        case 401: throw Failure.unauthorized
        case 426: throw Failure.upgradeRequired
        default: throw Failure.server(status: status, message: Self.errorText(body))
        }
    }

    // MARK: - §3 batches

    public enum BatchAnswer: Sendable {
        case answered(ArchiveBatchResponse)
        /// 413: the server wants smaller batches.
        case tooLarge
    }

    public func sendBatch(_ body: Data, _ endpoint: ArchiveEndpoint) async throws -> BatchAnswer {
        var request = endpoint.request("PUT", "/sync/batch")
        request.httpBody = body
        let (status, answer) = try await send(request)
        switch status {
        case 200:
            guard let response = try? JSONDecoder().decode(ArchiveBatchResponse.self, from: answer)
            else { throw Failure.malformed }
            return .answered(response)
        case 413: return .tooLarge
        case 401: throw Failure.unauthorized
        case 426: throw Failure.upgradeRequired
        default: throw Failure.server(status: status, message: Self.errorText(answer))
        }
    }

    // MARK: -

    private func url(_ path: String) -> URL {
        var base = origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? origin
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            // The error names the URL at most; the request's headers are never part of it.
            throw Failure.network((error as NSError).localizedDescription)
        }
    }

    /// `{ "error": "…" }`, which the server sends with every refusal.
    static func errorText(_ body: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
    }
}
