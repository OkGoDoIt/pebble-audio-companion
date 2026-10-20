import Foundation
import Security

/// The import's own link to a server, kept in the login Keychain between runs: one item per
/// server origin, holding the device id and its `pad_` token. Never printed, never written
/// anywhere else.
public struct SavedLink: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String

    public init(deviceId: String, deviceToken: String) {
        self.deviceId = deviceId
        self.deviceToken = deviceToken
    }
}

public struct TokenStore: Sendable {
    public static let service = "dev.audiocompanion.archive-import"

    public init() {}

    private func query(_ origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: origin,
        ]
    }

    /// Whether the Keychain may be used at all. The login Keychain asks before a rebuilt binary
    /// (a new app, to it) reads or changes the item, in a dialog on the Mac's screen that no flag
    /// of `SecItem` suppresses for this kind of item. A run with no terminal is someone else's
    /// (a script, an agent): it must not put that dialog in front of the person, so it neither
    /// reads nor writes the link.
    public static var isUsable: Bool { isatty(STDIN_FILENO) == 1 }

    /// The saved link for `origin`.
    public func load(origin: String) -> SavedLink? {
        var query = query(origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(SavedLink.self, from: data)
    }

    public func save(_ link: SavedLink, origin: String) throws {
        let data = try JSONEncoder().encode(link)
        let status = SecItemUpdate(
            query(origin) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(origin)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Pebble Audio backup import (\(origin))"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func remove(origin: String) {
        SecItemDelete(query(origin) as CFDictionary)
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain did not save the link: \(message)"
        }
    }
}
