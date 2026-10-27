import Foundation
import MuseLink
import Receiver
import WireProtocol

/// Muse, through the watch.
///
/// The app is the Muse gadget. Pairing needs the Muse app to find a gadget over Bluetooth, and
/// the watch provides that: on request it opens a short window, hosts Muse's setup service on a
/// private second link, and relays every value to this service, which runs the setup protocol
/// (`MuseSetupController`) and keeps the device tokens the Muse app hands over. After that the
/// watch is not involved: asking Muse is an HTTPS + WebSocket exchange from the phone.
public actor MuseGadgetService {
    public enum PairingState: Equatable, Sendable {
        case idle
        /// Asking the watch to open a window.
        case starting
        /// The watch is asking its wearer.
        case confirmOnWatch
        /// The watch is advertising as `gadgetName`; the Muse app has not connected yet.
        case waitingForMuse(gadgetName: String, secondsLeft: Int)
        /// The Muse app is connected and setting the gadget up.
        case museConnected(gadgetName: String)
        case paired
        case failed(PairingFailure)

        public var isActive: Bool {
            switch self {
            case .starting, .confirmOnWatch, .waitingForMuse, .museConnected: return true
            case .idle, .paired, .failed: return false
            }
        }
    }

    public enum PairingFailure: Equatable, Sendable {
        /// No authorized watch on the line.
        case watchNotConnected
        /// The watch's firmware cannot host the window.
        case watchNeedsUpdate
        /// The window ended without the Muse app connecting.
        case timedOut
        /// The Muse app connected but setup did not complete.
        case didNotFinish
        /// The watch could not start advertising.
        case couldNotStart
    }

    public enum AskFailure: Error, Equatable, Sendable {
        case notPaired
    }

    /// How long the watch keeps a window open.
    public static let windowSeconds = 300

    /// Whether questions can be asked from the watch (push-to-talk). The setup screen's
    /// description and the privacy model's `MuseState.spokenQuestions` follow it.
    public static let asksFromWatch = true

    /// The version this gadget reports to Muse. Fixed, so nothing about the watch or its firmware
    /// goes to Meta (docs/privacy-model.md, D7).
    public static let gadgetVersion = "1.0.0"

    public nonisolated let pairing = StateSubject<PairingState>(.idle)
    /// The name the Muse app lists this gadget under, nil until paired.
    public nonisolated let pairedName: StateSubject<String?>
    public nonisolated let hasSDKToken: StateSubject<Bool>
    public nonisolated let reconnectRequired: StateSubject<Bool>

    private let link: any MuseWatchLink
    private let secrets: any MuseSecrets
    private let api: MuseDeviceAPI
    private let credentials: MuseCredentialStore
    private let network: any MuseSetupNetwork
    private let log: @Sendable (String) -> Void

    private var attempt: Attempt?
    private var attemptCounter = 0

    /// One pairing window, from the OPEN request to the watch's Closed event.
    private final class Attempt {
        let id: Int
        let identity: MuseGadgetIdentity
        let inbound: AsyncStream<AudioReceiverSession.MuseSetupInbound>.Continuation
        var assembler = MuseRxAssembler()
        var controller: MuseSetupController?
        var controllerTask: Task<Void, Never>?
        var loop: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var museConnected = false
        var provisioned = false
        var closeRequested = false
        /// A CLOSE sent to clear a window an earlier attempt left open; its Closed is not ours.
        var staleCloses = 0

        init(id: Int, identity: MuseGadgetIdentity, inbound: AsyncStream<AudioReceiverSession.MuseSetupInbound>.Continuation) {
            self.id = id
            self.identity = identity
            self.inbound = inbound
        }
    }

    public init(
        link: any MuseWatchLink,
        secrets: any MuseSecrets = KeychainMuseSecrets(),
        api: MuseDeviceAPI = MuseDeviceAPI(),
        network: any MuseSetupNetwork = MuseHTTPSReachability(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.link = link
        self.secrets = secrets
        self.api = api
        self.network = network
        self.log = log
        let credentials = MuseCredentialStore(secrets: secrets, api: api, log: log)
        self.credentials = credentials
        pairedName = credentials.pairedName
        reconnectRequired = credentials.reconnectRequired
        hasSDKToken = StateSubject(secrets.sdkToken() != nil)
    }

    // MARK: - Settings

    public func setSDKToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.setSDKToken(trimmed)
        hasSDKToken.value = secrets.sdkToken() != nil
    }

    /// Drops the device tokens. The identity stays, so pairing again shows up in the Muse app as
    /// the same gadget.
    public func forget() async {
        guard await credentials.forget() else {
            log("Muse pairing: could not remove saved credentials")
            return
        }
        if !pairing.value.isActive { pairing.value = .idle }
    }

    /// Whether the watch on the line says it can host the window. Nil before its Info is read.
    public nonisolated var watchCanPair: Bool? {
        link.watchCapabilities.map { $0 & ProtocolConstants.capabilityMuseSetup != 0 }
    }

    // MARK: - Pairing

    public func startPairing() async {
        guard !pairing.value.isActive else { return }
        guard let capabilities = link.watchCapabilities else {
            pairing.value = .failed(.watchNotConnected)
            return
        }
        guard capabilities & ProtocolConstants.capabilityMuseSetup != 0 else {
            pairing.value = .failed(.watchNeedsUpdate)
            return
        }
        pairing.value = .starting

        attemptCounter += 1
        let identity = secrets.loadOrCreateIdentity()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioReceiverSession.MuseSetupInbound.self)
        let current = Attempt(id: attemptCounter, identity: identity, inbound: continuation)
        attempt = current
        let attemptID = current.id
        await link.setMuseSetupHandler { continuation.yield($0) }
        current.loop = Task { await self.consume(stream, attemptID: attemptID) }

        let suffix = identity.suffix.uppercased()
        let open: @Sendable (Int) -> [UInt8] = { token in
            MuseSetupOpen(requestToken: token, windowSeconds: Self.windowSeconds, suffix: suffix).encode()
        }
        var reply = await link.sendMuseSetup(open)
        if reply == .badState {
            // A window an earlier attempt lost track of is still open on the watch.
            log("Muse pairing: clearing a window left open")
            current.staleCloses += 1
            _ = await link.sendMuseSetup { MuseSetupClose(requestToken: $0, reason: .cancelled).encode() }
            reply = await link.sendMuseSetup(open)
        }
        guard attempt === current else { return }
        log("Muse pairing: open as \(identity.bleName) → \(reply)")
        switch reply {
        case .ok:
            pairing.value = .confirmOnWatch
            // The watch reports how the window ends; if the link drops, nothing will.
            current.watchdog = Task {
                try? await Task.sleep(for: .seconds(Self.windowSeconds + 120))
                await self.giveUp(attemptID: attemptID)
            }
        case .notSent, .noAnswer:
            await finish(current, .failed(.watchNotConnected))
        default:
            await finish(current, .failed(.couldNotStart))
        }
    }

    /// Ends the window from the app.
    public func cancelPairing() async {
        guard let current = attempt, pairing.value.isActive else { return }
        current.closeRequested = true
        let reply = await link.sendMuseSetup { MuseSetupClose(requestToken: $0, reason: .cancelled).encode() }
        // Without the watch there is no Closed event to wait for.
        if reply != .ok, attempt === current { await finish(current, .idle) }
    }

    private func consume(_ stream: AsyncStream<AudioReceiverSession.MuseSetupInbound>, attemptID: Int) async {
        for await inbound in stream {
            guard let current = attempt, current.id == attemptID else { return }
            switch inbound {
            case .rx(let rx):
                switch current.assembler.feed(rx) {
                case .value(let value): current.controller?.receive(value)
                case .incomplete: break
                case .lost: await lostSetupTraffic(current)
                }
            case .event(let event):
                await handle(event, current)
            }
        }
    }

    private func handle(_ event: MuseSetupEvent, _ current: Attempt) async {
        let name = current.identity.bleName
        switch event.event {
        case .opened:
            log("Muse pairing: watch advertising as \(name) for \(event.secondsLeft) s")
            startController(current)
            pairing.value = .waitingForMuse(gadgetName: name, secondsLeft: event.secondsLeft)
        case .clientConnected:
            log("Muse pairing: Muse app connected (MTU \(event.mtu))")
            current.museConnected = true
            if event.mtu > 0 { await current.controller?.updateMTU(event.mtu) }
            pairing.value = .museConnected(gadgetName: name)
        case .mtu:
            if event.mtu > 0 { await current.controller?.updateMTU(event.mtu) }
        case .subscribed:
            log("Muse pairing: Muse app \(event.detail == 1 ? "subscribed" : "unsubscribed")")
        case .clientDisconnected:
            log("Muse pairing: Muse app disconnected (HCI 0x\(String(event.detail, radix: 16)))")
            current.assembler.reset()
            current.controller?.clientDisconnected()
            if current.provisioned {
                await closeWindow(current, reason: .paired)
            } else if pairing.value.isActive {
                pairing.value = .waitingForMuse(gadgetName: name, secondsLeft: event.secondsLeft)
            }
        case .rxOverflow:
            log("Muse pairing: watch dropped \(event.detail) value(s)")
            await lostSetupTraffic(current)
        case .closed:
            let reason = event.closeReason
            if reason == .appCancelled, current.staleCloses > 0, !current.closeRequested {
                current.staleCloses -= 1
                return
            }
            log("Muse pairing: window closed (\(reason.map { "\($0)" } ?? "\(event.detail)"))")
            await finish(current, outcome(for: reason, current))
        case nil:
            break
        }
    }

    private func outcome(for reason: MuseSetupCloseReason?, _ current: Attempt) -> PairingState {
        if current.provisioned { return .paired }
        switch reason {
        case .appCancelled, .declinedOnWatch, .cancelledOnWatch:
            return .idle
        case .timeout:
            return .failed(current.museConnected ? .didNotFinish : .timedOut)
        case .phoneLinkLost, .receiverGone:
            return .failed(.watchNotConnected)
        case .couldNotStart:
            return .failed(.couldNotStart)
        case .appPaired, .appFailed, nil:
            return .failed(.didNotFinish)
        }
    }

    private func startController(_ current: Attempt) {
        guard current.controller == nil else { return }
        let api = self.api
        let log = self.log
        let attemptID = current.id
        let controller = MuseSetupController(
            identity: current.identity,
            firmwareVersion: Self.gadgetVersion,
            sdkToken: secrets.sdkToken(),
            transport: WatchMuseSetupTransport(link: link, log: log),
            network: network,
            verify: { credentials throws(MuseProvisionFailure) in
                // What Meta's gadget does: the tokens are good if they lease a VM.
                do {
                    let vms = try await api.fetchVMs(accessToken: credentials.accessToken, apiRoot: credentials.apiRoot)
                    log("Muse pairing: device token works, \(vms.count) VM(s)")
                    if vms.isEmpty { throw MuseProvisionFailure("auth_failed") }
                } catch let failure as MuseProvisionFailure {
                    throw failure
                } catch {
                    log("Muse pairing: device token check failed: \(error)")
                    throw MuseProvisionFailure("auth_failed")
                }
            },
            onPaired: { [weak self] credentials in
                await self?.provisioned(credentials, attemptID: attemptID) ?? false
            },
            trace: { log("Muse setup: \($0)") }
        )
        current.controller = controller
        current.controllerTask = Task { await controller.run() }
    }

    /// The Muse app provisioned the gadget and the tokens work.
    private func provisioned(_ credentials: MuseGadgetCredentials, attemptID: Int) async -> Bool {
        guard let current = attempt, current.id == attemptID else { return false }
        guard await self.credentials.replace(with: credentials) else {
            log("Muse pairing: could not save the device tokens")
            return false
        }
        guard attempt === current else { return false }
        current.provisioned = true
        // auth_ok goes out after this returns. The Muse app usually hangs up on its own; if it
        // doesn't, close the window once the reply has had time to reach it.
        Task {
            try? await Task.sleep(for: .seconds(4))
            await self.closeAfterPairing(attemptID: attemptID)
        }
        return true
    }

    private func closeAfterPairing(attemptID: Int) async {
        guard let current = attempt, current.id == attemptID, current.provisioned else { return }
        await closeWindow(current, reason: .paired)
    }

    private func closeWindow(_ current: Attempt, reason: MuseSetupAppCloseReason) async {
        guard !current.closeRequested else { return }
        current.closeRequested = true
        let reply = await link.sendMuseSetup { MuseSetupClose(requestToken: $0, reason: reason).encode() }
        if reply != .ok, attempt === current {
            await finish(current, current.provisioned ? .paired : .failed(.didNotFinish))
        }
    }

    /// Part of the setup exchange went missing: start it over on a fresh link.
    private func lostSetupTraffic(_ current: Attempt) async {
        current.assembler.reset()
        current.controller?.clientDisconnected()
        let reply = await link.sendMuseSetup { MuseSetupDisconnect(requestToken: $0, delayMs: 0).encode() }
        log("Muse pairing: setup traffic lost; asked the watch to drop the Muse app's link (\(reply))")
    }

    private func giveUp(attemptID: Int) async {
        guard let current = attempt, current.id == attemptID else { return }
        log("Muse pairing: no word from the watch; giving up")
        await finish(current, current.provisioned ? .paired : .failed(.watchNotConnected))
    }

    private func finish(_ current: Attempt, _ state: PairingState) async {
        guard attempt === current else { return }
        attempt = nil
        current.watchdog?.cancel()
        await current.controller?.stop()
        current.inbound.finish()
        await link.setMuseSetupHandler(nil)
        pairing.value = state
    }

    // MARK: - Asking

    /// Sends `message` to Muse as this gadget and returns its answer.
    public func ask(_ message: String, trace: (@Sendable (String) -> Void)? = nil) async throws -> MuseAsk.Answer {
        return try await MuseAsk(api: api).ask(
            message, credentials: credentials,
            trace: trace)
    }
}

