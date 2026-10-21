import Foundation

/// One question to Muse as this gadget, answered as text: rotate the device token if it's due,
/// lease a VM, open a chat-only link, send the message and follow the turn to its end.
///
/// The same steps `muse-dev turn` runs, packaged for the app.
public struct MuseAsk: Sendable {
    public struct Answer: Sendable, Equatable {
        public let text: String
        /// False when the deadline passed before Muse said it was done; `text` is what arrived.
        public let complete: Bool
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The account leased no VM to this gadget.
        case noVM
        /// Muse refused the message (HTTP status).
        case refused(Int)
    }

    private let api: MuseDeviceAPI
    private let sdkToken: String?
    private let userAgent: String

    public init(api: MuseDeviceAPI = MuseDeviceAPI(), sdkToken: String?, userAgent: String = MuseDeviceAPI.defaultUserAgent) {
        self.api = api
        self.sdkToken = sdkToken
        self.userAgent = userAgent
    }

    /// The credentials with a fresh access token when it's due (or `force`).
    public func freshCredentials(_ credentials: MuseGadgetCredentials, force: Bool = false) async throws -> MuseGadgetCredentials {
        guard force || credentials.isRefreshDue() else { return credentials }
        let tokens = try await api.refreshDeviceToken(
            refreshToken: credentials.refreshToken, nodeID: credentials.identity.nodeID,
            sdkToken: sdkToken, apiRoot: credentials.apiRoot)
        return credentials.rotated(to: tokens)
    }

    /// - Parameters:
    ///   - onCredentials: called whenever the tokens rotate; persist what it is given.
    ///   - trace: every step as a line of text (never tokens).
    /// The first steps of every question: fresh tokens, a leased VM, and a link open to it. With
    /// `device`, the link is registered as that gadget so Muse can call its commands.
    public func openSession(
        credentials: MuseGadgetCredentials,
        device: MuseLinkSession.Device? = nil,
        commandHandler: MuseLinkSession.CommandHandler? = nil,
        onCredentials: @escaping @Sendable (MuseGadgetCredentials) async -> Void,
        trace: (@Sendable (String) -> Void)? = nil
    ) async throws -> MuseLinkSession {
        var current = try await freshCredentials(credentials)
        if current != credentials { await onCredentials(current) }

        var vms: [MuseVM]
        do {
            vms = try await api.fetchVMs(accessToken: current.accessToken, apiRoot: current.apiRoot)
        } catch .http(401) {
            trace?("device token rejected; rotating")
            current = try await freshCredentials(current, force: true)
            await onCredentials(current)
            vms = try await api.fetchVMs(accessToken: current.accessToken, apiRoot: current.apiRoot)
        }
        guard let vm = vms.first(where: \.isDefault) ?? vms.first else { throw Failure.noVM }
        trace?("VM \(vm.vmName.isEmpty ? vm.vmID : vm.vmName)")

        let session = try MuseLinkSession(
            noiseHost: current.noiseHost, vmID: vm.linkVMID, vmAuthToken: vm.vmAuthToken,
            device: device, commandHandler: commandHandler, userAgent: userAgent, trace: trace)
        try await session.connect()
        if device != nil {
            do {
                try await session.waitUntilRegistered()
            } catch {
                await session.close()
                throw error
            }
        }
        return session
    }

    public func ask(
        _ message: String,
        credentials: MuseGadgetCredentials,
        sessionID: String? = nil,
        timeout: Duration = .seconds(120),
        onCredentials: @escaping @Sendable (MuseGadgetCredentials) async -> Void,
        trace: (@Sendable (String) -> Void)? = nil
    ) async throws -> Answer {
        let session = try await openSession(credentials: credentials, onCredentials: onCredentials, trace: trace)
        do {
            let answer = try await follow(message, session: session, sessionID: sessionID, timeout: timeout, trace: trace)
            await session.close()
            return answer
        } catch {
            await session.close()
            throw error
        }
    }

    private func follow(
        _ message: String, session: MuseLinkSession, sessionID: String?, timeout: Duration,
        trace: (@Sendable (String) -> Void)?
    ) async throws -> Answer {
        let events = try await session.subscribeChat(sessionID: sessionID)
        let box = TurnBox(MuseTurn(sessionID: sessionID))
        let reader = Task {
            do {
                var seen = 0
                for try await event in events {
                    // The first events' names and keys (never their text), to see what Muse sends.
                    if seen < 12 { trace?("event \(MuseLinkSession.shape(event))") }
                    seen += 1
                    try await box.feed(event)
                }
            } catch {
                trace?("chat events ended: \(error)")
            }
        }
        defer { reader.cancel() }

        let ack = try await session.sendChat(message, sessionID: sessionID)
        trace?("chat acknowledged: HTTP \(ack.status)")
        guard ack.ok else { throw Failure.refused(ack.status) }
        let result = ack.response?["result"] ?? ack.response
        trace?("acknowledgement keys: \(result?.object?.keys.sorted().joined(separator: ",") ?? "none")")
        try await box.acknowledge(ack.response)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await box.isComplete()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let answer = Answer(text: await box.answerText(), complete: await box.isComplete())
        trace?("answer \(answer.text.count) chars, complete \(answer.complete)")
        return answer
    }
}

/// The turn being followed, shared by the event reader and the poller.
private actor TurnBox {
    private var turn: MuseTurn

    init(_ turn: MuseTurn) { self.turn = turn }

    func feed(_ event: MuseJSON) throws {
        _ = try turn.feed(event)
    }

    func acknowledge(_ response: MuseJSON?) throws {
        _ = try turn.acknowledge(response)
    }

    func isComplete() -> Bool { turn.isAnswered() }

    func answerText() -> String {
        MuseWidget.removingPlaceholders(MuseWidget.substitute(turn.answerText, widgets: turn.replies.flatMap(\.widgets)))
    }
}
