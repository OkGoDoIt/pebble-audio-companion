import CryptoKit
import Foundation
import Testing

@testable import MuseLink

// MARK: - Meta's published vectors

private struct VectorFile: Decodable {
    let vectors: [Vector]
}

private struct Vector: Decodable {
    let name: String
    let community: Bool
    let pairing_auth_epoch: Int
    let device_id: String
    let node_id: String
    let mac: String
    let firmware_version: String
    let pairing_policy: String
    let mobile_private_scalar_hex: String
    let device_private_scalar_hex: String
    let mobile_pub: String
    let device_pub: String
    let mobile_nonce: String
    let device_nonce: String
    let ecdh_secret_hex: String
    let transcript: String
    let transcript_hash: String
    let session_secret_hex: String
    let mobile_tx_key_hex: String
    let mobile_rx_key_hex: String
    let session_id: String
    let client_finished_plaintext: String
    let client_finished_aad: String
    let client_finished_ciphertext: String
    let client_finished_tag: String
}

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/link_pairing_v5", withExtension: "json"))
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite("Muse pairing v5 against Meta's vectors")
struct MusePairingVectorTests {
    @Test func transcriptAndHashMatch() throws {
        for vector in try loadVectors() {
            let transcript = try MusePairingSession.transcript(
                community: vector.community, authEpoch: vector.pairing_auth_epoch,
                policy: vector.pairing_policy, deviceID: vector.device_id, nodeID: vector.node_id,
                mac: vector.mac, firmwareVersion: vector.firmware_version,
                mobilePub: vector.mobile_pub, devicePub: vector.device_pub,
                mobileNonce: vector.mobile_nonce, deviceNonce: vector.device_nonce)
            #expect(transcript == vector.transcript, "\(vector.name)")
            let hash = MuseBase64URL.encode(Data(SHA256.hash(data: Data(transcript.utf8))))
            #expect(hash == vector.transcript_hash, "\(vector.name)")
        }
    }

    @Test func publicKeysAndECDHMatch() throws {
        for vector in try loadVectors() {
            let mobile = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.mobile_private_scalar_hex))
            let device = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.device_private_scalar_hex))
            #expect(MuseBase64URL.encode(mobile.publicKey.x963Representation) == vector.mobile_pub)
            #expect(MuseBase64URL.encode(device.publicKey.x963Representation) == vector.device_pub)
            let secret = try device.sharedSecretFromKeyAgreement(with: mobile.publicKey).withUnsafeBytes { Data($0) }
            #expect(secret.hex == vector.ecdh_secret_hex)
        }
    }

    @Test func keyScheduleMatches() throws {
        for vector in try loadVectors() {
            let keys = MusePairingSession.deriveSessionKeys(
                ecdhSecret: Data(hex: vector.ecdh_secret_hex),
                mobileNonce: try MuseBase64URL.decode(vector.mobile_nonce),
                deviceNonce: try MuseBase64URL.decode(vector.device_nonce),
                transcriptHash: try MuseBase64URL.decode(vector.transcript_hash))
            #expect(keys.sessionSecret.hex == vector.session_secret_hex, "\(vector.name)")
            #expect(keys.mobileTX.hex == vector.mobile_tx_key_hex, "\(vector.name)")
            #expect(keys.mobileRX.hex == vector.mobile_rx_key_hex, "\(vector.name)")
            #expect(MuseBase64URL.encode(keys.sessionID) == vector.session_id, "\(vector.name)")
        }
    }

    @Test func clientFinishedRecordOpens() throws {
        for vector in try loadVectors() {
            let aad = MusePairingSession.recordAAD(vector.session_id, direction: 0, counter: 0)
            #expect(String(decoding: aad, as: UTF8.self) == vector.client_finished_aad)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: MusePairingSession.recordNonce(direction: 0, counter: 0)),
                ciphertext: try MuseBase64URL.decode(vector.client_finished_ciphertext),
                tag: try MuseBase64URL.decode(vector.client_finished_tag))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: Data(hex: vector.mobile_tx_key_hex)), authenticating: aad)
            #expect(String(decoding: plain, as: UTF8.self) == vector.client_finished_plaintext)
        }
    }

    /// The session itself, driven with the vector's device key and nonce, produces the vector's
    /// `pairing_ready` and accepts its client-finished record.
    @Test func sessionReproducesConfirmAppVector() throws {
        let vector = try #require(try loadVectors().first { $0.pairing_policy == "confirm_app" })
        let identity = try #require(MuseGadgetIdentity(mac: vector.mac))
        #expect(identity.nodeID == vector.node_id)
        #expect(identity.deviceID == vector.device_id)
        let deviceScalar = Data(hex: vector.device_private_scalar_hex)
        let deviceNonce = try MuseBase64URL.decode(vector.device_nonce)
        var session = MusePairingSession(
            identity: identity, firmwareVersion: vector.firmware_version, sdkToken: "mgst_test",
            clock: { 0 },
            generateKey: { try! P256.KeyAgreement.PrivateKey(rawRepresentation: deviceScalar) },
            randomBytes: { _ in deviceNonce })
        let ready = try session.handleHello([
            "action": "pairing_client_hello", "version": 5, "pairing_auth": "none",
            "pairing_policy": "confirm_app", "mobile_pub": .string(vector.mobile_pub),
            "mobile_nonce": .string(vector.mobile_nonce),
        ])
        #expect(ready["transcript_hash"]?.string == vector.transcript_hash)
        #expect(ready["session_id"]?.string == vector.session_id)
        #expect(ready["device_pub"]?.string == vector.device_pub)
        let plaintext = try session.decrypt([
            "type": "pairing_encrypted", "session_id": .string(vector.session_id), "counter": "0",
            "ciphertext": .string(vector.client_finished_ciphertext), "tag": .string(vector.client_finished_tag),
        ])
        #expect(plaintext == vector.client_finished_plaintext)
        let generation = session.handleClientFinished(try #require(MuseJSON.parse(Data(plaintext.utf8))))
        #expect(generation != 0)
        let confirmed = session.isConfirmed()
        #expect(confirmed)
    }

    @Test func helloRejectsBooleanVersionAndWrongPolicy() {
        var session = MusePairingSession(
            identity: MuseGadgetIdentity(mac: "02:00:00:00:00:01")!, firmwareVersion: "1", sdkToken: nil)
        for hello: MuseJSON in [
            ["version": true, "pairing_auth": "none", "pairing_policy": "confirm_app"],
            ["version": 5, "pairing_auth": "none", "pairing_policy": "confirm_press"],
        ] {
            do {
                _ = try session.handleHello(hello)
                Issue.record("accepted \(hello.compactString())")
            } catch {
                #expect(error.status == "error_pairing_invalid_hello")
            }
        }
    }
}

