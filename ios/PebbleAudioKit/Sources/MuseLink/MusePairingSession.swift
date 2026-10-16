import CryptoKit
import Foundation

/// Device side of Muse gadget BLE pairing, protocol version 5, community mode — a port of Meta's
/// `linux/src/musegadget/pairing.py` (Apache-2.0).
///
/// `pairing_auth` is `"none"` (no manufacturer proof) and the policy is `confirm_app`: the Muse
/// app has already collected the user's consent, so a valid client-finished record confirms the
/// session without a button press on the gadget. Transcript, key schedule and record encryption
/// match Meta's firmware byte for byte (checked against `link_pairing_v5.json`).
///
/// Community pairing protects setup secrets (the device tokens) from passive observers. It does not
/// authenticate the ECDH peer, so it cannot stop an active man-in-the-middle — the same limit Meta
/// documents for every community gadget.
///
/// A value type: the owner (`MuseSetupController`, an actor) serialises access. Methods that
/// advance the handshake return a nonzero *generation*; asynchronous work (provisioning) holds on
/// to it and checks `isCurrent` before acting, so work from an abandoned attempt can't act on a
/// newer one.
public struct MusePairingSession: Sendable {
    public enum State: String, Sendable {
        case idle, waitClientFinished, ready, provisioning
    }

    public struct Failure: Error, Equatable {
        /// The wire status to report.
        public let status: String
    }

    public static let version = 5
    public static let model = "hatch_link"
    public static let suite = "p256-hkdf-sha256-aes-gcm-v1"
    public static let policyButton = "confirm_press"
    public static let policyApp = "confirm_app"
    public static let authOfficial = "fleet_ecdsa_p256_v1"
    public static let authCommunity = "none"
    public static let buttonConfirmTimeoutSeconds = 60
    public static let recordLabel = "hatch-link ble setup v1"
    static let sessionIDLabel = Data("hatch-link session id v1".utf8)

    public static let clientFinishedTimeout: TimeInterval = 60
    public static let confirmedTimeout: TimeInterval = 120
    public static let provisioningTimeout: TimeInterval = 120

    public static let errorInvalidHello = "error_pairing_invalid_hello"
    public static let errorDecrypt = "error_pairing_decrypt"

    static let p256PointBytes = 65
    static let nonceBytes = 16
    static let sessionIDBytes = 16
    static let tagBytes = 16
    public static let maxB64Chars = 4096
    static let maxCiphertextB64Chars = 16384
    static let toDevice: UInt8 = 0
    static let fromDevice: UInt8 = 1

    public let nodeID: String
    public let deviceID: String
    public let mac: String
    public let firmwareVersion: String
    public let sdkToken: String?

    private let clock: @Sendable () -> TimeInterval
    private let generateKey: @Sendable () -> P256.KeyAgreement.PrivateKey
    private let randomBytes: @Sendable (Int) -> Data

    public private(set) var generation = 0
    private var stateValue: State = .idle
    private var deadline: TimeInterval = 0
    private var rxKey: SymmetricKey?
    private var txKey: SymmetricKey?
    private var sessionIDB64 = ""
    private var rxCounter: UInt64 = 0
    private var txCounter: UInt64 = 0

    public init(
        identity: MuseGadgetIdentity,
        firmwareVersion: String,
        sdkToken: String?,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        generateKey: @escaping @Sendable () -> P256.KeyAgreement.PrivateKey = { P256.KeyAgreement.PrivateKey() },
        randomBytes: @escaping @Sendable (Int) -> Data = MusePairingSession.secureRandomBytes
    ) {
        self.nodeID = identity.nodeID
        self.deviceID = identity.deviceID
        self.mac = identity.mac
        self.firmwareVersion = firmwareVersion.isEmpty ? "unknown" : firmwareVersion
        self.sdkToken = sdkToken
        self.clock = clock
        self.generateKey = generateKey
        self.randomBytes = randomBytes
        reset()
    }

    public static func secureRandomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Pairing fields for the `get_device_info` response.
    public var deviceInfoFields: [String: MuseJSON] {
        [
            "device_id": .string(deviceID),
            "mac": .string(mac),
            "model": .string(Self.model),
            "pairing_protocol": .number(Double(Self.version)),
            "pairing_auth": .string(Self.authCommunity),
            "pairing_auth_epoch": 0,
            "pairing_policy": .string(Self.policyApp),
        ]
    }

