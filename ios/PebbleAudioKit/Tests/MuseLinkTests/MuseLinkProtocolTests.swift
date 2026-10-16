import CryptoKit
import Foundation
import Testing

@testable import MuseLink

@Suite("Muse Noise XX and envelope")
struct MuseNoiseTests {
    @Test func handshakeRoundTripsAndSplitsMirrored() throws {
        var initiator = MuseNoiseXXInitiator()
        var responder = MuseNoiseXXResponder(payload: Data("hello gadget".utf8))
        let message2 = try responder.readMessage1AndWriteMessage2(try initiator.writeMessage1())
        #expect(try initiator.readMessage2(message2) == Data("hello gadget".utf8))
        try responder.readMessage3(try initiator.writeMessage3())
        #expect(initiator.handshakeHash == responder.handshakeHash)

        var (initiatorSend, initiatorReceive) = initiator.split()
        var (responderSend, responderReceive) = responder.split()
        let sealed = try initiatorSend.encrypt(ad: Data(), plaintext: Data("ping".utf8))
        #expect(try responderReceive.decrypt(ad: Data(), ciphertext: sealed) == Data("ping".utf8))
        let back = try responderSend.encrypt(ad: Data(), plaintext: Data("pong".utf8))
        #expect(try initiatorReceive.decrypt(ad: Data(), ciphertext: back) == Data("pong".utf8))
    }

    @Test func tamperedMessage2IsRejected() throws {
        var initiator = MuseNoiseXXInitiator()
        var responder = MuseNoiseXXResponder()
        var message2 = try responder.readMessage1AndWriteMessage2(try initiator.writeMessage1())
        message2[40] ^= 0x01
        #expect(throws: MuseNoiseError.self) { _ = try initiator.readMessage2(message2) }
    }

    @Test func lowOrderPointIsRejected() {
        #expect(throws: MuseNoiseError.self) {
            _ = try MuseNoiseCrypto.dh(.init(), Data(count: 32))
        }
    }

    /// A request sealed by the gadget's transport opens on the VM side into the same frame, and a
    /// response sealed by the VM opens in the gadget's transport.
    @Test func transportFramesRoundTrip() throws {
        var initiator = MuseNoiseXXInitiator()
        var responder = MuseNoiseXXResponder()
        let message2 = try responder.readMessage1AndWriteMessage2(try initiator.writeMessage1())
        _ = try initiator.readMessage2(message2)
        try responder.readMessage3(try initiator.writeMessage3())
        let (send, receive) = initiator.split()
        var (vmSend, vmReceive) = responder.split()
        var gadget = MuseNoiseTransport(send: send, receive: receive)

        let body = Data(repeating: 0x41, count: 70_000)  // two noise chunks
        let request = try gadget.request(
            "POST", "/chat/stream", headers: [MuseHeader("x-app-id", "musegadget")], body: body, endBody: true)
        #expect(request.streamID == 1)
        #expect(request.frames.count == 2)
        var decoder = MuseNoiseFraming.Decoder()
        var envelope: Data?
        for frame in request.frames {
            envelope = try decoder.decode(try vmReceive.decrypt(ad: Data(), ciphertext: frame)) ?? envelope
        }
        let frame = try MuseServiceFrame.decode(try MuseServiceEnvelope.decodeRequestPayload(try #require(envelope)))
        #expect(frame.streamID == 1)
        #expect(frame.kind == .request(verb: "POST", path: "/chat/stream", headers: [MuseHeader("x-app-id", "musegadget")], body: body, endBody: true))

        let response = MuseServiceFrame(streamID: 1, kind: .response(status: 200, headers: [], body: Data("{}".utf8), endBody: true))
        let wire = try MuseNoiseFraming.encode(MuseServiceEnvelope.encodeResponse(payload: response.encoded()))
        let opened = try gadget.open(try vmSend.encrypt(ad: Data(), plaintext: try #require(wire.first)))
        #expect(opened == response)
    }

    @Test func varintAndNegativeStreamIDsRoundTrip() throws {
        for id: Int64 in [0, 1, 127, 128, 300, Int64.max, -1, Int64.min] {
            let frame = MuseServiceFrame(streamID: id, kind: .bodyChunk(data: Data([1, 2, 3]), endBody: false))
            #expect(try MuseServiceFrame.decode(frame.encoded()) == frame)
        }
    }

    @Test func urlEncodesVMIDLikeEncodeURIComponent() {
        let url = MuseLinkSession.url(noiseHost: "hatch.metaaivm.com", vmID: "vm id/1+x")
        #expect(url?.absoluteString == "wss://hatch.metaaivm.com/v1/noise?vm_id=vm%20id%2F1%2Bx")
    }
}

@Suite("Muse turn tracking")
struct MuseTurnTests {
    private func event(_ name: String, _ payload: MuseJSON) -> MuseJSON {
        ["type": "event", "event": .string(name), "payload": payload]
    }

    @Test func bindsRepliesToTheAcknowledgedMessageAndCompletes() throws {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        let clock = Clock()
        var turn = MuseTurn(clock: { clock.now })
        // Arrives before the acknowledgement: held, then released by it.
        #expect(try turn.feed(event("agent.status", ["activity_code": "thinking", "reply_to_message_id": "u1"])).isEmpty)
        let held = try turn.acknowledge(["result": ["message_id": "u1", "session_id": "s1"]])
        #expect(held == [.status(.init(activityCode: "thinking", activityText: nil))])
        #expect(turn.busy)

        _ = try turn.feed(event("delta.message_start", ["message_id": "r1", "reply_to_message_id": "u1"]))
        _ = try turn.feed(event("delta.text_append", ["message_id": "r1", "reply_to_message_id": "u1", "text": "Four"]))
        // A reply to someone else's message is ignored.
        #expect(try turn.feed(event("delta.text_append", ["message_id": "x", "reply_to_message_id": "other", "text": "no"])).isEmpty)
        let done = try turn.feed(event("delta.message_done", ["message_id": "r1", "reply_to_message_id": "u1", "display_text": "4."]))
        #expect(done.last == .reply(.init(messageID: "r1", text: "4.", streamed: "Four", done: true, bound: true)))
        _ = try turn.feed(event("task.status", ["status": "completed", "reply_to_message_id": "u1"]))
        #expect(turn.taskFinished)
        #expect(turn.isComplete())
        #expect(turn.answerText == "4.")
    }

    @Test func quietCompletesWithoutTaskStatus() throws {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = Clock()
        var turn = MuseTurn(clock: { clock.now })
        _ = try turn.acknowledge(["result": ["message_id": "u1"]])
        _ = try turn.feed(event("delta.message_done", ["message_id": "r1", "reply_to_message_id": "u1", "display_text": "hi"]))
        #expect(!turn.isComplete())
        clock.now = 3.5
        #expect(turn.isComplete())
    }

    @Test func ownedChatRequiresAThreadAcknowledgement() {
        var turn = MuseTurn(sessionID: "watch", ownsChat: true)
        #expect(throws: MuseTurn.Invalid.self) {
            _ = try turn.acknowledge(["result": ["message_id": "u1", "session_id": "watch"]])
        }
    }

    @Test func stripsControlCharacters() {
        #expect(MuseTurn.stripControls("a\u{1B}[31mb\tc\nd\u{85}") == "a[31mb\tc\nd")
    }
}