// MARK: - Framing and identity

@Suite("Muse BLE framing and identity")
struct MuseFramingTests {
    @Test func roundTripsAcrossChunks() throws {
        let message = Data((0..<1000).map { UInt8($0 % 251) })
        let packets = try MuseBLEFraming.encode(message, mtu: 185)
        #expect(packets.allSatisfy { $0.count <= MuseBLEFraming.maxPacketBytes })
        var assembler = MuseChunkAssembler()
        var result: Data?
        for packet in packets { result = assembler.feed(packet) ?? result }
        #expect(result == message)
    }

    @Test func unframedPacketIsAWholeMessage() {
        var assembler = MuseChunkAssembler()
        let message = Data("{\"action\":\"get_device_info\"}".utf8)
        let result = assembler.feed(message)
        #expect(result == message)
    }

    @Test func outOfOrderChunkDiscards() throws {
        let packets = try MuseBLEFraming.encode(Data(repeating: 7, count: 400), mtu: 185)
        var assembler = MuseChunkAssembler()
        let results = [assembler.feed(packets[0]), assembler.feed(packets[2]), assembler.feed(packets[1])]
        #expect(results == [nil, nil, nil])  // the skip discarded the message
    }

    @Test func identityShapes() {
        let identity = MuseGadgetIdentity(mac: "02:ab:cd:ef:01:2a")!
        #expect(identity.nodeID == "homelink-ef012a")
        #expect(identity.bleName == "MuseGadgetEF012A")
        #expect(identity.deviceID == "hatch-link:02:ab:cd:ef:01:2a")
        let generated = MuseGadgetIdentity.generate()
        #expect(MuseGadgetIdentity(mac: generated.mac) != nil)
        let first = UInt8(generated.mac.prefix(2), radix: 16)!
        #expect(first & 0x03 == 0x02)
        #expect(MuseGadgetIdentity(mac: "02:AB:00:00:00:01") == nil)
    }
}

// MARK: - Full setup flow, with a simulated Muse app

