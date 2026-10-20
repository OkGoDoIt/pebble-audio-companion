import Foundation
import os

/// One session with the user's Muse VM — a port of Meta's `linux/src/musegadget/link_client.py`
/// (Apache-2.0).
///
/// Opens a WebSocket to `wss://<noise host>/v1/noise?vm_id=…` with the per-VM bearer, runs the
/// Noise XX handshake, and then carries HTTP-shaped streams inside it:
/// * `POST /link-control` (optional): the long-lived control stream. Length-prefixed JSON both
///   ways: `link.register` and `link.result` out; the register reply, `link.invoke` and
///   `link.unpaired` in. Only needed for Muse to call this gadget's commands.
/// * `POST /chat/stream`: one per message to Muse (text or a WAV voice note).
/// * `POST /chat/subscribe`: Muse's NDJSON chat event stream (status, reply text deltas).
///
/// Built for connect-per-turn use — open at a button press, close after the reply — since iOS won't
/// keep a socket alive in the background; nothing here assumes a long-lived connection.
public actor MuseLinkSession {
    public struct Device: Sendable {
        public var nodeID: String
        public var displayName: String
        public var version: String
        /// `commands_v2`: `{name: {description, required: {param: {type, description}}, optional, timeout_ms}}`.
        public var commands: MuseJSON

        public init(nodeID: String, displayName: String, version: String, commands: MuseJSON = [:]) {
            self.nodeID = nodeID
            self.displayName = displayName
            self.version = version
            self.commands = commands
        }

        /// Registered as a Linux "homehub", like Meta's Linux gadget. Never family `link`: per
        /// Meta's SDK, the server pushes ESP32 firmware updates to every `link` device.
        var registerParams: MuseJSON {
            [
                "node_id": .string(nodeID), "display_name": .string(displayName), "platform": "linux",
                "version": .string(version), "device_family": "homehub", "model_id": "linux",
                "is_wakeup_supported": false, "commands_v2": commands,
            ]
        }
    }

    public enum Outcome: String, Sendable {
        /// The connection ended; reconnect normally.
        case closed
        /// The edge refused the VM bearer (401): fetch VMs again for a fresh one.
        case authRejected
        /// Authenticated but not allowed right now (403, or `link.register` refused).
        case forbidden
        /// Muse removed this device.
        case unpaired
        case stopped
    }

    public enum Failure: Error, Equatable, Sendable {
        case upgradeRejected(status: Int)
        case notConnected
        case timedOut(String)
        case streamReset(String)
        case http(status: Int, path: String)
        case protocolError(String)
        case sessionEnded
    }

    /// The acknowledgement of a chat request.
    public struct ChatAck: Sendable {
        public let status: Int
        public let response: MuseJSON?
        public var ok: Bool { (200..<300).contains(status) }
    }

    /// Runs a `link.invoke`; returns `{"ok": true, "payload": …}` or `{"ok": false, "error": "…"}`.
    public typealias CommandHandler = @Sendable (_ command: String, _ params: MuseJSON, _ timeoutMS: Int?) async -> MuseJSON

    public static let noisePath = "/v1/noise"
    static let appID = "musegadget"
    static let requestTimeout: Duration = .seconds(60)
    static let handshakeTimeout: Duration = .seconds(20)
    static let pingInterval: Duration = .seconds(20)
    static let maxInboundMessage = 4 * 1024 * 1024
    static let maxResponseBytes = 1024 * 1024
    static let maxChatEventBytes = 256 * 1024
    static let maxInlineRequestBytes = 64 * 1024
    static let requestChunkBytes = 16 * 1024
    public static let maxVoiceBytes = 2 * 1024 * 1024

    private let url: URL
    private let vmAuthToken: String
    private let device: Device?
    private let commandHandler: CommandHandler?
    private let userAgent: String
    private let trace: (@Sendable (String) -> Void)?
    private let log = Logger(subsystem: "dev.audiocompanion.muselink", category: "link")

    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var transport: MuseNoiseTransport?
    private var outbox: AsyncStream<[Data]>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var controlStreamID: Int64 = 0
    private var registerID = ""
    private var controlBuffer = Data()
    private var requests: [Int64: RequestCollector] = [:]
    private var streams: [Int64: StreamCollector] = [:]
    private var registeredWaiters: [CheckedContinuation<Void, Error>] = []
    private var endWaiters: [CheckedContinuation<Outcome, Never>] = []
    public private(set) var isRegistered = false
    public private(set) var outcome: Outcome?

    public static func url(noiseHost: String, vmID: String) -> URL? {
        // encodeURIComponent, as Meta's gadgets do.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        guard let encoded = vmID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "wss://\(noiseHost)\(noisePath)?vm_id=\(encoded)")
    }

    /// - Parameters:
    ///   - device: register on a control stream so Muse can call `commandHandler`; `nil` for a
    ///     chat-only session (what Meta's ESP32 chat client does).
    public init(
        noiseHost: String, vmID: String, vmAuthToken: String, device: Device? = nil,
        commandHandler: CommandHandler? = nil, userAgent: String = MuseDeviceAPI.defaultUserAgent,
        urlSession: URLSession = .shared, trace: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard let url = Self.url(noiseHost: noiseHost.isEmpty ? MuseDeviceAPI.defaultNoiseHost : noiseHost, vmID: vmID) else {
            throw Failure.protocolError("bad noise host or vm id")
        }
        self.init(url: url, vmAuthToken: vmAuthToken, device: device, commandHandler: commandHandler,
                  userAgent: userAgent, urlSession: urlSession, trace: trace)
    }

    /// Any socket URL — for tests against a local fake VM (`ws://127.0.0.1:…`).
    init(
        url: URL, vmAuthToken: String, device: Device?, commandHandler: CommandHandler?,
        userAgent: String = MuseDeviceAPI.defaultUserAgent, urlSession: URLSession = .shared,
        trace: (@Sendable (String) -> Void)? = nil
    ) {
        self.url = url
        self.vmAuthToken = vmAuthToken
        self.device = device
        self.commandHandler = commandHandler
        self.userAgent = userAgent
        self.urlSession = urlSession
        self.trace = trace
    }

    private func note(_ message: String) {
        log.info("\(message, privacy: .public)")
        trace?(message)
    }

    // MARK: - Connecting

    /// Opens the socket, runs the handshake and, with a `device`, opens the control stream and
    /// sends `link.register` (await `waitUntilRegistered()` for the reply).
    public func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(vmAuthToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let socket = urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = MuseNoiseFraming.maxAssemblyBytes + 1024
        self.socket = socket
        socket.resume()

        // URLSessionWebSocketTask's send/receive ignore task cancellation, so the handshake's
        // deadline cancels the socket itself, which fails whatever is pending.
        let started = ContinuousClock.now
        let deadline = Task {
            try? await Task.sleep(for: Self.handshakeTimeout)
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        do {
            transport = try await Self.handshake(socket)
            deadline.cancel()
        } catch {
            deadline.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if let http = socket.response as? HTTPURLResponse, [401, 403].contains(http.statusCode) {
                note("VM refused the connection: HTTP \(http.statusCode)")
                outcome = http.statusCode == 401 ? .authRejected : .forbidden
                throw Failure.upgradeRejected(status: http.statusCode)
            }
            outcome = .closed
            if ContinuousClock.now - started >= Self.handshakeTimeout { throw Failure.timedOut("Noise handshake") }
            throw error
        }
        note("Noise session established")

        let (outbound, continuation) = AsyncStream.makeStream(of: [Data].self)
        outbox = continuation
        tasks.append(Task { [weak self] in
            for await frames in outbound {
                for frame in frames {
                    do { try await socket.send(.data(frame)) } catch {
                        await self?.end(.closed, because: "send failed: \(error.localizedDescription)")
                        return
                    }
                }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do { message = try await socket.receive() } catch {
                    await self?.end(.closed, because: "connection closed: \(error.localizedDescription)")
                    return
                }
                guard case .data(let data) = message else { continue }
                guard let self, await self.handleIncoming(data) else { return }
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                socket.sendPing { _ in }
            }
        })

        if let device {
            let opened = try transportRequest("POST", "/link-control", headers: [], endBody: false)
            controlStreamID = opened.streamID
            enqueue(opened.frames)
            registerID = UUID().uuidString.lowercased()
            sendControl(["type": "req", "id": .string(registerID), "method": "link.register", "params": device.registerParams])
            note("sent link.register as \(device.nodeID)")
        }
    }

    private static func handshake(_ socket: URLSessionWebSocketTask) async throws -> MuseNoiseTransport {
        var initiator = MuseNoiseXXInitiator()
        try await socket.send(.data(try initiator.writeMessage1()))
        guard case .data(let message2) = try await socket.receive() else {
            throw Failure.protocolError("Noise handshake got a text frame")
        }
        _ = try initiator.readMessage2(message2)
        // The bearer already authenticated us at the upgrade; message 3 carries an empty payload.
        try await socket.send(.data(try initiator.writeMessage3()))
        let (send, receive) = initiator.split()
        return MuseNoiseTransport(send: send, receive: receive)
    }

    public func waitUntilRegistered(timeout: Duration = .seconds(20)) async throws {
        if isRegistered { return }
        if outcome != nil { throw Failure.sessionEnded }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.failRegisteredWaiters(Failure.timedOut("link.register reply")) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { registeredWaiters.append($0) }
    }

    private func failRegisteredWaiters(_ error: Error) {
        registeredWaiters.forEach { $0.resume(throwing: error) }
        registeredWaiters.removeAll()
    }

    /// Resolves when the session ends, with why.
    public func waitForEnd() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { endWaiters.append($0) }
    }

    public func close() {
        end(.stopped, because: "closed by the gadget")
    }

    // MARK: - Chat

    /// Posts a user message to Muse as coming from this gadget. `sessionID` targets a side chat (an
    /// id Muse hasn't seen starts a new one); without it the message goes to the main chat.
    public func sendChat(_ message: String, sessionID: String? = nil, outputModality: String = "text") async throws -> ChatAck {
        var body: [String: MuseJSON] = ["message": .string(message), "output_modality": .string(outputModality)]
        if let device { body["device_id"] = .string(device.nodeID) }
        if let sessionID { body["session_id"] = .string(sessionID) }
        return try await postChat(.object(body))
    }

    /// Posts a WAV voice note (16 kHz mono PCM16, at most 15 s / 2 MiB), optionally with
    /// instructions in `message`.
    public func sendVoice(wav: Data, sessionID: String? = nil, message: String = "", outputModality: String? = nil) async throws -> ChatAck {
        guard !wav.isEmpty, wav.count <= Self.maxVoiceBytes else {
            throw Failure.protocolError("voice note must contain at most 2 MiB of WAV audio")
        }
        var body: [String: MuseJSON] = [
            "message": .string(message),
            "items": [["type": "file", "mime_type": "audio/wav", "filename": "voice_note.wav",
                       "data_base64": .string(wav.base64EncodedString())]],
        ]
        if let device { body["device_id"] = .string(device.nodeID) }
        if let sessionID { body["session_id"] = .string(sessionID) }
        if let outputModality { body["output_modality"] = .string(outputModality) }
        return try await postChat(.object(body))
    }

    private func httpHeaders(_ extra: [MuseHeader]) -> [MuseHeader] {
        extra + [MuseHeader("x-request-id", UUID().uuidString.lowercased()), MuseHeader("x-app-id", Self.appID)]
    }

    private func postChat(_ request: MuseJSON) async throws -> ChatAck {
        guard transport != nil, outcome == nil else { throw Failure.notConnected }
        let body = request.compactData()
        let headers = httpHeaders([MuseHeader("Content-Type", "application/json")])
        let inParts = body.count > Self.maxInlineRequestBytes
        let opened = try transportRequest("POST", "/chat/stream", headers: headers, body: inParts ? Data() : body, endBody: !inParts)
        let streamID = opened.streamID
        let (status, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, Data), Error>) in
            startRequest(streamID, frames: opened.frames, body: inParts ? body : nil, continuation: continuation)
        }
        return ChatAck(status: Int(status), response: response.isEmpty ? nil : MuseJSON.parse(response))
    }

    private func startRequest(_ streamID: Int64, frames: [Data], body: Data?, continuation: CheckedContinuation<(Int32, Data), Error>) {
        guard outcome == nil else {
            continuation.resume(throwing: Failure.sessionEnded)
            return
        }
        requests[streamID] = RequestCollector(continuation: continuation)
        enqueue(frames)
        tasks.append(Task {
            try? await Task.sleep(for: Self.requestTimeout)
            if !Task.isCancelled { self.timeOutRequest(streamID, "/chat/stream") }
        })
        guard let body else { return }
        var offset = 0
        while offset < body.count {
            let end = min(offset + Self.requestChunkBytes, body.count)
            guard let chunk = try? transport?.bodyChunk(streamID: streamID, data: body.subdata(in: offset..<end), endBody: end == body.count) else {
                failRequest(streamID, Failure.protocolError("could not encrypt body chunk"))
                return
            }
            enqueue(chunk)
            offset = end
        }
    }

    /// Muse's chat events (`{"type":"event","event":…,"payload":…}`) from its NDJSON subscription,
    /// for `sessionID`'s chat or the main one. Subscribe *before* sending the request whose answer
    /// you want. Ending iteration cancels the subscription.
    public func subscribeChat(sessionID: String? = nil) async throws -> AsyncThrowingStream<MuseJSON, Error> {
        guard transport != nil, outcome == nil else { throw Failure.notConnected }
        let body: MuseJSON = sessionID.map { ["session_id": .string($0)] } ?? [:]
        let headers = httpHeaders([MuseHeader("Content-Type", "application/json"), MuseHeader("Accept", "application/x-ndjson")])
        let opened = try transportRequest("POST", "/chat/subscribe", headers: headers, body: body.compactData(), endBody: true)
        let streamID = opened.streamID
        let (chunks, chunkContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let status: Int32 = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Int32, Error>) in
            startStream(streamID, frames: opened.frames, ready: ready, chunks: chunkContinuation)
        }
        guard (200..<300).contains(status) else {
            cancelStream(streamID)
            throw Failure.http(status: Int(status), path: "/chat/subscribe")
        }
        note("subscribed to chat events\(sessionID.map { " (side chat \($0))" } ?? "")")
        return AsyncThrowingStream { continuation in
            let reader = Task {
                var line = Data()
                do {
                    for try await chunk in chunks {
                        for byte in chunk {
                            line.append(byte)
                            guard line.count <= Self.maxChatEventBytes else {
                                throw Failure.protocolError("chat event exceeds 256 KiB")
                            }
                            guard byte == 0x0A else { continue }
                            if let event = Self.chatEvent(line) { continuation.yield(event) }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if let event = Self.chatEvent(line) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                Task { await self.cancelStream(streamID) }
            }
        }
    }

    /// One subscription row, with its name under `event` wherever Muse put it: Meta's ESP32
    /// gadget reads the name from `event` or `event_name`, at the top level or in the payload.
    static func chatEvent(_ raw: Data) -> MuseJSON? {
        guard var event = MuseJSON.parse(raw)?.object, event["type"]?.string == "event" else { return nil }
        if event["event"]?.string == nil {
            let name = event["event_name"]?.string ?? event["payload"]?["event"]?.string
                ?? event["payload"]?["event_name"]?.string
            if let name { event["event"] = .string(name) }
        }
        return .object(event)
    }

    /// What a chat event looks like, for the flight recorder: its name and the payload's keys,
    /// never their values (no question or answer text, no ids).
    public static func shape(_ event: MuseJSON) -> String {
        let name = event["event"]?.string ?? "?"
        let keys = event["payload"]?.object?.keys.sorted().joined(separator: ",") ?? "-"
        return "\(name)[\(keys)]"
    }

    private func startStream(
        _ streamID: Int64, frames: [Data], ready: CheckedContinuation<Int32, Error>,
        chunks: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        guard outcome == nil else {
            ready.resume(throwing: Failure.sessionEnded)
            chunks.finish(throwing: Failure.sessionEnded)
            return
        }
        streams[streamID] = StreamCollector(ready: ready, chunks: chunks)
        enqueue(frames)
        tasks.append(Task {
            try? await Task.sleep(for: Self.requestTimeout)
            if !Task.isCancelled { self.timeOutStreamHeaders(streamID) }
        })
    }

    /// A stream whose response headers never came: fail its opener and cancel it.
    private func timeOutStreamHeaders(_ streamID: Int64) {
        guard var stream = streams[streamID], stream.ready != nil else { return }
        stream.resolveReady(throwing: Failure.timedOut("stream headers"))
        streams[streamID] = stream
        cancelStream(streamID)
    }

    private func timeOutRequest(_ streamID: Int64, _ path: String) {
        guard requests[streamID] != nil else { return }
        failRequest(streamID, Failure.timedOut(path))
        if outcome == nil, let frames = try? transport?.reset(streamID: streamID, reason: "timed out") {
            enqueue(frames)
        }
    }

    private func cancelStream(_ streamID: Int64) {
        guard let stream = streams.removeValue(forKey: streamID) else { return }
        stream.chunks.finish()
        if !stream.ended, outcome == nil, let frames = try? transport?.reset(streamID: streamID, reason: "consumer closed") {
            enqueue(frames)
        }
    }

    // MARK: - Sending

    private func transportRequest(_ verb: String, _ path: String, headers: [MuseHeader], body: Data = Data(), endBody: Bool) throws -> MuseNoiseTransport.Encrypted {
        guard var transport else { throw Failure.notConnected }
        defer { self.transport = transport }
        return try transport.request(verb, path, headers: headers, body: body, endBody: endBody)
    }

    /// Frames go out strictly in the order they were encrypted: the Noise nonce has already advanced.
    private func enqueue(_ frames: [Data]) {
        outbox?.yield(frames)
    }

    private func sendControl(_ message: MuseJSON) {
        let json = message.compactData()
        var data = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        guard let frames = try? transport?.bodyChunk(streamID: controlStreamID, data: data, endBody: false) else { return }
        enqueue(frames)
    }

    // MARK: - Receiving

    /// Handles one WebSocket message. Returns false once the session has ended.
    private func handleIncoming(_ data: Data) -> Bool {
        guard outcome == nil else { return false }
        let frame: MuseServiceFrame
        do {
            guard let opened = try transport?.open(data) else { return true }
            frame = opened
        } catch {
            end(.closed, because: "undecryptable frame: \(error)")
            return false
        }
        if frame.streamID != controlStreamID || controlStreamID == 0 {
            dispatch(frame)
            return true
        }
        let data: Data
        let ended: Bool
        switch frame.kind {
        case .reset(_, let reason)?:
            end(.closed, because: "control stream reset: \(reason)")
            return false
        case .response(let status, _, let body, let endBody)?:
            if status >= 400 {
                end(status == 403 ? .forbidden : .closed, because: "/link-control refused: HTTP \(status)")
                return false
            }
            (data, ended) = (body, endBody)
        case .bodyChunk(let chunk, let endBody)?:
            (data, ended) = (chunk, endBody)
        default:
            return true
        }
        controlBuffer.append(data)
        while controlBuffer.count >= 4 {
            let length = controlBuffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard length <= Self.maxInboundMessage else {
                end(.closed, because: "inbound control message too large")
                return false
            }
            guard controlBuffer.count >= 4 + length else { break }
            let raw = controlBuffer.subdata(in: (controlBuffer.startIndex + 4)..<(controlBuffer.startIndex + 4 + length))
            controlBuffer.removeSubrange(controlBuffer.startIndex..<(controlBuffer.startIndex + 4 + length))
            if raw.isEmpty { continue }  // keepalive
            guard let message = MuseJSON.parse(raw), message.object != nil else {
                note("dropping malformed control message (\(length) bytes)")
                continue
            }
            if let outcome = handleControl(message) {
                end(outcome, because: "control message")
                return false
            }
        }
        if ended {
            end(.closed, because: "control stream ended by VM")
            return false
        }
        return true
    }

    private func handleControl(_ message: MuseJSON) -> Outcome? {
        if message["id"]?.string == registerID, message["method"] == nil {
            if message["error"] != nil || message["ok"]?.bool == false {
                note("link.register rejected: \(message.compactString())")
                return .forbidden
            }
            isRegistered = true
            note("registered with Muse")
            registeredWaiters.forEach { $0.resume() }
            registeredWaiters.removeAll()
            return nil
        }
        if let event = message["event"]?.string, event == "link.unpaired" || event == "node.unpaired" {
            note("Muse removed this device")
            return .unpaired
        }
        if message["method"]?.string == "link.invoke", let id = message["id"]?.string, !id.isEmpty {
            let command = message["command"]?.string ?? ""
            let params = message["params"].flatMap { $0.object != nil ? $0 : nil } ?? [:]
            let timeoutMS = message["timeout_ms"]?.number.map { Int($0) }
            note("invoke \(command.filter { !$0.isASCII || $0.isLetter || $0.isNumber || ".-_".contains($0) })")
            let handler = commandHandler
            tasks.append(Task {
                let result = await handler?(command, params, timeoutMS) ?? ["ok": false, "error": "unsupported command"]
                self.sendInvokeResult(id: id, result: result)
            })
        }
        return nil
    }

    private func sendInvokeResult(id: String, result: MuseJSON) {
        guard outcome == nil else { return }
        var message = result.object ?? ["ok": false, "error": "invalid result"]
        message["method"] = "link.result"
        message["id"] = .string(id)
        sendControl(.object(message))
    }

    private func dispatch(_ frame: MuseServiceFrame) {
        let streamID = frame.streamID
        if var stream = streams[streamID] {
            switch frame.kind {
            case .reset?:
                stream.ended = true
                streams[streamID] = nil
                stream.resolveReady(throwing: Failure.streamReset("response stream reset"))
                stream.chunks.finish(throwing: Failure.streamReset("response stream reset"))
            case .response(let status, _, let body, let endBody)?:
                stream.resolveReady(status)
                if !body.isEmpty { stream.chunks.yield(body) }
                if endBody {
                    stream.ended = true
                    stream.chunks.finish()
                }
                streams[streamID] = stream
            case .bodyChunk(let data, let endBody)?:
                if !data.isEmpty { stream.chunks.yield(data) }
                if endBody {
                    stream.ended = true
                    stream.chunks.finish()
                }
                streams[streamID] = stream
            default:
                break
            }
            return
        }
        guard var request = requests[streamID] else { return }
        let data: Data
        let ended: Bool
        switch frame.kind {
        case .reset(_, let reason)?:
            failRequest(streamID, Failure.streamReset(reason))
            return
        case .response(let status, _, let body, let endBody)?:
            request.status = status
            (data, ended) = (body, endBody)
        case .bodyChunk(let chunk, let endBody)?:
            (data, ended) = (chunk, endBody)
        default:
            return
        }
        request.body.append(data)
        if request.body.count > Self.maxResponseBytes {
            failRequest(streamID, Failure.protocolError("response too large"))
        } else if ended {
            requests[streamID] = nil
            request.continuation.resume(returning: (request.status, request.body))
        } else {
            requests[streamID] = request
        }
    }

    private func failRequest(_ streamID: Int64, _ error: Error) {
        guard let request = requests.removeValue(forKey: streamID) else { return }
        request.continuation.resume(throwing: error)
    }

    private func end(_ outcome: Outcome, because reason: String) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        note("session ended (\(outcome.rawValue)): \(reason)")
        outbox?.finish()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        for (_, request) in requests { request.continuation.resume(throwing: Failure.sessionEnded) }
        requests.removeAll()
        for (_, var stream) in streams {
            stream.resolveReady(throwing: Failure.sessionEnded)
            stream.chunks.finish(throwing: Failure.sessionEnded)
        }
        streams.removeAll()
        registeredWaiters.forEach { $0.resume(throwing: Failure.sessionEnded) }
        registeredWaiters.removeAll()
        endWaiters.forEach { $0.resume(returning: outcome) }
        endWaiters.removeAll()
    }

    // MARK: - Helpers

    private struct RequestCollector {
        let continuation: CheckedContinuation<(Int32, Data), Error>
        var status: Int32 = 0
        var body = Data()
    }

    private struct StreamCollector {
        var ready: CheckedContinuation<Int32, Error>?
        let chunks: AsyncThrowingStream<Data, Error>.Continuation
        var ended = false

        mutating func resolveReady(_ status: Int32) {
            ready?.resume(returning: status)
            ready = nil
        }

        mutating func resolveReady(throwing error: Error) {
            ready?.resume(throwing: error)
            ready = nil
        }
    }
}
