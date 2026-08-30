import Foundation
import Security

/// Keychain-backed secret storage (Q7/B13: API keys and the receiver identity never live in
/// UserDefaults or render in plaintext).
public struct KeychainStore: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        /// 32-byte receiver id, lowercase hex. LOAD-BEARING: the watch stores SHA-256 of it —
        /// migrated from the old app's NSUserDefaults, never regenerated while a binding exists.
        case receiverId = "receiver_id_v1"
        case openAiApiKey = "openai_api_key"
        case sonioxApiKey = "soniox_api_key"
    }

    public let service: String

    public init(service: String = "dev.audiocompanion") {
        self.service = service
    }

    public func string(for key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ value: String, for key: Key) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func remove(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Masked rendering for the API-key change flow ("sk-…gtT4") — keys never render whole.
    public func maskedString(for key: Key) -> String? {
        guard let value = string(for: key) else { return nil }
        guard value.count > 8 else { return "••••" }
        return "\(value.prefix(3))…\(value.suffix(4))"
    }

    private func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
