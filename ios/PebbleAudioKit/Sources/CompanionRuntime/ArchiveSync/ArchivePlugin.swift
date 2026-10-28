import Foundation

// The Pebble Audio plugin for the official Pebble app (`pebble-plugin/`), as the phone sees it:
// the one-time code its settings page takes, and whether it has connected. Both come from the
// archive server under this phone's device token (`server/docs/sync-protocol.md` §5); the plugin
// itself talks to the server, never to this app.

/// `POST /sync/plugin-code`: a code for the plugin's settings page.
public struct ArchivePluginCode: Codable, Equatable, Sendable {
    /// As a person types it, `K7QM-3XWD`.
    public var code: String
    /// When it stops working. Ten minutes after it was made; it works once, and a newer code
    /// ends it.
    public var expiresAtMs: Int64

    public init(code: String, expiresAtMs: Int64) {
        self.code = code
        self.expiresAtMs = expiresAtMs
    }
}

/// `GET /sync/plugin`.
public struct ArchivePluginConnection: Codable, Equatable, Sendable {
    /// The account has a live access for the plugin (it entered a code and was not disconnected).
    public var connected: Bool
    /// Its latest read; nil before the first, and whenever it is not connected.
    public var lastUsedAtMs: Int64?

    public init(connected: Bool, lastUsedAtMs: Int64? = nil) {
        self.connected = connected
        self.lastUsedAtMs = lastUsedAtMs
    }
}

/// Why the server gave no answer.
public enum ArchivePluginFailure: Error, Equatable, Sendable {
    /// No server is linked, or the server has stopped accepting this phone.
    case notLinked
    /// The server could not be reached, or answered something this app does not understand.
    case unavailable
}

extension ArchiveSyncService {
    /// `POST /sync/plugin-code`. Each call ends the code before it.
    public func mintPluginCode() async -> Result<ArchivePluginCode, ArchivePluginFailure> {
        await pluginRequest("POST", "/sync/plugin-code")
    }

    /// `GET /sync/plugin`.
    public func pluginConnection() async -> Result<ArchivePluginConnection, ArchivePluginFailure> {
        await pluginRequest("GET", "/sync/plugin")
    }
}
