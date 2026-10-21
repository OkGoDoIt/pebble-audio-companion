import Foundation
import Testing

@testable import MuseLink

/// What a standing subscription reports of Muse's messages: finished ones, after the replay, in
/// groups, each with the user message it answers.
struct MuseInboxTests {
    private func event(_ name: String, _ payload: String) -> MuseJSON {
        MuseJSON.parse(Data(#"{"type":"event","event":"\#(name)","payload":\#(payload)}"#.utf8))!
    }

    @Test func theReplayIsNeverReportedAndAFinishedMessageIsOnceItIsQuiet() {
        var inbox = MuseInbox(sessionID: "chat-1", startedAt: 100)
        // Replayed on subscribing: an older answer.
        inbox.feed(event("delta.message_done", #"{"session_id":"chat-1","message_id":"old","display_text":"Earlier."}"#), now: 100.5)
        #expect(inbox.due(now: 104).isEmpty)

        // Muse writes by itself later: streamed, then finished.
        inbox.feed(event("delta.message_start", #"{"session_id":"chat-1","message_id":"m1"}"#), now: 200)
        inbox.feed(event("delta.text_append", #"{"session_id":"chat-1","message_id":"m1","text":"Your 3 PM "}"#), now: 200.2)
        inbox.feed(event("delta.text_append", #"{"session_id":"chat-1","message_id":"m1","text":"moved."}"#), now: 200.4)
        #expect(inbox.due(now: 210).isEmpty)  // not finished yet
        inbox.feed(event("delta.message_done", #"{"session_id":"chat-1","message_id":"m1","display_text":"Your 3 PM moved to 4."}"#), now: 201)
        #expect(inbox.due(now: 202).isEmpty)  // not quiet yet
        let due = inbox.due(now: 204.5)
        #expect(due == [MuseInbox.Message(id: "m1", text: "Your 3 PM moved to 4.", widgets: [], root: nil)])
        #expect(inbox.due(now: 300).isEmpty)  // once
    }

    @Test func bubblesGoTogetherAndARepliesChainLeadsToItsQuestion() {
        var inbox = MuseInbox(sessionID: "chat-1", startedAt: 0)
        inbox.feed(event("message.user", #"{"session_id":"chat-1","message_id":"u7","role":"user","display_text":"hi"}"#), now: 10)
        inbox.feed(event("delta.message_done", #"{"session_id":"chat-1","message_id":"a1","reply_to_message_id":"u7","display_text":"First."}"#), now: 11)
        inbox.feed(event("delta.message_done", #"{"session_id":"chat-1","message_id":"a2","reply_to_message_id":"a1","display_text":"Second."}"#), now: 12)
        // Another chat's message is not this one's.
        inbox.feed(event("delta.message_done", #"{"session_id":"other","message_id":"x","display_text":"No."}"#), now: 12.5)
        let due = inbox.due(now: 16)
        #expect(due.map(\.id) == ["a1", "a2"])
        #expect(due.map(\.root) == ["u7", "u7"])
        #expect(inbox.userMessages == ["u7"])
    }

    @Test func aMessageMadeOfOnlyAWidgetCounts() {
        var inbox = MuseInbox(sessionID: nil, startedAt: 0)
        inbox.feed(event("delta.text_append", #"{"message_id":"w","text":"[[hatch_widget:w1]]","widgets":[{"widget_id":"w1","kind":"options","options":["Yes","No"]}]}"#), now: 10)
        inbox.feed(event("delta.message_done", #"{"message_id":"w"}"#), now: 10.1)
        let due = inbox.due(now: 14)
        #expect(due.first?.widgets.first?.options.map(\.label) == ["Yes", "No"])
    }
}
