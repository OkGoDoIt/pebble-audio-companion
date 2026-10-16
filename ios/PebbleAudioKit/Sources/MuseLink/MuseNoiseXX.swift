import CryptoKit
import Foundation

/// `Noise_XX_25519_AESGCM_SHA256` with an empty prologue — a port of Meta's
/// `linux/src/musegadget/noise/noise_xx.py` (Apache-2.0).
///
/// The gadget is the initiator, and its static key is generated fresh for every connection: the VM
/// bearer token at the WebSocket upgrade is what authenticates the device, and message 3 carries an
/// empty payload. The server's static key is not pinned (neither does Meta's gadget).
public struct MuseNoiseError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One direction's AES-256-GCM key and nonce counter. Any failure poisons it: Noise has no way to
/// recover from a skipped or failed nonce.
struct MuseNoiseCipher: Sendable {
    static let maxSafeNonce: UInt64 = (1 << 53) - 1
    static let tagBytes = 16

    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var poisoned = false

    init(key: Data? = nil) {
        if let key { self.key = SymmetricKey(data: key) }
    }

    var hasKey: Bool { key != nil }

    static func iv(_ nonce: UInt64) -> Data {
        var iv = Data(count: 4)
        withUnsafeBytes(of: nonce.bigEndian) { iv.append(contentsOf: $0) }
        return iv
    }

    mutating func encrypt(ad: Data, plaintext: Data) throws(MuseNoiseError) -> Data {
        guard !poisoned else { throw MuseNoiseError("cipher poisoned after prior failure") }
        guard let key else { return plaintext }
        let current = try nextNonce()
        do {
            let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: Self.iv(current)), authenticating: ad)
            return box.ciphertext + box.tag
        } catch {
            poisoned = true
            throw MuseNoiseError("encrypt failed")
        }
    }

    mutating func decrypt(ad: Data, ciphertext: Data) throws(MuseNoiseError) -> Data {
        guard !poisoned else { throw MuseNoiseError("cipher poisoned after prior failure") }
        guard let key else { return ciphertext }
        let current = try nextNonce()
        do {
            guard ciphertext.count >= Self.tagBytes else { throw MuseNoiseError("ciphertext too short") }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Self.iv(current)),
                ciphertext: ciphertext.prefix(ciphertext.count - Self.tagBytes), tag: ciphertext.suffix(Self.tagBytes))
            return try AES.GCM.open(box, using: key, authenticating: ad)
        } catch {
            poisoned = true
            throw MuseNoiseError("decrypt failed")
        }
    }

    private mutating func nextNonce() throws(MuseNoiseError) -> UInt64 {
        guard nonce < Self.maxSafeNonce else {
            poisoned = true
            throw MuseNoiseError("nonce exhausted")
        }
        defer { nonce += 1 }
        return nonce
    }
}

enum MuseNoiseCrypto {
    static let protocolName = Data("Noise_XX_25519_AESGCM_SHA256".utf8)
    static let dhLength = 32

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF with two outputs.
    static func hkdf2(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let temp = hmac(chainingKey, inputKeyMaterial)
        let first = hmac(temp, Data([0x01]))
        let second = hmac(temp, first + Data([0x02]))
        return (first, second)
    }

    /// Curve25519's small-order points, which a peer must never be allowed to make us use.
    static let lowOrderPoints: [Data] = [
        Data(count: 32),
        Data([1] + [UInt8](repeating: 0, count: 31)),
        Data([0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE, 0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
              0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD, 0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00]),
        Data([0x5F, 0x9C, 0x95, 0xBC, 0xA3, 0x50, 0x8C, 0x24, 0xB1, 0xD0, 0xB1, 0x55, 0x9C, 0x83, 0xEF, 0x5B,
              0x04, 0x44, 0x5C, 0xC4, 0x58, 0x1C, 0x8E, 0x86, 0xD8, 0x22, 0x4E, 0xDD, 0xD0, 0x9F, 0x11, 0x57]),
        Data([0xEC] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]),
        Data([0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]),
        Data([0xEE] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]),
    ]

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKeyBytes: Data) throws(MuseNoiseError) -> Data {
        guard publicKeyBytes.count == dhLength else { throw MuseNoiseError("x25519: invalid public key length") }
        guard !lowOrderPoints.contains(publicKeyBytes) else { throw MuseNoiseError("x25519: rejected low-order public key") }
        let shared: Data
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyBytes)
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        } catch {
            throw MuseNoiseError("x25519: key agreement failed")
        }
        guard shared != Data(count: 32) else { throw MuseNoiseError("x25519: DH produced all-zeros output") }
        return shared
    }
}