private actor FakeTransport: MuseSetupTransport {
    private var assembler = MuseChunkAssembler()
    private var messages: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []
    private(set) var disconnects = 0

    func send(_ packet: Data) async {
        guard let message = assembler.feed(packet) else { return }
        if waiters.isEmpty {
            messages.append(message)
        } else {
            waiters.removeFirst().resume(returning: message)
        }
    }

    func disconnect(after delay: Duration) async { disconnects += 1 }

    func next() async -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private struct AlwaysOnline: MuseSetupNetwork {
    func isOnline() async -> Bool { true }
}

/// The phone side of pairing, as the Muse app does it.
private struct SimulatedMuseApp {
    let key = P256.KeyAgreement.PrivateKey()
    let nonce = MusePairingSession.secureRandomBytes(16)
    var txKey: SymmetricKey?
    var rxKey: SymmetricKey?
    var sessionID = ""
    var txCounter: UInt64 = 0
    var rxCounter: UInt64 = 0

    func hello() -> MuseJSON {
        [
            "action": "pairing_client_hello", "version": 5, "pairing_auth": "none",
            "pairing_policy": "confirm_app",
            "mobile_pub": .string(MuseBase64URL.encode(key.publicKey.x963Representation)),
            "mobile_nonce": .string(MuseBase64URL.encode(nonce)),
        ]
    }

    mutating func accept(ready: MuseJSON) throws {
        let devicePub = try MuseBase64URL.decode(ready["device_pub"])
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: devicePub)
        let secret = try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let transcript = try MusePairingSession.transcript(
            community: true, authEpoch: 0, policy: "confirm_app",
            deviceID: ready["device_id"]!.string!, nodeID: ready["node_id"]!.string!,
            mac: ready["mac"]!.string!, firmwareVersion: ready["firmware_version"]!.string!,
            mobilePub: MuseBase64URL.encode(key.publicKey.x963Representation),
            devicePub: ready["device_pub"]!.string!, mobileNonce: MuseBase64URL.encode(nonce),
            deviceNonce: ready["device_nonce"]!.string!)
        let hash = Data(SHA256.hash(data: Data(transcript.utf8)))
        #expect(MuseBase64URL.encode(hash) == ready["transcript_hash"]?.string)
        let keys = MusePairingSession.deriveSessionKeys(
            ecdhSecret: secret, mobileNonce: nonce,
            deviceNonce: try MuseBase64URL.decode(ready["device_nonce"]), transcriptHash: hash)
        txKey = SymmetricKey(data: keys.mobileTX)
        rxKey = SymmetricKey(data: keys.mobileRX)
        sessionID = MuseBase64URL.encode(keys.sessionID)
        #expect(sessionID == ready["session_id"]?.string)
    }

    mutating func seal(_ command: MuseJSON) throws -> MuseJSON {
        let counter = txCounter
        txCounter += 1
        let sealed = try AES.GCM.seal(
            command.compactData(), using: txKey!,
            nonce: AES.GCM.Nonce(data: MusePairingSession.recordNonce(direction: 0, counter: counter)),
            authenticating: MusePairingSession.recordAAD(sessionID, direction: 0, counter: counter))
        return [
            "action": "pairing_encrypted", "session_id": .string(sessionID), "counter": .string(String(counter)),
            "ciphertext": .string(MuseBase64URL.encode(sealed.ciphertext)), "tag": .string(MuseBase64URL.encode(sealed.tag)),
        ]
    }

    mutating func open(_ envelope: MuseJSON) throws -> MuseJSON {
        #expect(envelope["type"]?.string == "pairing_encrypted")
        #expect(envelope["counter"]?.string == String(rxCounter))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: MusePairingSession.recordNonce(direction: 1, counter: rxCounter)),
            ciphertext: try MuseBase64URL.decode(envelope["ciphertext"]), tag: try MuseBase64URL.decode(envelope["tag"]))
        let plain = try AES.GCM.open(
            box, using: rxKey!, authenticating: MusePairingSession.recordAAD(sessionID, direction: 1, counter: rxCounter))
        rxCounter += 1
        return try #require(MuseJSON.parse(plain))
    }
}

private final class PairedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MuseGadgetCredentials?
    func set(_ credentials: MuseGadgetCredentials) { lock.withLock { value = credentials } }
    var credentials: MuseGadgetCredentials? { lock.withLock { value } }
}

@Suite("Muse setup flow")
struct MuseSetupFlowTests {
    private func send(_ message: MuseJSON, to controller: MuseSetupController, mtu: Int = 185) throws {
        for packet in try MuseBLEFraming.encode(message.compactData(), mtu: mtu) {
            controller.receive(packet)
        }
    }

