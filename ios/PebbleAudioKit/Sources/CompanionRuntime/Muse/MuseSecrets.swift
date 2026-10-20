import Foundation
import MuseLink
import Security

/// Where the Muse gadget keeps what it must not lose: its identity (the Muse app knows the gadget
/// by it), the device tokens the Muse app provisioned, and the developer's gadget SDK token.
public protocol MuseSecrets: Sendable {
    func identity() -> MuseGadgetIdentity?
    @discardableResult func save(identity: MuseGadgetIdentity) -> Bool
    func credentials() -> MuseGadgetCredentials?
    @discardableResult func save(credentials: MuseGadgetCredentials) -> Bool
    @discardableResult func removeCredentials() -> Bool
    func sdkToken() -> String?
    @discardableResult func setSDKToken(_ token: String?) -> Bool
}

extension MuseSecrets {
    /// The gadget's identity, made on first use and then kept: a new one is a new device to Muse.
    public func loadOrCreateIdentity() -> MuseGadgetIdentity {
        if let existing = identity() { return existing }
        let created = MuseGadgetIdentity.generate()
        save(identity: created)
        return created
    }
}

/// `MuseSecrets` in the Keychain, readable after first unlock so pairing and asking work while the
/// app runs in the background.
public struct KeychainMuseSecrets: MuseSecrets {
    private enum Account: String {
        case identity = "gadget_identity_v1"
        case credentials = "gadget_credentials_v1"
        case sdkToken = "gadget_sdk_token"
    }

    public let service: String

    public init(service: String = "dev.audiocompanion.muse") {
        self.service = service
    }

    public func identity() -> MuseGadgetIdentity? { decode(read(.identity)) }
    public func save(identity: MuseGadgetIdentity) -> Bool { write(encode(identity), .identity) }
    public func credentials() -> MuseGadgetCredentials? { decode(read(.credentials)) }
    public func save(credentials: MuseGadgetCredentials) -> Bool { write(encode(credentials), .credentials) }
    public func removeCredentials() -> Bool { delete(.credentials) }

    public func sdkToken() -> String? {
        read(.sdkToken).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setSDKToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return delete(.sdkToken) }
        return write(Data(token.utf8), .sdkToken)
    }

    private func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    private func decode<T: Decodable>(_ data: Data?) -> T? { data.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }

    private func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private func read(_ account: Account) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data?, _ account: Account) -> Bool {
        guard let data else { return false }
        var query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private func delete(_ account: Account) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// `MuseSecrets` in memory, for tests and previews.
public final class InMemoryMuseSecrets: MuseSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentity: MuseGadgetIdentity?
    private var storedCredentials: MuseGadgetCredentials?
    private var storedToken: String?

    public init(identity: MuseGadgetIdentity? = nil, credentials: MuseGadgetCredentials? = nil, sdkToken: String? = nil) {
        storedIdentity = identity
        storedCredentials = credentials
        storedToken = sdkToken
    }

    public func identity() -> MuseGadgetIdentity? { lock.withLock { storedIdentity } }
    public func save(identity: MuseGadgetIdentity) -> Bool { lock.withLock { storedIdentity = identity }; return true }
    public func credentials() -> MuseGadgetCredentials? { lock.withLock { storedCredentials } }
    public func save(credentials: MuseGadgetCredentials) -> Bool { lock.withLock { storedCredentials = credentials }; return true }
    public func removeCredentials() -> Bool { lock.withLock { storedCredentials = nil }; return true }
    public func sdkToken() -> String? { lock.withLock { storedToken } }
    public func setSDKToken(_ token: String?) -> Bool { lock.withLock { storedToken = token?.isEmpty == true ? nil : token }; return true }
}
