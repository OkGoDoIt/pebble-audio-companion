import Foundation
import Testing

@testable import MuseLink

/// Muse's chat subscription rows, as Meta's ESP32 gadget reads them: the event's name may be
/// `event` or `event_name`, at the top level or in the payload.
struct MuseChatEventTests {
    private func row(_ json: String) -> MuseJSON? { MuseLinkSession.chatEvent(Data(json.utf8)) }

    @Test func theNameIsFoundWhereverMusePutIt() {
        #expect(row(#"{"type":"event","event":"message.assistant","payload":{}}"#)?["event"]?.string == "message.assistant")
        #expect(row(#"{"type":"event","event_name":"delta.text_append","payload":{}}"#)?["event"]?.string == "delta.text_append")
        #expect(row(#"{"type":"event","payload":{"event_name":"agent.status"}}"#)?["event"]?.string == "agent.status")
        #expect(row(#"{"type":"ack"}"#) == nil)
    }

    @Test func aReplyNamedEventNameReachesTheTurn() throws {
        var turn = MuseTurn()
        _ = try turn.acknowledge(["result": ["message_id": "u1"]])
        let delta = try #require(row(#"{"type":"event","event_name":"delta.text_append","payload":{"message_id":"a1","reply_to_message_id":"u1","text":"Hi"}}"#))
        let done = try #require(row(#"{"type":"event","event_name":"delta.message_done","payload":{"message_id":"a1","reply_to_message_id":"u1"}}"#))
        _ = try turn.feed(delta)
        _ = try turn.feed(done)
        #expect(turn.answerText == "Hi")
    }

    @Test func aReplayedCompletionDoesNotEndATurnThatHeardNothing() throws {
        var turn = MuseTurn(clock: { 0 })
        _ = try turn.acknowledge(["result": ["message_id": "u2"]])
        let stale = try #require(row(#"{"type":"event","event":"task.status","payload":{"status":"completed","task_id":"t-old"}}"#))
        _ = try turn.feed(stale)
        #expect(turn.isComplete())
        #expect(!turn.isAnswered())
    }

    @Test func theShapeNamesKeysNotValues() {
        let event = row(#"{"type":"event","event":"message.user","payload":{"content":"secret words","message_id":"m"}}"#)!
        #expect(MuseLinkSession.shape(event) == "message.user[content,message_id]")
    }
}
