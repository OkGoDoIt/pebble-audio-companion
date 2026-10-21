import Foundation
import MuseLink
import Testing

@testable import CompanionRuntime

/// What a question's chat events become for the watch: widgets as words and a choice, and an
/// approval Muse waits on said plainly.
struct VoiceTurnFollowerTests {
    private actor Events {
        var list: [MuseQuestionEvent] = []
        func add(_ event: MuseQuestionEvent) { list.append(event) }
    }

    private func event(_ json: String) -> MuseJSON { MuseJSON.parse(Data(json.utf8))! }

    private func follower(_ events: Events) async throws -> VoiceTurnFollower {
        let follower = VoiceTurnFollower(sessionID: "chat-1", onEvent: { await events.add($0) })
        try await follower.acknowledge(["result": ["message_id": "u1", "session_id": "chat-1"]])
        return follower
    }

    @Test func aChoiceWidgetArrivesAsWordsAndAsAChoice() async throws {
        let events = Events()
        let follower = try await follower(events)
        try await follower.feed(event(#"""
            {"type":"event","event":"delta.text_append","payload":{"session_id":"chat-1","message_id":"a1",
             "reply_to_message_id":"u1","text":"What is 2 times 7?\n\nTap your answer:\n\n[[hatch_widget:widget-1]]",
             "widgets":[{"widget_id":"widget-1","kind":"options","options":["A: 12","B: 14"]}]}}
            """#))
        let list = await events.list
        #expect(list.contains(.answer("What is 2 times 7?\n\nTap your answer:\n\nA: 12\nB: 14")))
        #expect(list.contains(.choice(MuseChoice(question: "What is 2 times 7?", options: [MuseWidget.Option("A: 12"), MuseWidget.Option("B: 14")]))))
    }

    @Test func anApprovalThatAppearsDuringTheQuestionIsSaidOnce() async throws {
        let events = Events()
        let follower = try await follower(events)
        let none = #"{"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[]}}"#
        let one = #"{"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[{"id":"ap1","title":"Send the email"}]}}"#
        try await follower.feed(event(none))
        #expect(await events.list.isEmpty)
        try await follower.feed(event(one))
        try await follower.feed(event(one))
        #expect(await events.list == [.status(VoiceTurnFollower.waitingForOK)])
        #expect(await !follower.isComplete())
        // Answered in the app, then Muse finishes: the question can end.
        try await follower.feed(event(none))
        try await follower.feed(event(#"{"type":"event","event":"delta.message_done","payload":{"session_id":"chat-1","message_id":"a1","reply_to_message_id":"u1","display_text":"Sent."}}"#))
        try await follower.feed(event(#"{"type":"event","event":"task.status","payload":{"status":"completed","task_id":"t1"}}"#))
        #expect(await follower.isComplete())
    }

    @Test func aQuestionWaitingOnAnApprovalStaysOpen() async throws {
        let events = Events()
        let follower = try await follower(events)
        try await follower.feed(event(#"{"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[]}}"#))
        try await follower.feed(event(#"{"type":"event","event":"delta.message_done","payload":{"session_id":"chat-1","message_id":"a1","reply_to_message_id":"u1","display_text":"I need your OK to buy it."}}"#))
        try await follower.feed(event(#"{"type":"event","event":"task.status","payload":{"status":"completed","task_id":"t1"}}"#))
        #expect(await follower.isComplete())
        try await follower.feed(event(#"{"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[{"id":"buy"}]}}"#))
        #expect(await !follower.isComplete())
    }

    @Test func anOlderApprovalOnAnotherChatIsNotThisQuestions() async throws {
        let events = Events()
        let follower = try await follower(events)
        try await follower.feed(event(#"""
            {"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[{"id":"old","session_id":"elsewhere"}]}}
            """#))
        #expect(await events.list.isEmpty)
        // One on this chat counts even when it was already waiting.
        try await follower.feed(event(#"""
            {"type":"event","event":"approvals.snapshot","payload":{"pending_approvals":[{"id":"old","session_id":"elsewhere"},{"approval_id":"connector-1","type":"connector","status":"pending","scope":{"thread_id":"chat-1","session_scope_id":"s"}}]}}
            """#))
        #expect(await events.list == [.status(VoiceTurnFollower.waitingForOK)])
    }

    @Test func aReactionAloneIsAnAnswer() async throws {
        let events = Events()
        let follower = try await follower(events)
        try await follower.feed(event(#"{"type":"event","event":"message.reaction","payload":{"session_id":"chat-1","message_id":"u1","emoji":"👍"}}"#))
        try await follower.feed(event(#"{"type":"event","event":"task.status","payload":{"status":"completed","task_id":"t1"}}"#))
        #expect(await events.list == [.reaction("👍")])
        #expect(await follower.isComplete())
        // Muse's care reaction is a heart; a reaction to another message isn't this question's.
        #expect(VoiceTurnFollower.reactionText("hatch:heart_v1") == "\u{2764}")
        let other = Events()
        let second = try await self.follower(other)
        try await second.feed(event(#"{"type":"event","event":"reaction.set","payload":{"target_message_id":"old","emoji":"🎉"}}"#))
        #expect(await other.list.isEmpty)
    }

    @Test func aReactionsUpdateNamesTheNewestReaction() async throws {
        // The form Muse sent on 2026-10-21: the message's reactions as a whole.
        let events = Events()
        let follower = try await follower(events)
        try await follower.feed(event(#"{"type":"event","event":"reactions.updated","payload":{"is_thread":true,"message_id":"u1","session_id":"chat-1","reactions":[{"emoji":"👍","count":1}]}}"#))
        #expect(await events.list == [.reaction("👍")])
        #expect(VoiceTurnFollower.reactionValue(MuseJSON.parse(Data(#"{"👍":1}"#.utf8))) == "👍")
        #expect(VoiceTurnFollower.reactionValue(MuseJSON.parse(Data(#"["hatch:heart_v1"]"#.utf8))) == "hatch:heart_v1")
        #expect(VoiceTurnFollower.reactionValue(MuseJSON.parse(Data(#"[]"#.utf8))) == nil)
    }
}