    public mutating func state() -> State {
        expireIfDue()
        return stateValue
    }

    public mutating func isConfirmed() -> Bool {
        let state = state()
        return state == .ready || state == .provisioning
    }

    public func isCurrent(_ generation: Int) -> Bool {
        generation != 0 && generation == self.generation
    }

    public mutating func reset() {
        generation += 1
        clear()
    }

    /// Starts a session from `pairing_client_hello`; returns the `pairing_ready` message.
    public mutating func handleHello(_ message: MuseJSON) throws(Failure) -> MuseJSON {
        guard
            let version = message["version"]?.number, version == Double(Self.version),
            message["pairing_auth"]?.string == Self.authCommunity,
            message["pairing_policy"]?.string == Self.policyApp
        else { throw Failure(status: Self.errorInvalidHello) }

        reset()
        let peer: P256.KeyAgreement.PublicKey
        let mobilePub: Data
        let mobileNonce: Data
        do {
            mobilePub = try MuseBase64URL.decode(message["mobile_pub"])
            mobileNonce = try MuseBase64URL.decode(message["mobile_nonce"])
            guard mobilePub.count == Self.p256PointBytes, mobilePub.first == 0x04,
                mobileNonce.count == Self.nonceBytes
            else { throw Failure(status: Self.errorInvalidHello) }
            peer = try P256.KeyAgreement.PublicKey(x963Representation: mobilePub)
        } catch {
            reset()
            throw Failure(status: Self.errorInvalidHello)
        }

        let deviceKey = generateKey()
        let devicePub = deviceKey.publicKey.x963Representation
        let deviceNonce = randomBytes(Self.nonceBytes)
        let transcript: String
        let ecdhSecret: Data
        do {
            transcript = try Self.transcript(
                community: true, authEpoch: 0, policy: Self.policyApp,
                deviceID: deviceID, nodeID: nodeID, mac: mac, firmwareVersion: firmwareVersion,
                mobilePub: MuseBase64URL.encode(mobilePub), devicePub: MuseBase64URL.encode(devicePub),
                mobileNonce: MuseBase64URL.encode(mobileNonce),
                deviceNonce: MuseBase64URL.encode(deviceNonce))
            ecdhSecret = try deviceKey.sharedSecretFromKeyAgreement(with: peer)
                .withUnsafeBytes { Data($0) }
        } catch {
            reset()
            throw Failure(status: Self.errorInvalidHello)
        }
        let transcriptHash = Data(SHA256.hash(data: Data(transcript.utf8)))
        let keys = Self.deriveSessionKeys(
            ecdhSecret: ecdhSecret, mobileNonce: mobileNonce, deviceNonce: deviceNonce,
            transcriptHash: transcriptHash)

        // The mobile's TX key opens what this device receives; its RX key seals what we send.
        rxKey = SymmetricKey(data: keys.mobileTX)
        txKey = SymmetricKey(data: keys.mobileRX)
        sessionIDB64 = MuseBase64URL.encode(keys.sessionID)
        rxCounter = 0
        txCounter = 0
        stateValue = .waitClientFinished
        deadline = clock() + Self.clientFinishedTimeout
        return [
            "type": "pairing_ready",
            "version": .number(Double(Self.version)),
            "device_id": .string(deviceID),
            "node_id": .string(nodeID),
            "mac": .string(mac),
            "model": .string(Self.model),
            "firmware_version": .string(firmwareVersion),
            "pairing_auth": .string(Self.authCommunity),
            "pairing_auth_epoch": 0,
            "pairing_policy": .string(Self.policyApp),
            "device_pub": .string(MuseBase64URL.encode(devicePub)),
            "device_nonce": .string(MuseBase64URL.encode(deviceNonce)),
            "transcript_hash": .string(MuseBase64URL.encode(transcriptHash)),
            "session_id": .string(sessionIDB64),
        ]
    }

