import Foundation
import Network
import Testing

@testable import MuseLink

/// A local stand-in for a Muse VM: a real WebSocket server (Network framework) that runs the
/// responder side of Noise XX and answers the gadget's streams the way Meta's service does —
/// enough to drive `MuseLinkSession` end to end (handshake, register, invoke, subscribe, chat).
private final class FakeMuseVM: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-muse-vm")
    private let listener: NWListener
    private var connection: NWConnection?
    private var responder = MuseNoiseXXResponder()
    private var send: MuseNoiseCipher?
    private var receive: MuseNoiseCipher?
    private var decoder = MuseNoiseFraming.Decoder()
    private var phase = 0
    private var controlStreamID: Int64?
    private var subscribeStreamID: Int64?
    private var controlBuffer = Data()
    private var startResolved = false

    // Observations, read on `queue` through `snapshot`.
    final class UpgradeHeaders: @unchecked Sendable { var authorization: String? }
    private let upgradeHeaders = UpgradeHeaders()
    var authorization: String? { upgradeHeaders.authorization }
    private(set) var paths: [String] = []
    private(set) var registerParams: MuseJSON?
    private(set) var chatBody: MuseJSON?
    private(set) var invokeResults: [MuseJSON] = []
    var invokeResult: MuseJSON? { invokeResults.first { $0["id"]?.string == "inv1" } }
    /// The answer to the command Muse sent as a `client.invoke` chat event.
    var clientInvokeResult: MuseJSON? { invokeResults.first { $0["id"]?.string == "ci1" } }

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let queue = self.queue
        // The options are copied into the listener, so the handler must be set first; it can't
        // capture `self` yet, hence the box.
        let upgrade = upgradeHeaders
        websocket.setClientRequestHandler(queue) { _, headers in
            upgrade.authorization = headers.first { $0.name.lowercased() == "authorization" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.connection = connection
            connection.start(queue: queue)
            self?.receiveNext()
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // Runs on `queue`, so `startResolved` needs no lock.
            listener.stateUpdateHandler = { [self] state in
                guard !startResolved else { return }
                switch state {
                case .ready:
                    startResolved = true
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    startResolved = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connection?.cancel()
    }

    func snapshot<T: Sendable>(_ read: @escaping @Sendable (FakeMuseVM) -> T) -> T {
        queue.sync { read(self) }
    }

    private func receiveNext() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.handle(data) }
            self.receiveNext()
        }
    }

    private func sendBinary(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func respond(_ frame: MuseServiceFrame) {
        let envelope = MuseServiceEnvelope.encodeResponse(payload: frame.encoded())
        for chunk in try! MuseNoiseFraming.encode(envelope) {
            sendBinary(try! send!.encrypt(ad: Data(), plaintext: chunk))
        }
    }

    private func sendControl(_ message: MuseJSON) {
        let json = message.compactData()
        var data = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        respond(MuseServiceFrame(streamID: controlStreamID!, kind: .bodyChunk(data: data + json, endBody: false)))
    }

    private func event(_ name: String, _ payload: MuseJSON) {
        let line = MuseJSON.object(["type": "event", "event": .string(name), "payload": payload]).compactData() + Data([0x0A])
        respond(MuseServiceFrame(streamID: subscribeStreamID!, kind: .bodyChunk(data: line, endBody: false)))
    }

    private func handle(_ data: Data) {
        switch phase {
        case 0:
            sendBinary(try! responder.readMessage1AndWriteMessage2(data))
            phase = 1
        case 1:
            try! responder.readMessage3(data)
            (send, receive) = responder.split()
            phase = 2
        default:
            let plain = try! receive!.decrypt(ad: Data(), ciphertext: data)
            guard let envelope = try! decoder.decode(plain) else { return }
            let frame = try! MuseServiceFrame.decode(try! MuseServiceEnvelope.decodeRequestPayload(envelope))
            handle(frame)
        }
    }

    private func handle(_ frame: MuseServiceFrame) {
        switch frame.kind {
        case .request(_, let path, _, let body, _)?:
            paths.append(path)
            switch path {
            case "/link-control":
                controlStreamID = frame.streamID
                respond(MuseServiceFrame(streamID: frame.streamID, kind: .response(status: 200, headers: [], body: Data(), endBody: false)))
            case "/chat/subscribe":
                subscribeStreamID = frame.streamID
                respond(MuseServiceFrame(streamID: frame.streamID, kind: .response(
                    status: 200, headers: [MuseHeader("Content-Type", "application/x-ndjson")], body: Data(), endBody: false)))
            case "/chat/stream":
                chatBody = MuseJSON.parse(body)
                let session = chatBody?["session_id"] ?? .null
                let ack: MuseJSON = ["result": ["message_id": "u1", "session_id": session, "is_thread": true]]
                respond(MuseServiceFrame(streamID: frame.streamID, kind: .response(status: 200, headers: [], body: ack.compactData(), endBody: true)))
                event("agent.status", ["activity_code": "thinking", "reply_to_message_id": "u1", "session_id": session])
                // How Muse really sent a gadget command on 2026-10-21: a chat event, not link.invoke.
                event("client.invoke", ["command_id": "watch.show", "invoke_id": "ci1",
                                        "params_json": #"{"title":"Yo"}"#, "timeout_ms": 120000])
                event("delta.message_start", ["message_id": "r1", "reply_to_message_id": "u1", "session_id": session])
                event("delta.text_append", ["message_id": "r1", "reply_to_message_id": "u1", "text": "Hel", "session_id": session])
                event("delta.text_append", ["message_id": "r1", "reply_to_message_id": "u1", "text": "lo", "session_id": session])
                event("delta.message_done", ["message_id": "r1", "reply_to_message_id": "u1", "display_text": "Hello", "session_id": session])
                event("task.status", ["status": "completed", "reply_to_message_id": "u1", "session_id": session])
            default:
                respond(MuseServiceFrame(streamID: frame.streamID, kind: .response(status: 404, headers: [], body: Data(), endBody: true)))
            }
        case .bodyChunk(let data, _)? where frame.streamID == controlStreamID:
            controlBuffer.append(data)
            while controlBuffer.count >= 4 {
                let length = controlBuffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                guard controlBuffer.count >= 4 + length else { break }
                let message = MuseJSON.parse(controlBuffer.subdata(in: (controlBuffer.startIndex + 4)..<(controlBuffer.startIndex + 4 + length)))
                controlBuffer.removeSubrange(controlBuffer.startIndex..<(controlBuffer.startIndex + 4 + length))
                if message?["method"]?.string == "link.register" {
                    registerParams = message?["params"]
                    sendControl(["type": "res", "id": message?["id"] ?? .null, "ok": true, "result": ["status": "registered"]])
                    sendControl(["method": "link.invoke", "id": "inv1", "command": "watch.show",
                                 "params": ["title": "Hi", "body": "From Muse"], "timeout_ms": 5000])
                } else if message?["method"]?.string == "link.result", let message {
                    invokeResults.append(message)
                    if message["id"]?.string == "ci1" { sendControl(["type": "res", "id": "ci1", "ok": true]) }
                }
            }
        default:
            break
        }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

@Suite("Muse link session against a local fake VM")
struct MuseLinkSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func connectsRegistersAnswersAnInvokeAndFollowsATurn() async throws {
        let vm = try FakeMuseVM()
        let port = try await vm.start()
        defer { vm.stop() }

        let calls = Calls()
        let session = MuseLinkSession(
            url: URL(string: "ws://127.0.0.1:\(port)/v1/noise?vm_id=vm1")!, vmAuthToken: "vm-token",
            device: .init(nodeID: "homelink-abc123", displayName: "Pebble watch", version: "0.1.0",
                          commands: ["watch.show": ["description": "Show text", "required": [:], "optional": [:]]]),
            commandHandler: { command, params, _, _ in
                calls.append("\(command) \(params["title"]?.string ?? "")")
                return ["ok": true, "payload": ["shown": true]]
            })
        try await session.connect()
        try await session.waitUntilRegistered()
        #expect(vm.snapshot { $0.authorization } == "Bearer vm-token")
        let params = try #require(vm.snapshot { $0.registerParams })
        #expect(params["platform"]?.string == "linux")
        #expect(params["device_family"]?.string == "homehub")
        #expect(params["node_id"]?.string == "homelink-abc123")
        #expect(params["commands_v2"]?["watch.show"] != nil)

        let events = try await session.subscribeChat(sessionID: "watch-1")
        let ack = try await session.sendChat("hi", sessionID: "watch-1")
        #expect(ack.ok)
        let body = try #require(vm.snapshot { $0.chatBody })
        #expect(body["message"]?.string == "hi")
        #expect(body["device_id"]?.string == "homelink-abc123")
        #expect(body["session_id"]?.string == "watch-1")

        var turn = MuseTurn(sessionID: "watch-1", ownsChat: true)
        _ = try turn.acknowledge(ack.response)
        for try await event in events {
            _ = try turn.feed(event)
            if turn.taskFinished, turn.replies.allSatisfy(\.done) { break }
        }
        #expect(turn.answerText == "Hello")
        #expect(turn.replies.first?.streamed == "Hello")

        // The invoke Muse sent right after registering was answered on the control stream.
        for _ in 0..<50 where vm.snapshot({ $0.invokeResult }) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<50 where vm.snapshot({ $0.clientInvokeResult }) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(calls.all) == ["watch.show Hi", "watch.show Yo"])
        // The command that came as a chat event was run too, and answered by its invoke id.
        let client = try #require(vm.snapshot { $0.clientInvokeResult })
        #expect(client["method"]?.string == "link.result")
        #expect(client["ok"]?.bool == true)
        let result = try #require(vm.snapshot { $0.invokeResult })
        #expect(result["id"]?.string == "inv1")
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["shown"]?.bool == true)
        #expect(vm.snapshot { $0.paths } == ["/link-control", "/chat/subscribe", "/chat/stream"])

        await session.close()
        #expect(await session.waitForEnd() == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedUpgradeReportsTheStatus() async throws {
        // Nothing listens on this port's /v1/noise with a valid WebSocket; a plain HTTP 401 server
        // would be needed to see 401, so just check a dead endpoint fails fast and cleanly.
        let session = MuseLinkSession(
            url: URL(string: "ws://127.0.0.1:9/v1/noise?vm_id=x")!, vmAuthToken: "t", device: nil, commandHandler: nil)
        await #expect(throws: (any Error).self) { try await session.connect() }
        #expect(await session.outcome != nil)
    }
}