struct MuseNoiseSymmetricState: Sendable {
    private(set) var chainingKey: Data
    private(set) var handshakeHash: Data
    private var cipher = MuseNoiseCipher()

    /// The gadget's prologue is empty; a non-empty one exists for the standard test vectors.
    init(prologue: Data = Data()) {
        // The protocol name fits in 32 bytes, so h is it zero-padded; then the prologue.
        var padded = MuseNoiseCrypto.protocolName
        padded.append(Data(count: 32 - padded.count))
        handshakeHash = padded
        chainingKey = padded
        mixHash(prologue)
    }

    mutating func mixHash(_ data: Data) {
        handshakeHash = Data(SHA256.hash(data: handshakeHash + data))
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (ck, tempKey) = MuseNoiseCrypto.hkdf2(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = ck
        cipher = MuseNoiseCipher(key: tempKey)
    }

    mutating func encryptAndHash(_ plaintext: Data) throws(MuseNoiseError) -> Data {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws(MuseNoiseError) -> Data {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (MuseNoiseCipher, MuseNoiseCipher) {
        let (first, second) = MuseNoiseCrypto.hkdf2(chainingKey: chainingKey, inputKeyMaterial: Data())
        return (MuseNoiseCipher(key: first), MuseNoiseCipher(key: second))
    }
}

/// The initiator's three-message handshake. Single use.
struct MuseNoiseXXInitiator: Sendable {
    static let minMessage2Length = 32 + (32 + 16) + 16

    private var state: MuseNoiseSymmetricState
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: Data?
    private(set) var remoteStatic: Data?

    init(
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
        staticKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        prologue: Data = Data()
    ) {
        self.ephemeral = ephemeral
        self.staticKey = staticKey
        self.state = MuseNoiseSymmetricState(prologue: prologue)
    }

    var handshakeHash: Data { state.handshakeHash }

    /// -> e (+ payload; the gadget's is empty)
    mutating func writeMessage1(payload: Data = Data()) throws(MuseNoiseError) -> Data {
        let publicKey = ephemeral.publicKey.rawRepresentation
        state.mixHash(publicKey)
        return publicKey + (try state.encryptAndHash(payload))
    }

    /// <- e, ee, s, es (+ payload, returned)
    mutating func readMessage2(_ message: Data) throws(MuseNoiseError) -> Data {
        guard message.count >= Self.minMessage2Length else {
            throw MuseNoiseError("message 2 too short (\(message.count) < \(Self.minMessage2Length))")
        }
        let bytes = Data(message)
        let re = bytes.prefix(32)
        remoteEphemeral = re
        state.mixHash(re)
        state.mixKey(try MuseNoiseCrypto.dh(ephemeral, re))
        let rs = try state.decryptAndHash(bytes.subdata(in: 32..<(32 + 48)))
        remoteStatic = rs
        state.mixKey(try MuseNoiseCrypto.dh(ephemeral, rs))
        return try state.decryptAndHash(bytes.subdata(in: (32 + 48)..<bytes.count))
    }

    /// -> s, se (+ payload; the gadget's is empty — the bearer token authenticated it already)
    mutating func writeMessage3(payload: Data = Data()) throws(MuseNoiseError) -> Data {
        guard let remoteEphemeral else { throw MuseNoiseError("message 3 before message 2") }
        let encryptedStatic = try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
        state.mixKey(try MuseNoiseCrypto.dh(staticKey, remoteEphemeral))
        let encryptedPayload = try state.encryptAndHash(payload)
        return encryptedStatic + encryptedPayload
    }

    /// (send, receive)
    func split() -> (MuseNoiseCipher, MuseNoiseCipher) {
        state.split()
    }
}

/// The responder side, for tests (a fake VM).
struct MuseNoiseXXResponder: Sendable {
    private var state = MuseNoiseSymmetricState()
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let staticKey = Curve25519.KeyAgreement.PrivateKey()
    private var remoteEphemeral = Data()
    private let payload: Data

    init(payload: Data = Data()) {
        self.payload = payload
    }

    var handshakeHash: Data { state.handshakeHash }

    mutating func readMessage1AndWriteMessage2(_ message1: Data) throws(MuseNoiseError) -> Data {
        guard message1.count >= 32 else { throw MuseNoiseError("message 1 too short") }
        let bytes = Data(message1)
        remoteEphemeral = bytes.prefix(32)
        state.mixHash(remoteEphemeral)
        _ = try state.decryptAndHash(bytes.subdata(in: 32..<bytes.count))
        let e = ephemeral.publicKey.rawRepresentation
        state.mixHash(e)
        state.mixKey(try MuseNoiseCrypto.dh(ephemeral, remoteEphemeral))
        let encryptedStatic = try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
        state.mixKey(try MuseNoiseCrypto.dh(staticKey, remoteEphemeral))
        let encryptedPayload = try state.encryptAndHash(payload)
        return e + encryptedStatic + encryptedPayload
    }

    mutating func readMessage3(_ message3: Data) throws(MuseNoiseError) {
        let bytes = Data(message3)
        guard bytes.count >= 32 + 16 + 16 else { throw MuseNoiseError("message 3 too short") }
        let rs = try state.decryptAndHash(bytes.prefix(48))
        state.mixKey(try MuseNoiseCrypto.dh(ephemeral, rs))
        _ = try state.decryptAndHash(bytes.subdata(in: 48..<bytes.count))
    }

    /// (send, receive) — the mirror of the initiator's.
    func split() -> (MuseNoiseCipher, MuseNoiseCipher) {
        let (first, second) = state.split()
        return (second, first)
    }
}

/// The established session: request/stream frames out, response frames in. Stream ids are
/// assigned here, from 1.
struct MuseNoiseTransport: Sendable {
    private var send: MuseNoiseCipher
    private var receive: MuseNoiseCipher
    private var decoder = MuseNoiseFraming.Decoder()
    private var nextStreamID: Int64 = 1
    private(set) var dead = false

    init(send: MuseNoiseCipher, receive: MuseNoiseCipher) {
        self.send = send
        self.receive = receive
    }

    struct Encrypted {
        let streamID: Int64
        let frames: [Data]
    }

    /// Opens a stream with a request. `endBody: false` leaves its body open for `bodyChunk`s.
    mutating func request(
        _ verb: String, _ path: String, headers: [MuseHeader], body: Data = Data(), endBody: Bool
    ) throws -> Encrypted {
        let streamID = nextStreamID
        nextStreamID += 1
        let frame = MuseServiceFrame(
            streamID: streamID, kind: .request(verb: verb, path: path, headers: headers, body: body, endBody: endBody))
        return Encrypted(streamID: streamID, frames: try seal(frame))
    }

    mutating func bodyChunk(streamID: Int64, data: Data, endBody: Bool) throws -> [Data] {
        try seal(MuseServiceFrame(streamID: streamID, kind: .bodyChunk(data: data, endBody: endBody)))
    }

    mutating func reset(streamID: Int64, reason: String) throws -> [Data] {
        try seal(MuseServiceFrame(streamID: streamID, kind: .reset(code: MuseServiceFrame.resetCancelled, reason: reason)))
    }

    /// One received WebSocket message; `nil` while a multi-chunk envelope is still incomplete.
    mutating func open(_ ciphertext: Data) throws -> MuseServiceFrame? {
        guard !dead else { throw MuseNoiseError("transport dead after prior failure") }
        do {
            let plain = try receive.decrypt(ad: Data(), ciphertext: ciphertext)
            guard let envelope = try decoder.decode(plain) else { return nil }
            let payload = try MuseServiceEnvelope.decodeResponsePayload(envelope)
            guard !payload.isEmpty else { throw MuseNoiseError("empty ServiceResponse payload") }
            let frame = try MuseServiceFrame.decode(payload)
            if case .request? = frame.kind { throw MuseNoiseError("unexpected request frame from server") }
            return frame
        } catch {
            dead = true
            throw error
        }
    }

    private mutating func seal(_ frame: MuseServiceFrame) throws -> [Data] {
        guard !dead else { throw MuseNoiseError("transport dead after prior failure") }
        do {
            let envelope = MuseServiceEnvelope.encodeRequest(payload: frame.encoded())
            return try MuseNoiseFraming.encode(envelope).map { chunk throws(MuseNoiseError) in
                try send.encrypt(ad: Data(), plaintext: chunk)
            }
        } catch {
            dead = true
            throw error
        }
    }
}