    @Test func pairsAndProvisions() async throws {
        let identity = MuseGadgetIdentity.generate()
        let transport = FakeTransport()
        let paired = PairedBox()
        let controller = MuseSetupController(
            identity: identity, firmwareVersion: "0.1.0", sdkToken: "mgst_example",
            transport: transport, network: AlwaysOnline(),
            verify: { credentials throws(MuseProvisionFailure) in
                if credentials.accessToken != "access-1" { throw MuseProvisionFailure("auth_failed") }
            },
            onPaired: { credentials in paired.set(credentials); return true })
        let runner = Task { await controller.run() }
        defer { runner.cancel() }

        try send(["action": "get_device_info"], to: controller)
        let info = try #require(MuseJSON.parse(await transport.next()))
        #expect(info["type"]?.string == "device_info")
        #expect(info["node_id"]?.string == identity.nodeID)
        #expect(info["pairing_protocol"]?.number == 5)
        #expect(info["pairing_policy"]?.string == "confirm_app")

        var app = SimulatedMuseApp()
        try send(app.hello(), to: controller)
        let ready = try #require(MuseJSON.parse(await transport.next()))
        #expect(ready["type"]?.string == "pairing_ready")
        try app.accept(ready: ready)

        try send(try app.seal(["action": "pairing_client_finished"]), to: controller)
        let confirmed = try app.open(try #require(MuseJSON.parse(await transport.next())))
        #expect(confirmed["status"]?.string == "pairing_confirmed")
        #expect(confirmed["sdk_token"]?.string == "mgst_example")

        try send(try app.seal(["action": "wifi_scan"]), to: controller)
        let scan = try app.open(try #require(MuseJSON.parse(await transport.next())))
        #expect(scan["type"]?.string == "wifi_scan_result")
        #expect(scan["networks"]?.array?.first?["secure"]?.bool == false)

        try send(
            try app.seal([
                "action": "provision_v2", "ssid": "Use current connection", "password": "",
                "access_token": "access-1", "refresh_token": "refresh-1", "token_type": "device",
                "username": "roger", "api_url_v2": "https://api.muse.ai", "noise_host": "hatch.metaaivm.com",
            ]), to: controller)
        var statuses: [String] = []
        while statuses.last != "auth_ok" && statuses.count < 5 {
            statuses.append(try app.open(try #require(MuseJSON.parse(await transport.next())))["status"]?.string ?? "?")
        }
        #expect(statuses == ["wifi_connecting", "wifi_connected", "auth_ok"])
        let credentials = try #require(paired.credentials)
        #expect(credentials.identity == identity)
        #expect(credentials.refreshToken == "refresh-1")
        #expect(credentials.noiseHost == "hatch.metaaivm.com")
        #expect(await controller.isComplete)
    }

    @Test func badTokenFailsWithAuthFailed() async throws {
        let transport = FakeTransport()
        let controller = MuseSetupController(
            identity: MuseGadgetIdentity.generate(), firmwareVersion: "0.1.0", sdkToken: nil,
            transport: transport, network: AlwaysOnline(),
            verify: { _ throws(MuseProvisionFailure) in throw MuseProvisionFailure("auth_failed") },
            onPaired: { _ in Issue.record("must not persist"); return true })
        let runner = Task { await controller.run() }
        defer { runner.cancel() }

        var app = SimulatedMuseApp()
        try send(app.hello(), to: controller)
        try app.accept(ready: try #require(MuseJSON.parse(await transport.next())))
        try send(try app.seal(["action": "pairing_client_finished"]), to: controller)
        _ = try app.open(try #require(MuseJSON.parse(await transport.next())))
        try send(
            try app.seal([
                "action": "provision_v2", "ssid": "x", "password": "", "access_token": "bad",
                "refresh_token": "r", "token_type": "device",
            ]), to: controller)
        var statuses: [String] = []
        while statuses.last != "auth_failed" && statuses.count < 5 {
            statuses.append(try app.open(try #require(MuseJSON.parse(await transport.next())))["status"]?.string ?? "?")
        }
        #expect(statuses == ["wifi_connecting", "wifi_connected", "auth_failed"])
        #expect(await controller.isComplete == false)
    }

    @Test func sensitivePlaintextIsRefused() async throws {
        let transport = FakeTransport()
        let controller = MuseSetupController(
            identity: MuseGadgetIdentity.generate(), firmwareVersion: "0.1.0", sdkToken: nil,
            transport: transport, network: AlwaysOnline(),
            verify: { _ throws(MuseProvisionFailure) in }, onPaired: { _ in true })
        let runner = Task { await controller.run() }
        defer { runner.cancel() }
        try send(["action": "provision_v2", "access_token": "a"], to: controller)
        #expect(String(decoding: await transport.next(), as: UTF8.self) == "error_encryption_required")
    }
}
