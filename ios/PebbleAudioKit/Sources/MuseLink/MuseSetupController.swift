import Foundation
import os

/// Where the gadget's setup bytes physically go: a Mac's CoreBluetooth peripheral during
/// development, or — the product — the watch, which hosts the setup GATT service and relays the
/// characteristic values to the phone. Values are raw characteristic values in both directions;
/// framing and crypto live in `MuseSetupController`.
public protocol MuseSetupTransport: Sendable {
    /// Notifies one packet on the TX characteristic. Returns once it is queued.
    func send(_ packet: Data) async
    /// Ends the setup client's connection after `delay`, where the transport can. The watch relay
    /// must not: the phone's link to the watch is shared with the official Pebble app.
    func disconnect(after delay: Duration) async
}

/// What setup needs to know about connectivity. A gadget on the phone is online whenever the
/// phone is; the Wi-Fi details the Muse app sends are deliberately ignored, exactly as Meta's Linux
/// gadget does when it is already on a network.
public protocol MuseSetupNetwork: Sendable {
    func isOnline() async -> Bool
}

/// The credentials a successful pairing produces, in the shape Meta's Linux gadget stores in
/// `pairing.json` (plus the identity, which it keeps in `identity.json`).
public struct MuseGadgetCredentials: Codable, Sendable, Equatable {
    public var identity: MuseGadgetIdentity
    public var accessToken: String
    public var refreshToken: String
    public var username: String
    /// Legacy; only older firmware reads it. Kept so an export round-trips.
    public var apiURL: String
    /// The API root, or empty for `https://api.muse.ai`.
    public var apiURLv2: String
    public var noiseHost: String
    public var accessTokenSavedAt: Date

    public init(
        identity: MuseGadgetIdentity, accessToken: String, refreshToken: String, username: String,
        apiURL: String, apiURLv2: String, noiseHost: String, accessTokenSavedAt: Date
    ) {
        self.identity = identity
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.username = username
        self.apiURL = apiURL
        self.apiURLv2 = apiURLv2
        self.noiseHost = noiseHost
        self.accessTokenSavedAt = accessTokenSavedAt
    }

    public var apiRoot: URL { MuseDeviceAPI.apiRoot(apiURLv2: apiURLv2) }
}

/// Setup could not finish; `status` is what the Muse app is told.
public struct MuseProvisionFailure: Error, Equatable, Sendable {
    public let status: String
    public init(_ status: String) { self.status = status }
}