    /// Opens one mobile-to-device `pairing_encrypted` record. Any failure (wrong session, skipped or
    /// replayed counter, bad tag, expiry) clears the session, as the firmware does.
    public mutating func decrypt(_ envelope: MuseJSON) throws(Failure) -> String {
        if expireIfDue() || stateValue == .idle {
            reset()
            throw Failure(status: Self.errorDecrypt)
        }
        do {
            guard envelope["session_id"]?.string == sessionIDB64, let rxKey else {
                throw Failure(status: Self.errorDecrypt)
            }
            let counter = try Self.parseCounter(envelope["counter"])
            guard counter == rxCounter else { throw Failure(status: Self.errorDecrypt) }
            let ciphertext = try MuseBase64URL.decode(envelope["ciphertext"], maxChars: Self.maxCiphertextB64Chars)
            let tag = try MuseBase64URL.decode(envelope["tag"])
            guard tag.count == Self.tagBytes else { throw Failure(status: Self.errorDecrypt) }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Self.recordNonce(direction: Self.toDevice, counter: counter)),
                ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(
                box, using: rxKey,
                authenticating: Self.recordAAD(sessionIDB64, direction: Self.toDevice, counter: counter))
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw Failure(status: Self.errorDecrypt)
            }
            rxCounter += 1
            return text
        } catch {
            reset()
            throw Failure(status: Self.errorDecrypt)
        }
    }

    /// Confirms the session after the first decrypted record. `command` must be exactly
    /// `{"action":"pairing_client_finished"}` and must have been the first record. Returns the new
    /// generation, or 0 (after clearing the session) if the record is invalid.
    public mutating func handleClientFinished(_ command: MuseJSON) -> Int {
        let ok = command == ["action": "pairing_client_finished"]
            && !expireIfDue()
            && stateValue == .waitClientFinished
            && rxCounter == 1
        guard ok else {
            reset()
            return 0
        }
        generation += 1
        stateValue = .ready
        deadline = clock() + Self.confirmedTimeout
        return generation
    }

    /// Enters provisioning from a confirmed session; returns its generation, or 0.
    public mutating func markProvisioning() -> Int {
        if !expireIfDue(), stateValue == .ready {
            generation += 1
            stateValue = .provisioning
            deadline = clock() + Self.provisioningTimeout
        }
        return stateValue == .provisioning ? generation : 0
    }

    public mutating func extendProvisioning(_ generation: Int) -> Bool {
        guard isProvisioning(generation) else { return false }
        deadline = clock() + Self.provisioningTimeout
        return true
    }

    public mutating func isProvisioning(_ generation: Int) -> Bool {
        generation != 0 && generation == self.generation && !expireIfDue() && stateValue == .provisioning
    }

    /// Seals a device-to-mobile record. `nil` when there is no active session, or when a nonzero
    /// `generation` no longer matches (the work it belongs to is stale).
    public mutating func encrypt(_ plaintext: String, generation: Int = 0) -> MuseJSON? {
        if (generation != 0 && generation != self.generation) || expireIfDue() || stateValue == .idle {
            return nil
        }
        guard let txKey else { return nil }
        let counter = txCounter
        guard
            let sealed = try? AES.GCM.seal(
                Data(plaintext.utf8), using: txKey,
                nonce: AES.GCM.Nonce(data: Self.recordNonce(direction: Self.fromDevice, counter: counter)),
                authenticating: Self.recordAAD(sessionIDB64, direction: Self.fromDevice, counter: counter))
        else { return nil }
        txCounter += 1
        return [
            "type": "pairing_encrypted",
            "session_id": .string(sessionIDB64),
            "counter": .string(String(counter)),
            "ciphertext": .string(MuseBase64URL.encode(sealed.ciphertext)),
            "tag": .string(MuseBase64URL.encode(sealed.tag)),
        ]
    }

    public mutating func encryptStatus(_ status: String, generation: Int = 0) -> MuseJSON? {
        var message: [String: MuseJSON] = ["type": "status", "status": .string(status)]
        // Apps read only type and status, so older ones ignore the token.
        if let sdkToken, !sdkToken.isEmpty, status == "pairing_confirmed" {
            message["sdk_token"] = .string(sdkToken)
        }
        return encrypt(MuseJSON.object(message).compactString(), generation: generation)
    }

    private mutating func clear() {
        stateValue = .idle
        deadline = 0
        rxKey = nil
        txKey = nil
        sessionIDB64 = ""
        rxCounter = 0
        txCounter = 0
    }

    /// Drops the keys of an expired session but keeps the generation, so the owner of the expired
    /// session can still recognise it. Returns whether it expired just now.
    @discardableResult
    private mutating func expireIfDue() -> Bool {
        guard stateValue != .idle, clock() > deadline else { return false }
        clear()
        return true
    }

    // MARK: - Protocol primitives (static so the vectors can drive them directly)

    struct InvalidTranscript: Error {}

    /// The canonical v5 transcript; its SHA-256 is the `transcript_hash`.
    static func transcript(
        community: Bool, authEpoch: Int, policy: String, deviceID: String, nodeID: String,
        mac: String, firmwareVersion: String, mobilePub: String, devicePub: String,
        mobileNonce: String, deviceNonce: String
    ) throws -> String {
        let button = policy == policyButton
        guard button || (community && policy == policyApp) else { throw InvalidTranscript() }
        guard community ? authEpoch == 0 : authEpoch > 0 else { throw InvalidTranscript() }
        let fields = [deviceID, nodeID, mac, firmwareVersion, mobilePub, devicePub, mobileNonce, deviceNonce]
        guard fields.allSatisfy({ !$0.isEmpty }) else { throw InvalidTranscript() }
        return [
            "hatch-link-pairing-v\(version)",
            "version=\(version)",
            "initiator_role=mobile",
            "responder_role=link",
            "device_id=\(deviceID)",
            "node_id=\(nodeID)",
            "mac=\(mac)",
            "model=\(model)",
            "firmware_version=\(firmwareVersion)",
            "selected_cipher_suite=\(suite)",
            "pairing_auth=\(community ? authCommunity : authOfficial)",
            "pairing_auth_epoch=\(authEpoch)",
            "pairing_policy=\(policy)",
            "confirm_timeout_seconds=\(button ? buttonConfirmTimeoutSeconds : 0)",
            "mobile_pub=\(mobilePub)",
            "device_pub=\(devicePub)",
            "mobile_nonce=\(mobileNonce)",
            "device_nonce=\(deviceNonce)",
        ].joined(separator: "\n")
    }

    struct SessionKeys: Equatable {
        /// Opens records the device receives.
        let mobileTX: Data
        /// Seals records the device sends.
        let mobileRX: Data
        let sessionID: Data
        let sessionSecret: Data
    }

    static func deriveSessionKeys(
        ecdhSecret: Data, mobileNonce: Data, deviceNonce: Data, transcriptHash: Data
    ) -> SessionKeys {
        let salt = Data(SHA256.hash(data: mobileNonce + deviceNonce + transcriptHash))
        let sessionSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ecdhSecret), salt: salt,
            info: Data(recordLabel.utf8), outputByteCount: 32)
        let secretBytes = sessionSecret.withUnsafeBytes { Data($0) }
        let mobileTX = HKDF<SHA256>.expand(
            pseudoRandomKey: sessionSecret, info: Data("mobile->device".utf8), outputByteCount: 32)
        let mobileRX = HKDF<SHA256>.expand(
            pseudoRandomKey: sessionSecret, info: Data("device->mobile".utf8), outputByteCount: 32)
        let sessionID = Data(SHA256.hash(data: sessionIDLabel + transcriptHash + ecdhSecret)).prefix(sessionIDBytes)
        return SessionKeys(
            mobileTX: mobileTX.withUnsafeBytes { Data($0) },
            mobileRX: mobileRX.withUnsafeBytes { Data($0) },
            sessionID: Data(sessionID), sessionSecret: secretBytes)
    }

    static func recordNonce(direction: UInt8, counter: UInt64) -> Data {
        var nonce = Data([direction, 0, 0, 0])
        withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }

    static func recordAAD(_ sessionIDB64: String, direction: UInt8, counter: UInt64) -> Data {
        Data("\(recordLabel)|\(sessionIDB64)|\(direction == toDevice ? "m2d" : "d2m")|\(counter)".utf8)
    }

    static func parseCounter(_ value: MuseJSON?) throws(Failure) -> UInt64 {
        guard let text = value?.string, !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }),
            let counter = UInt64(text)
        else { throw Failure(status: errorDecrypt) }
        return counter
    }
}

/// Unpadded base64url with the reference's validation rules.
public enum MuseBase64URL {
    public struct Invalid: Error {}

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: MuseJSON?, maxChars: Int = MusePairingSession.maxB64Chars) throws -> Data {
        guard let text = value?.string else { throw Invalid() }
        return try decode(text, maxChars: maxChars)
    }

    public static func decode(_ text: String, maxChars: Int = MusePairingSession.maxB64Chars) throws -> Data {
        guard !text.isEmpty, text.count <= maxChars, text.count % 4 != 1,
            text.unicodeScalars.allSatisfy({ CharacterSet.base64URL.contains($0) })
        else { throw Invalid() }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { throw Invalid() }
        return data
    }
}

extension CharacterSet {
    fileprivate static let base64URL = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
