import CryptoKit
import Foundation
import Security
import Synchronization

public enum VoiceProfileProtectionError: Error, LocalizedError, Equatable, Sendable {
    case keyMissing, deviceLocked, invalidEnvelope, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .keyMissing: "Voice samples could not be restored on this phone. Set up the voice again."
        case .deviceLocked: "Unlock this phone to use voice recognition."
        case .invalidEnvelope: "This voice sample could not be read. Remove it and add a new sample."
        case .keychain: "Voice samples could not be securely stored. Please try again."
        }
    }
}

public protocol VoiceProfileProtecting: Sendable {
    /// A JSON envelope, so DB validation can bound it without possessing the decryption key.
    func seal(_ plaintext: Data) throws -> Data
    func open(_ envelope: Data) throws -> Data
    /// Missing after restore is different from temporarily inaccessible while locked.
    func hasKey() throws -> Bool
}

/// Database backups can contain encrypted envelopes, never usable voice embeddings. The key
/// is device-bound and non-synchronizing. It is created only on explicit enrollment, not launch.
public final class VoiceProfileCipher: VoiceProfileProtecting, Sendable {
    private let service: String?
    private let key = Mutex<SymmetricKey?>(nil)
    private struct Envelope: Codable { var version: Int; var algorithm: String; var ciphertext: Data }

    public init(service: String = "dev.audiocompanion.voice-profile-key.v1") { self.service = service }

    /// In-memory test/evaluation key; never persisted or shared with the installed app.
    public init(ephemeralKey: SymmetricKey) {
        service = nil
        key.withLock { $0 = ephemeralKey }
    }

    public func hasKey() throws -> Bool { try loadKey(create: false) != nil }

    public func seal(_ plaintext: Data) throws -> Data {
        guard !plaintext.isEmpty, plaintext.count <= 524_288,
              let key = try loadKey(create: true) else { throw VoiceProfileProtectionError.invalidEnvelope }
        guard let combined = try AES.GCM.seal(plaintext, using: key,
            authenticating: Data("PebbleAudioVoiceProfile:v1".utf8)).combined else {
            throw VoiceProfileProtectionError.invalidEnvelope
        }
        return try JSONEncoder().encode(Envelope(version: 1, algorithm: "AES-256-GCM", ciphertext: combined))
    }

    public func open(_ envelope: Data) throws -> Data {
        guard envelope.count <= 750_000,
              let decoded = try? JSONDecoder().decode(Envelope.self, from: envelope),
              decoded.version == 1, decoded.algorithm == "AES-256-GCM" else {
            throw VoiceProfileProtectionError.invalidEnvelope
        }
        guard let key = try loadKey(create: false) else { throw VoiceProfileProtectionError.keyMissing }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: decoded.ciphertext), using: key,
                authenticating: Data("PebbleAudioVoiceProfile:v1".utf8))
        } catch { throw VoiceProfileProtectionError.invalidEnvelope }
    }

    private func loadKey(create: Bool) throws -> SymmetricKey? {
        try key.withLock { cached in
            if let cached { return cached }
            guard let service else { return nil }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "voice-profile",
                kSecAttrSynchronizable as String: false,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            func fetch() throws -> Data? {
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                switch status {
                case errSecSuccess:
                    guard let bytes = value as? Data, bytes.count == 32 else {
                        throw VoiceProfileProtectionError.invalidEnvelope
                    }
                    return bytes
                case errSecItemNotFound: return nil
                case errSecInteractionNotAllowed: throw VoiceProfileProtectionError.deviceLocked
                default: throw VoiceProfileProtectionError.keychain(status)
                }
            }
            if let bytes = try fetch() { cached = SymmetricKey(data: bytes); return cached }
            guard create else { return nil }
            let fresh = SymmetricKey(size: .bits256)
            let bytes = fresh.withUnsafeBytes { Data($0) }
            var attributes = query
            attributes.removeValue(forKey: kSecReturnData as String)
            attributes.removeValue(forKey: kSecMatchLimit as String)
            attributes[kSecValueData as String] = bytes
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem, let existing = try fetch() {
                cached = SymmetricKey(data: existing)
            } else if status == errSecSuccess { cached = fresh }
            else if status == errSecInteractionNotAllowed { throw VoiceProfileProtectionError.deviceLocked }
            else { throw VoiceProfileProtectionError.keychain(status) }
            return cached
        }
    }
}