// MARK: - Asking out loud

extension MuseGadgetService: MuseVoiceConnector {
    public nonisolated var isPaired: Bool { pairedName.value != nil }

    /// A link for questions asked on the watch. With `commands`, the gadget registers them so
    /// Muse can act on the watch; if Muse won't take the registration, the link opens without.
    public func open(
        chatID: String?, commands: MuseJSON, handler: @escaping MuseLinkSession.CommandHandler
    ) async throws(MuseQuestionFailure) -> any MuseVoiceConversation {
        guard let saved = secrets.credentials(), isPaired else { throw .notSetUp }
        let credentials = self.credentials
        let log = self.log
        let ask = MuseAsk(api: api)
        let identity = saved.identity
        let device = (commands.object?.isEmpty ?? true)
            ? nil
            : MuseLinkSession.Device(
                nodeID: identity.nodeID, displayName: identity.bleName, version: Self.gadgetVersion,
                commands: commands)
        func attempt(_ device: MuseLinkSession.Device?) async throws -> MuseLinkSession {
            try await ask.openSession(
                credentials: credentials, device: device,
                commandHandler: device == nil ? nil : handler,
                trace: { log("Muse voice: \($0)") })
        }
        do {
            let session: MuseLinkSession
            do {
                session = try await attempt(device)
            } catch let failure as MuseLinkSession.Failure where device != nil {
                log("Muse voice: registering the watch's actions failed (\(failure)); asking without them")
                session = try await attempt(nil)
            }
            return LiveMuseVoiceConversation(session: session, chatID: chatID, trace: { log("Muse voice: \($0)") })
        } catch let failure as MuseQuestionFailure {
            throw failure
        } catch MuseAsk.Failure.noVM {
            throw .notSetUp
        } catch let failure as MuseCredentialStore.Failure {
            log("Muse voice: credentials unavailable: \(failure)")
            throw failure == .couldNotSave ? .unreachable : .notSetUp
        } catch let failure as MuseDeviceAPI.Failure {
            log("Muse voice: device API failed: \(failure)")
            if case .http(let status) = failure, [400, 401, 403].contains(status) { throw .notSetUp }
            throw .unreachable
        } catch {
            log("Muse voice: could not reach Muse: \(error)")
            throw .unreachable
        }
    }
}

