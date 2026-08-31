import Foundation

// Injectable WebSocket seam for the realtime providers — the analogue of ktor's WebSockets
// plugin in the KMP originals. Production wiring uses `URLSessionWebSocketConnector`
// (`URLSessionWebSocketTask` underneath); tests never open sockets (the accumulators and config
// builders carry the tested logic).

public enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

/// Thrown by `receive` when the socket closed (cleanly or after the peer went away) rather than
/// failing mid-message — the analogue of ktor's `incoming` channel simply ending, so the
/// realtime providers can finish their update streams normally.
public struct WebSocketClosedError: Error, Sendable {
    public init() {}
}

/// One live socket. `receive` throws when the socket closes or fails.
public protocol WebSocketConnection: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    func receive() async throws -> WebSocketMessage
    /// Idempotent close; safe from any context.
    func close()
}

public protocol WebSocketConnector: Sendable {
    /// Opens (and resumes) a socket to `url` with the given extra headers.
    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection
}

public final class URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func connect(url: URL, headers: [String: String]) -> any WebSocketConnection {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> WebSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default:
                throw TranscriptionError.transcriptionFailed("unsupported WebSocket message type")
            }
        } catch where task.closeCode != .invalid {
            // The socket was closed (the peer or `close()` ended it) — not a mid-stream failure.
            throw WebSocketClosedError()
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