/// The BLE setup protocol behind the two setup characteristics — a port of Meta's
/// `linux/src/musegadget/ble_setup.py` (Apache-2.0), one setup client at a time.
///
/// Packets are handled strictly in arrival order (`receive` only enqueues), and every outgoing
/// message is encrypted and queued inside the actor, so encrypted record counters reach the phone
/// in order even while provisioning runs concurrently.
public actor MuseSetupController {
    public enum Event: Sendable {
        case packet(Data)
        case clientDisconnected
    }

    static let sensitiveActions: Set<String> = [
        "provision", "provision_v2", "wifi_scan", "ota", "device.ota", "unpair", "set_wifi", "set_auth",
    ]
    static let plaintextStatuses: Set<String> = [
        "error_encryption_required", "error_pairing_invalid_hello",
        "error_pairing_unavailable", "error_pairing_decrypt",
    ]
    static let disconnectAfterError: Duration = .milliseconds(300)
    /// Offered as the only "Wi-Fi network": marked open so the app skips the password field.
    public static let currentConnectionLabel = "Use current connection"

    private let identity: MuseGadgetIdentity
    private let firmwareVersion: String
    private let transport: any MuseSetupTransport
    private let network: any MuseSetupNetwork
    private let verify: @Sendable (MuseGadgetCredentials) async throws(MuseProvisionFailure) -> Void
    private let onPaired: @Sendable (MuseGadgetCredentials) async -> Bool
    private let trace: (@Sendable (String) -> Void)?
    private let log = Logger(subsystem: "dev.audiocompanion.muselink", category: "setup")

    private var pairing: MusePairingSession
    private var assembler = MuseChunkAssembler()
    private var plaintextBlocked = false
    private var provisioning = false
    private var networkReady = true
    /// Current notification payload limit; the transport reports it once known. Phones running
    /// the Muse app negotiate at least enough for full 160-byte packets, which is what Meta's
    /// Linux gadget assumes until told otherwise.
    private var mtu = MuseBLEFraming.maxPacketBytes + 3

    private let inbox: AsyncStream<Event>
    private let inboxContinuation: AsyncStream<Event>.Continuation
    private let outbox: AsyncStream<[Data]>
    private let outboxContinuation: AsyncStream<[Data]>.Continuation
    private var completed = false

    /// - Parameters:
    ///   - verify: checks the provisioned device token works (Meta's gadget fetches its VMs), and
    ///     throws `auth_failed` if not.
    ///   - onPaired: persists the credentials; returns false if it couldn't.
    ///   - trace: receives every protocol step as a line of text (developer tools); never tokens.
    public init(
        identity: MuseGadgetIdentity,
        firmwareVersion: String,
        sdkToken: String?,
        transport: any MuseSetupTransport,
        network: any MuseSetupNetwork,
        verify: @escaping @Sendable (MuseGadgetCredentials) async throws(MuseProvisionFailure) -> Void,
        onPaired: @escaping @Sendable (MuseGadgetCredentials) async -> Bool,
        pairing: MusePairingSession? = nil,
        trace: (@Sendable (String) -> Void)? = nil
    ) {
        self.trace = trace
        self.identity = identity
        self.firmwareVersion = firmwareVersion
        self.transport = transport
        self.network = network
        self.verify = verify
        self.onPaired = onPaired
        self.pairing = pairing
            ?? MusePairingSession(identity: identity, firmwareVersion: firmwareVersion, sdkToken: sdkToken)
        (inbox, inboxContinuation) = AsyncStream.makeStream(of: Event.self)
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: [Data].self)
    }

    /// Whether a pairing has completed (`auth_ok` sent) on this controller.
    public var isComplete: Bool { completed }

    // MARK: - Transport callbacks (any context)

    public nonisolated func receive(_ packet: Data) {
        inboxContinuation.yield(.packet(packet))
    }

    public nonisolated func clientDisconnected() {
        inboxContinuation.yield(.clientDisconnected)
    }

    public func updateMTU(_ mtu: Int) {
        self.mtu = mtu
    }

    // MARK: - Lifecycle

    /// Processes setup traffic until `stop()`. Run it in its own task.
    public func run() async {
        networkReady = await network.isOnline()
        let transport = self.transport
        let outbox = self.outbox
        let sender = Task {
            for await packets in outbox {
                for (index, packet) in packets.enumerated() {
                    if index > 0 { try? await Task.sleep(for: MuseBLEFraming.chunkStagger) }
                    await transport.send(packet)
                }
            }
        }
        for await event in inbox {
            switch event {
            case .packet(let packet):
                if let message = assembler.feed(packet) {
                    handleMessage(message, decrypted: false)
                }
            case .clientDisconnected:
                note("setup client disconnected; clearing pairing session")
                assembler.reset()
                plaintextBlocked = false
                pairing.reset()
            }
        }
        outboxContinuation.finish()
        await sender.value
    }

    public func stop() {
        inboxContinuation.finish()
    }

    // MARK: - Dispatch

    func handleMessage(_ raw: Data, decrypted: Bool) {
        guard let command = MuseJSON.parse(raw), command.object != nil else {
            note("invalid command JSON (\(raw.count) bytes)")
            sendStatus("error_invalid_command")
            return
        }
        let action = command["action"]?.string ?? ""
        note("RX action: \(action.isEmpty ? "?" : action)\(decrypted ? " (encrypted)" : "")")

        if !decrypted, action == "pairing_client_hello" {
            handleHello(command)
        } else if !decrypted, action == "pairing_encrypted" {
            handleRecord(command)
        } else if action == "get_device_info" {
            // Public metadata, safe in plaintext at any point. Apps re-read it when they restart a
            // handshake on the same connection.
            sendJSON(deviceInfo())
        } else if !decrypted, plaintextBlocked {
            note("plaintext command ignored after pairing started: \(action)")
        } else if !decrypted, Self.sensitiveActions.contains(action) {
            sendStatus("error_encryption_required")
        } else if decrypted, action == "pairing_client_finished" {
            handleClientFinished(command)
        } else if decrypted, Self.sensitiveActions.contains(action), !pairing.isConfirmed() {
            sendStatus("error_pairing_confirm_required")
        } else if decrypted, action == "wifi_scan" {
            let networks: [MuseJSON] = networkReady
                ? [["ssid": .string(Self.currentConnectionLabel), "rssi": -40, "secure": false]] : []
            sendEncryptedJSON(["type": "wifi_scan_result", "networks": .array(networks)])
        } else if decrypted, action == "provision_v2" {
            handleProvision(command)
        } else {
            sendStatus("error_unknown_action")
        }
    }

    func deviceInfo() -> MuseJSON {
        var info = pairing.deviceInfoFields
        info["type"] = "device_info"
        info["node_id"] = .string(identity.nodeID)
        info["version"] = .string(firmwareVersion)
        info["build_sha"] = ""
        info["network_ready"] = .bool(networkReady)
        return .object(info)
    }

    private func handleHello(_ command: MuseJSON) {
        do {
            let ready = try pairing.handleHello(command)
            plaintextBlocked = true
            sendJSON(ready)
        } catch {
            sendStatus(error.status)
        }
    }

    private func handleRecord(_ envelope: MuseJSON) {
        do {
            let plaintext = try pairing.decrypt(envelope)
            handleMessage(Data(plaintext.utf8), decrypted: true)
        } catch {
            sendStatus(error.status)
            disconnectSoon(Self.disconnectAfterError)
        }
    }

    private func handleClientFinished(_ command: MuseJSON) {
        let generation = pairing.handleClientFinished(command)
        guard generation != 0 else {
            sendStatus(MusePairingSession.errorDecrypt)
            disconnectSoon(Self.disconnectAfterError)
            return
        }
        note("pairing confirmed (app consent)")
        sendStatus("pairing_confirmed", generation: generation)
    }

    private func handleProvision(_ command: MuseJSON) {
        func text(_ key: String) -> String { command[key]?.string ?? "" }
        guard command["ssid"]?.string != nil, command["password"]?.string != nil,
            !text("access_token").isEmpty, !text("refresh_token").isEmpty,
            text("token_type") == "device"
        else {
            sendStatus("error_missing_credentials")
            return
        }
        if provisioning {
            sendStatus("error_operation_in_progress")
            return
        }
        let generation = pairing.markProvisioning()
        guard generation != 0 else {
            sendStatus("error_pairing_confirm_required")
            return
        }
        provisioning = true
        // Only https roots are honoured, as in Meta's gadget; anything else falls back to the
        // default API.
        let https: (String) -> String = { $0.hasPrefix("https://") ? $0 : "" }
        let credentials = MuseGadgetCredentials(
            identity: identity, accessToken: text("access_token"), refreshToken: text("refresh_token"),
            username: text("username"), apiURL: https(text("api_url")), apiURLv2: https(text("api_url_v2")),
            noiseHost: text("noise_host"), accessTokenSavedAt: Date())
        Task { await runProvision(credentials, generation: generation) }
    }

    private func runProvision(_ credentials: MuseGadgetCredentials, generation: Int) async {
        defer { provisioning = false }
        sendStatus("wifi_connecting", generation: generation)
        networkReady = await network.isOnline()
        guard networkReady else {
            // Stay in provisioning so the app can retry, as the firmware does.
            _ = pairing.extendProvisioning(generation)
            sendStatus("wifi_failed", generation: generation)
            return
        }
        sendStatus("wifi_connected", generation: generation)
        do {
            try await verify(credentials)
        } catch {
            note("provisioning failed: \(error.status)")
            sendStatus(error.status, generation: generation)
            disconnectSoon(.milliseconds(500))
            return
        }
        guard pairing.isProvisioning(generation), await onPaired(credentials) else {
            sendStatus("error_storage", generation: generation)
            disconnectSoon(.milliseconds(500))
            return
        }
        completed = true
        sendStatus("auth_ok", generation: generation)
        note("setup complete")
    }

    private func note(_ message: String) {
        log.info("\(message, privacy: .public)")
        trace?(message)
    }

    private func disconnectSoon(_ delay: Duration) {
        let transport = self.transport
        Task { await transport.disconnect(after: delay) }
    }

    // MARK: - Sending (all queued in call order)

    func sendStatus(_ status: String, generation: Int = 0) {
        if let envelope = pairing.encryptStatus(status, generation: generation) {
            enqueue(envelope.compactString())
            note("TX status (encrypted #\(envelope["counter"]?.string ?? "?")): \(status)")
            return
        }
        guard generation == 0, !plaintextBlocked, Self.plaintextStatuses.contains(status) else {
            note("TX status suppressed: \(status)")
            return
        }
        // Plaintext statuses go out unframed.
        outboxContinuation.yield([Data(status.utf8)])
        note("TX status: \(status)")
    }

    func sendJSON(_ message: MuseJSON) {
        enqueue(message.compactString())
        note("TX \(message["type"]?.string ?? "?")")
    }

    func sendEncryptedJSON(_ message: MuseJSON, generation: Int = 0) {
        guard let envelope = pairing.encrypt(message.compactString(), generation: generation) else {
            note("TX \(message["type"]?.string ?? "?") suppressed: no session")
            return
        }
        enqueue(envelope.compactString())
    }

    private func enqueue(_ text: String) {
        do {
            outboxContinuation.yield(try MuseBLEFraming.encode(Data(text.utf8), mtu: mtu))
        } catch {
            note("TX dropped: message needs too many chunks")
        }
    }
}

/// `MuseSetupNetwork` for a phone or Mac: online when the Muse API host answers HTTPS.
public struct MuseHTTPSReachability: MuseSetupNetwork {
    public init() {}

    public func isOnline() async -> Bool {
        var request = URLRequest(url: MuseDeviceAPI.defaultAPIRoot, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        // Any HTTP answer, whatever the status, means the host is reachable.
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}
