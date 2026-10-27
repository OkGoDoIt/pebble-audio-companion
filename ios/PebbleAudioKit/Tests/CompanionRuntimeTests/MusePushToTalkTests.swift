import AudioCodec
import Foundation
import MuseLink
import Receiver
import Testing
import WireProtocol

@testable import CompanionRuntime

/// Questions asked on the watch (protocol Sections 4.4 and 4.5), against a fake watch that
/// records every request and a fake Muse that answers from a script.
struct MusePushToTalkTests {
    @Test func disconnectedAnswerReplaysAllFourOptionsAfterAuthorization() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityConversation | ProtocolConstants.capabilityAnswerRestart
        await fx.start()
        let options = ["11:48 AM", "11:08 AM", "11:18 AM", "11:58 AM"].map { MuseWidget.Option($0) }
        let raw = "That time came through unclear. Did you mean one of these?\n[[hatch_widget:times]]"
        let widget = MuseWidget(id: "times", options: options)
        fx.muse.script = [.heard("Set a smart alarm for approximately 11.8 AM"),
                          .content(MuseAnswerContent(raw: raw, widgets: [widget])),
                          .answer(raw), .choice(MuseChoice(question: nil, options: options))]
        // A prior fragment got through, then the reconnecting link rejects a write during auth.
        fx.link.scriptReplies([.ok, .badState, .notSent, .badState, .ok])
        try fx.ask(turn: 4, seconds: 1.5)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        let updates = fx.link.updates()
        let begin = try #require(updates.lastIndex { $0.kind == .begin })
        let replay = updates[begin...]
        #expect(replay.filter { $0.kind == .option }.map { String(decoding: $0.text, as: UTF8.self) } == options.map(\.label))
        #expect(String(decoding: replay.filter { $0.kind == .answer }.flatMap(\.text), as: UTF8.self).contains("Did you mean"))
        fx.muse.script = [.answer("Alarm set.")]
        fx.pick(turn: 4, index: 2)
        #expect(await fx.waitUntil { fx.muse.replies.contains("11:18 AM") })
    }

    @Test func aNewQuestionSupersedesAnInterruptedReplay() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityConversation | ProtocolConstants.capabilityAnswerRestart
        await fx.start()
        fx.link.scriptReplies(Array(repeating: .badState, count: 30))
        fx.muse.script = [.heard("Old question"), .answer("Old answer")]
        try fx.ask(turn: 5, seconds: 1.5)
        #expect(await fx.waitUntil { fx.service.lastQuestion.value?.answered == true })
        fx.link.scriptReplies([])
        fx.muse.script = [.heard("New question"), .answer("New answer")]
        try fx.ask(turn: 6, seconds: 1.5)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done && fx.link.updates().last?.turn == 6 })
        try await Task.sleep(for: .milliseconds(250))
        #expect(fx.link.updates().last?.turn == 6)
        #expect(!fx.link.updates().contains { $0.turn == 5 && $0.kind == .begin })
    }

    @Test func alarmToolRejectsAmbiguousFieldsAndNeverDowngradesSmartWake() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        for params: MuseJSON in [["hour": .number(11.8), "minute": 0], ["hour": 11, "minute": 8, "smart": "yes"]] {
            #expect(await fx.service.runCommand(MuseTools.alarmCommand, params)["ok"]?.bool == false)
        }
        #expect(await fx.service.runCommand(MuseTools.alarmsCommand, ["action": "delete", "id": .number(1.5)])["ok"]?.bool == false)
        #expect(fx.link.actions().isEmpty)
        let smart = Task { await fx.service.runCommand(MuseTools.alarmCommand, ["hour": 11, "minute": 18, "smart": true]) }
        _ = try #require(await fx.answerNextAction(status: .unsupported))
        #expect(await smart.value["ok"]?.bool == false)
        #expect(fx.link.actions().count == 1)
    }

    @Test func alarmResultBeforeALostAckIsKeptWithoutCreatingTwice() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.link.resultBeforeAck = true
        fx.link.scriptReplies([.noAnswer])
        let result = await fx.service.runCommand(MuseTools.alarmCommand, ["hour": 7, "minute": 30, "smart": true])
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["id"]?.number == 2)
        #expect(fx.link.actions().count == 1)
    }

    @Test func smartAlarmCreationAndEditsReachTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let create = Task { await fx.service.runCommand(MuseTools.alarmCommand, ["hour": 11, "minute": 18, "smart": true]) }
        let action = try #require(await fx.answerNextAction(status: .done, value: 3))
        #expect(WatchActionRequest.parse(action.payload) == .alarms(.create, hour: 11, minute: 18, smart: 1, enabled: 1))
        #expect(await create.value["payload"]?["smart"]?.bool == true)
        #expect(await create.value["payload"]?["id"]?.number == 3)
        let update = Task { await fx.service.runCommand(MuseTools.alarmsCommand, ["action": "update", "id": 3, "minute": 30]) }
        let changed = try #require(await fx.answerNextAction(status: .done))
        #expect(WatchActionRequest.parse(changed.payload) == .alarms(.update, id: 3, minute: 30))
        #expect(await update.value["ok"]?.bool == true)
        let delete = Task { await fx.service.runCommand(MuseTools.alarmsCommand, ["action": "delete", "id": 3]) }
        let deleted = try #require(await fx.answerNextAction(status: .done))
        #expect(WatchActionRequest.parse(deleted.payload) == .alarms(.delete, id: 3))
        #expect(await delete.value["ok"]?.bool == true)
    }

    @Test func alarmListDecodesSmartAndRecurringAlarms() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let list = Task { await fx.service.runCommand(MuseTools.alarmsCommand, ["action": "list"]) }
        _ = try #require(await fx.answerNextAction(status: .done, text: "0073011300\n118450047F\n"))
        let rows = await list.value["payload"]?["alarms"]?.array
        #expect(rows?.count == 2)
        #expect(rows?[0]["smart"]?.bool == true)
        #expect(rows?[0]["repeat"]?.string == "once")
        #expect(rows?[1]["enabled"]?.bool == false)
        #expect(rows?[1]["days_sunday_bit0"]?.number == 127)
    }

    @Test func aQuestionGoesToMuseAndItsAnswerToTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [
            .heard("what's the weather in Lisbon"),
            .status("Checking the forecast"),
            .answer("**Sunny**, 24 "),
            .answer("**Sunny**, 24 degrees until the evening."),
        ]

        try fx.ask(turn: 7, seconds: 1.5)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })

        let updates = fx.link.updates()
        #expect(updates.allSatisfy { $0.turn == 7 })
        #expect(updates.first?.kind == .heard)
        #expect(String(decoding: updates.first?.text ?? [], as: UTF8.self) == "what's the weather in Lisbon")
        #expect(updates.contains { $0.kind == .status && String(decoding: $0.text, as: UTF8.self) == "Checking the forecast" })
        let answer = updates.filter { $0.kind == .answer }.flatMap(\.text)
        #expect(String(decoding: answer, as: UTF8.self) == "Sunny, 24 degrees until the evening.")

        // One voice note: 16 kHz mono WAV, the question's length, made louder than it came.
        let note = try #require(fx.muse.notes.first)
        #expect(fx.muse.notes.count == 1)
        #expect(note.count == PcmWav.headerBytes + 75 * 320 * 2)
        let report = try #require(fx.service.lastQuestion.value)
        #expect(report.answered)
        #expect(report.missingFrames == 0)
        #expect((report.level?.gainDB ?? 0) > 10)
        #expect(report.heard == "what's the weather in Lisbon")
    }

    @Test func anAnswerMuseRewritesIsReplacedOnTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        // Streamed, then finished with different formatting: the watch can only append, so it
        // gets the whole answer again as a restart.
        fx.muse.script = [
            .answer("1. 09:53 your first note"),
            .answer("1. 09:53 — your 1st voice note: \"testing\". I confirmed I heard it."),
        ]
        try fx.ask(turn: 12, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        let updates = fx.link.updates()
        let restart = try #require(updates.firstIndex { $0.kind == .answerRestart })
        let after = updates[restart...].filter { $0.kind == .answer || $0.kind == .answerRestart }.flatMap(\.text)
        #expect(String(decoding: after, as: UTF8.self) == "1. 09:53 — your 1st voice note: \"testing\". I confirmed I heard it.")
    }

    @Test func anOlderWatchKeepsWhatStreamed() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk
        await fx.start()
        fx.muse.script = [.answer("Short"), .answer("Different")]
        try fx.ask(turn: 13, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        #expect(!fx.link.updates().contains { $0.kind == .answerRestart })
    }

    @Test func aLostFrameIsSilenceNotASkip() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [.answer("Yes.")]
        try fx.ask(turn: 3, seconds: 2, dropping: [10, 11, 12])
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        let note = try #require(fx.muse.notes.first)
        #expect(note.count == PcmWav.headerBytes + 100 * 320 * 2)
        #expect(fx.service.lastQuestion.value?.missingFrames == 3)
    }

    @Test func notSetUpSaysSoAtThePress() async throws {
        let fx = PushToTalkFixture(paired: false)
        await fx.start()
        fx.link.push(.pttEvent(PttEvent(turn: 2, eventRaw: PttEventKind.start.rawValue, detail: PttTrigger.quickLaunch.rawValue, maxSeconds: 15)))
        #expect(await fx.waitUntil { !fx.link.updates().isEmpty })
        let update = try #require(fx.link.updates().first)
        #expect(update.kind == .error)
        #expect(update.detail == AssistantError.notSetUp.rawValue)
        #expect(fx.muse.opens == 0)
    }

    @Test func aBlipIsNotAQuestion() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        // A hold that only opened Muse: under a second, press included.
        try fx.ask(turn: 4, seconds: 0.9)
        #expect(await fx.waitUntil { !fx.link.updates().isEmpty })
        #expect(fx.link.updates().first?.kind == .error)
        #expect(fx.link.updates().first?.detail == AssistantError.didNotCatch.rawValue)
        #expect(fx.muse.notes.isEmpty)
    }

    @Test func museUnreachableEndsTheQuestionPlainly() async throws {
        let fx = PushToTalkFixture()
        fx.muse.openFailure = .unreachable
        await fx.start()
        try fx.ask(turn: 5, seconds: 1)
        #expect(await fx.waitUntil { !fx.link.updates().isEmpty })
        #expect(fx.link.updates().last?.kind == .error)
        #expect(fx.link.updates().last?.detail == AssistantError.unreachable.rawValue)
    }

    // Muse refused every message on the watch's chat for an afternoon (HTTP 409) while the watch
    // said "Can't reach Muse". A turn finishing is asked again; a chat that stays held is left
    // for a new one, and the question is answered there.
    @Test func aChatMuseHoldsBrieflyIsAskedAgain() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [.heard("what time is it"), .answer("Two.")]
        fx.muse.askFailures = [.chatBusy(approvalPending: false)]
        let chat = fx.preferences.watchChatID()
        try fx.ask(turn: 7, seconds: 2)
        #expect(await fx.waitUntil(seconds: 6) { fx.link.updates().last?.kind == .done })
        #expect(fx.muse.notes.count == 1)
        #expect(fx.muse.opens == 1)
        #expect(fx.preferences.watchChatID() == chat)
    }

    @Test func aChatMuseKeepsHoldingIsLeftForANewOne() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [.heard("what time is it"), .answer("Two.")]
        fx.muse.askFailures = [.chatBusy(approvalPending: false), .chatBusy(approvalPending: false)]
        let chat = fx.preferences.watchChatID()
        try fx.ask(turn: 8, seconds: 2)
        #expect(await fx.waitUntil(seconds: 6) { fx.link.updates().last?.kind == .done })
        #expect(fx.preferences.watchChatID() != chat)
        #expect(fx.muse.chatIDs.last == fx.preferences.watchChatID())
        #expect(fx.muse.notes.count == 1)
    }

    @Test func anApprovalHoldingTheChatSaysMuseIsBusyAndKeepsTheChat() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.askFailures = [.chatBusy(approvalPending: true)]
        let chat = fx.preferences.watchChatID()
        try fx.ask(turn: 9, seconds: 2)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .error })
        #expect(fx.link.updates().last?.detail == AssistantError.busy.rawValue)
        #expect(fx.preferences.watchChatID() == chat)
        #expect(fx.muse.opens == 1)
    }

    @Test func silenceFromMuseIsNoAnswer() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [.heard("hello")]
        try fx.ask(turn: 6, seconds: 1)
        #expect(await fx.waitUntil { !fx.link.updates().isEmpty && fx.link.updates().last?.kind == .error })
        #expect(fx.link.updates().last?.detail == AssistantError.noAnswer.rawValue)
    }

    @Test func aCancelledQuestionSendsNothingAndTheLinkWaitsForTheNext() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.link.push(.pttEvent(PttEvent(turn: 8, eventRaw: PttEventKind.start.rawValue, detail: 2, maxSeconds: 15)))
        fx.link.push(.pttAudio(PttAudio(turn: 8, firstFrame: 0, frames: try fx.frames(count: 10))))
        fx.link.push(.pttEvent(PttEvent(turn: 8, eventRaw: PttEventKind.cancel.rawValue, detail: PttCancelReason.tooShort.rawValue, frameCount: 10)))
        #expect(await fx.waitUntil { fx.muse.opens == 1 })
        fx.muse.script = [.answer("Done.")]
        try fx.ask(turn: 9, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        #expect(fx.link.updates().allSatisfy { $0.turn == 9 })
        // The link opened at the first press was the one the second question used.
        #expect(fx.muse.opens == 1)
        #expect(fx.muse.notes.count == 1)
    }

    @Test func aBusyWatchIsAskedAgain() async throws {
        let fx = PushToTalkFixture()
        fx.link.scriptReplies([.busy, .busy])
        await fx.start()
        fx.muse.script = [.answer("Okay.")]
        try fx.ask(turn: 10, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        #expect(String(decoding: fx.link.updates().filter { $0.kind == .answer }.flatMap(\.text), as: UTF8.self) == "Okay.")
    }

    @Test func theQuietLinkFollowsPairing() async {
        let fx = PushToTalkFixture()
        await fx.start()
        #expect(fx.link.quietLink.last == true)
        fx.pairedName.value = nil
        #expect(await fx.waitUntil { fx.link.quietLink.last == false })
    }

    // MARK: - Choices Muse offers

    @Test func aChoiceMuseOffersIsPickedOnTheWatchAndAnsweredThere() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityAnswerRestart
            | ProtocolConstants.capabilityFollowUp
        await fx.start()
        fx.muse.script = [
            .answer("What is 2 times 7?\n\nA: 12\nB: 14\nC: 16"),
            .choice(MuseChoice(question: "What is 2 times 7?", options: ["A: 12", "B: 14", "C: 16"].map { MuseWidget.Option($0) })),
        ]
        fx.muse.replyScript = [.heard("B: 14"), .answer("Right, **14**.")]
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let actions = fx.link.actions()
        #expect(WatchActionRequest.parse(actions.flatMap(\.payload))
            == .choose(question: "What is 2 times 7?", options: ["A: 12", "B: 14", "C: 16"], timeoutSeconds: 120))

        fx.link.push(.watchActionResult(WatchActionResult(actionId: actions[0].actionId, statusRaw: WatchActionStatus.done.rawValue, value: 1)))
        #expect(await fx.waitUntil { fx.link.updates().filter { $0.kind == .done }.count == 2 })
        #expect(fx.muse.replies == ["B: 14"])
        #expect(fx.muse.notes.count == 1)
        let updates = fx.link.updates()
        let firstDone = try #require(updates.firstIndex { $0.kind == .done })
        let followUp = updates[(firstDone + 1)...]
        #expect(followUp.allSatisfy { $0.turn == 3 })
        #expect(followUp.first?.kind == .heard)
        #expect(String(decoding: followUp.first?.text ?? [], as: UTF8.self) == "B: 14")
        #expect(followUp.filter { $0.kind == .heard }.count == 1)
        let answer = followUp.filter { $0.kind == .answer }.flatMap(\.text)
        #expect(String(decoding: answer, as: UTF8.self) == "Right, 14.")
    }

    @Test func aListRowSendsItsOwnMessageAndALoneButtonCanBeLeft() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityFollowUp
        await fx.start()
        fx.muse.script = [
            .answer("Coffee near you"),
            .choice(MuseChoice(question: "Coffee near you", options: [MuseWidget.Option("Blue Bottle", reply: "Tell me more about Blue Bottle")])),
        ]
        fx.muse.replyScript = [.answer("It opened in 2002.")]
        try fx.ask(turn: 6, seconds: 1)
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let action = fx.link.actions()[0]
        #expect(WatchActionRequest.parse(action.payload)
            == .choose(question: "Coffee near you", options: ["Blue Bottle", "Not now"], timeoutSeconds: 120))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.done.rawValue, value: 0)))
        #expect(await fx.waitUntil { fx.muse.replies == ["Tell me more about Blue Bottle"] })
        #expect(await fx.waitUntil { fx.link.updates().filter { $0.kind == .done }.count == 2 })
    }

    @Test func aReactionSitsAfterTheQuestionOrIsTheAnswer() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [.heard("thanks, that's all"), .reaction("👍")]
        try fx.ask(turn: 8, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        let updates = fx.link.updates()
        let heard = updates.filter { $0.kind == .heard }.map { String(decoding: $0.text, as: UTF8.self) }
        #expect(heard == ["thanks, that's all", "thanks, that's all 👍"])
        let answer = updates.filter { $0.kind == .answer || $0.kind == .answerRestart }.flatMap(\.text)
        #expect(String(decoding: answer, as: UTF8.self) == "👍")
    }

    @Test func aWatchThatCannotFollowUpKeepsTheChoiceAsText() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        fx.muse.script = [
            .answer("Tea or coffee?\n\nTea\nCoffee"),
            .choice(MuseChoice(question: "Tea or coffee?", options: [MuseWidget.Option("Tea"), MuseWidget.Option("Coffee")])),
        ]
        try fx.ask(turn: 4, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fx.link.actions().isEmpty)
        let answer = fx.link.updates().filter { $0.kind == .answer }.flatMap(\.text)
        #expect(String(decoding: answer, as: UTF8.self) == "Tea or coffee?\n\nTea\nCoffee")
    }

    @Test func aChoiceSetAsideOnTheWatchAsksMuseNothing() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityFollowUp
        await fx.start()
        fx.muse.script = [.answer("Tea or coffee?"), .choice(MuseChoice(question: nil, options: [MuseWidget.Option("Tea"), MuseWidget.Option("Coffee")]))]
        try fx.ask(turn: 5, seconds: 1)
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let action = fx.link.actions()[0]
        #expect(WatchActionRequest.parse(action.payload) == .choose(question: "Your answer", options: ["Tea", "Coffee"], timeoutSeconds: 120))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.declined.rawValue)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fx.muse.replies.isEmpty)
        #expect(fx.link.updates().filter { $0.kind == .heard }.isEmpty)
    }

    @Test func museCanUseTheWatchWhileItAnswers() async throws {
        // Until 2026-10-21 the answer held the watch's messages back until it finished, so a
        // result the watch sent mid-answer waited behind the answer that was waiting for it.
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.health] = .allowed }
        await fx.start()
        fx.muse.toolCall = (MuseTools.healthCommand, ["metric": "distance", "days": 2])
        fx.muse.script = [.answer("You walked 4.2 km yesterday.")]
        try fx.ask(turn: 9, seconds: 1)
        let action = try #require(await fx.answerNextAction(status: .done, text: "3100,4200"))
        #expect(WatchActionRequest.parse(action.payload) == .health(.distanceMeters, days: 2))
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        #expect(fx.muse.toolResults.first?["ok"]?.bool == true)
        let report = try #require(fx.service.lastQuestion.value)
        #expect(report.tools == [MuseToolUse(command: MuseTools.healthCommand, outcome: .done)])
        #expect(report.answer == "You walked 4.2 km yesterday.")
    }

    @Test func eachCallsOutcomeIsReadFromItsReply() {
        #expect(MuseTools.outcome(of: ["ok": true, "payload": [:]]) == .done)
        #expect(MuseTools.outcome(of: MuseTools.turnedOff) == .declined)
        #expect(MuseTools.outcome(of: MuseTools.reply(.notNow, .calendar)) == .declined)
        #expect(MuseTools.outcome(of: MuseTools.reply(.notAnswered, .health)) == .unanswered)
        #expect(MuseTools.outcome(of: MuseTools.error("The watch didn't answer.")) == .failed("The watch didn't answer."))
    }

    // MARK: - Watch actions

    @Test func aTimerIsSetOnTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 90]) }
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let action = try #require(fx.link.actions().first)
        #expect(WatchActionRequest.parse(action.payload) == .nativeTimers(.create, seconds: 90, label: ""))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.done.rawValue, text: Array("42,1,90000,90\nPasta".utf8))))
        let result = await reply.value
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["duration_seconds"]?.number == 90)
    }

    @Test func anActionTurnedOffIsRefusedWithoutTouchingTheWatch() async {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.watchActions = [.timer] }
        await fx.start()
        let result = await fx.service.runCommand(MuseTools.alarmCommand, ["hour": 7, "minute": 30])
        #expect(result["ok"]?.bool == false)
        #expect(fx.link.actions().isEmpty)
        // And it was never offered to Muse.
        let offered = MuseTools.commands(
            for: MusePreferences(watchActions: [.timer], dataAccess: Dictionary(uniqueKeysWithValues: MuseSource.allCases.map { ($0, .off) })),
            hasData: true)
        #expect(offered.object?.keys.sorted() == [MuseTools.timerCommand, MuseTools.timersCommand])
    }

    @Test func aTimerRepeatedSoonAfterIsNotSetTwice() async throws {
        // Muse retries a call whose reply it never got; the first timer is already running.
        let fx = PushToTalkFixture()
        await fx.start()
        let first = Task { await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 600]) }
        _ = try #require(await fx.answerNextAction(status: .done, text: "42,1,600000,600\nPasta"))
        #expect(await first.value["ok"]?.bool == true)
        let again = await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 600])
        #expect(again["ok"]?.bool == true)
        #expect(fx.link.actions().count == 1)
        // A different timer is set.
        let other = Task { await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 300]) }
        _ = try #require(await fx.answerNextAction(status: .done, text: "42,1,600000,600\nPasta"))
        #expect(await other.value["ok"]?.bool == true)
        #expect(fx.link.actions().count == 2)
    }

    @Test func badParametersAreRefused() async {
        let fx = PushToTalkFixture()
        await fx.start()
        let result = await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 0])
        #expect(result["ok"]?.bool == false)
        let alarm = await fx.service.runCommand(MuseTools.alarmCommand, ["hour": 25, "minute": 0])
        #expect(alarm["ok"]?.bool == false)
        #expect(fx.link.actions().isEmpty)
    }
}

/// A watch that keeps the conversation (capability bit5): options with the answer, picks that
/// come later, and the messages Muse sends by itself.
struct MuseConversationTests {
    static let conversation = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityAnswerRestart
        | ProtocolConstants.capabilityFollowUp | ProtocolConstants.capabilityConversation

    private func choiceScript() -> [MuseQuestionEvent] {
        let widget = MuseWidget(id: "w1", options: [MuseWidget.Option("A: 12"), MuseWidget.Option("B: 14", reply: "I pick 14")])
        let raw = "What is 2 times 7?\n\n[[hatch_widget:w1]]"
        return [
            .heard("quiz me"),
            .asked(["u1"]),
            .content(MuseAnswerContent(raw: raw, widgets: [widget], messageIDs: ["a1"])),
            .answer("What is 2 times 7?\n\nA: 12\nB: 14"),
            .choice(MuseChoice(question: "What is 2 times 7?", options: widget.options)),
        ]
    }

    private func text(_ update: AssistantUpdate) -> String { String(decoding: update.text, as: UTF8.self) }

    @Test func museCanUseTheWatchOnlyWhileAnsweringAWatchQuestion() async throws {
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        // The link is open, but nobody asked anything: a call is refused, and nothing runs.
        let refused = await fx.muse.call(MuseTools.timerCommand, ["seconds": 60])
        #expect(refused?["ok"]?.bool == false)
        #expect(refused?["error"]?.string == MusePushToTalk.outsideQuestion)
        #expect(fx.link.actions().isEmpty)
        // Asked on the watch: the same call runs.
        fx.muse.script = [.heard("set a timer"), .answer("Done.")]
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })
        let call = Task { await fx.muse.call(MuseTools.timerCommand, ["seconds": 60]) }
        _ = try #require(await fx.answerNextAction(status: .done, text: "42,1,60000,60\n"))
        #expect(await call.value?["ok"]?.bool == true)
    }

    @Test func optionsGoWithTheAnswerAndItsTextLeavesThemOut() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = Self.conversation
        fx.muse.script = choiceScript()
        await fx.start()
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })
        let updates = fx.link.updates()
        let answer = updates.filter { $0.kind == .answer || $0.kind == .answerRestart }.map(text).joined()
        #expect(answer == "What is 2 times 7?")
        let options = updates.filter { $0.kind == .option }
        #expect(options.map(text) == ["A: 12", "B: 14"])
        #expect(options.map(\.detail) == [0, 1])
        // Options come before Done, and no picker pops up after it.
        let doneAt = try #require(updates.firstIndex { $0.kind == .done })
        #expect(updates.lastIndex { $0.kind == .option }! < doneAt)
        #expect(fx.link.actions().isEmpty)
    }

    @Test func aPickLaterGoesToMuseAsTheReplyOnTheSameTurn() async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = Self.conversation
        fx.muse.script = choiceScript()
        fx.muse.replyScript = [.answer("Correct!")]
        await fx.start()
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })
        let before = fx.link.updates().count

        fx.pick(turn: 3, index: 1)
        #expect(await fx.waitUntil { fx.link.updates().dropFirst(before).contains { $0.kind == .done } })
        #expect(fx.muse.replies == ["I pick 14"])
        let after = Array(fx.link.updates().dropFirst(before))
        #expect(after.allSatisfy { $0.turn == 3 })
        #expect(after.first { $0.kind == .heard }.map(text) == "B: 14")
        #expect(after.filter { $0.kind == .answer || $0.kind == .answerRestart }.map(text).joined() == "Correct!")

        // A pick for options this phone never sent says so.
        fx.pick(turn: 9, index: 0)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.turn == 9 && $0.kind == .error } })
    }

    @Test func aQuestionMuseIsStillWorkingOnSaysSoAndItsAnswerComesLater() async throws {
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        fx.muse.script = [.heard("book a table"), .asked(["u1"])]
        fx.muse.done = false
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        try fx.ask(turn: 4, seconds: 1)
        #expect(await fx.waitUntil {
            fx.link.updates().contains { $0.turn == 4 && $0.kind == .error && $0.detail == AssistantError.stillWorking.rawValue }
        })

        // Minutes later Muse answers that question: a late answer, on a turn of the phone's own.
        fx.muse.post([MuseChatMessage(id: "a9", content: MuseAnswerContent(raw: "Booked for 7.", widgets: []), root: "u1")])
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .begin } })
        let begin = try #require(fx.link.updates().first { $0.kind == .begin })
        #expect(begin.turn == 5)
        #expect(begin.detail == AssistantBegin.lateAnswer.rawValue)
        #expect(text(begin) == "book a table")
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.turn == 5 && $0.kind == .done } })
        let words = fx.link.updates().filter { $0.turn == 5 && ($0.kind == .answer || $0.kind == .answerRestart) }
        #expect(words.map(text).joined() == "Booked for 7.")
        #expect(fx.service.lastQuestion.value?.answer == "Booked for 7.")
    }

    @Test func museMessagesReachTheWatchUnlessAQuestionOrThePhoneHasThem() async throws {
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        fx.muse.script = choiceScript()
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })

        // The question's own answer, seen again by the chat: not sent twice. A reply to something
        // typed in the Muse app stays there.
        fx.muse.post([
            MuseChatMessage(id: "a1", content: MuseAnswerContent(raw: "What is 2 times 7?", widgets: []), root: "u1"),
            MuseChatMessage(id: "a2", content: MuseAnswerContent(raw: "Typed reply", widgets: []), root: "t1"),
        ], typedElsewhere: ["t1"])
        // A scheduled result Muse sends by itself goes to the watch, with no question.
        fx.muse.post([MuseChatMessage(id: "a3", content: MuseAnswerContent(raw: "Your 3 PM moved to 4.", widgets: []), root: nil)])
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .begin } })
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.turn == 4 && $0.kind == .done } })
        let begins = fx.link.updates().filter { $0.kind == .begin }
        #expect(begins.count == 1)
        #expect(begins.first?.detail == AssistantBegin.message.rawValue)
        #expect(begins.first?.text.isEmpty == true)
        let words = fx.link.updates().filter { $0.turn == 4 && ($0.kind == .answer || $0.kind == .answerRestart) }
        #expect(words.map(text).joined() == "Your 3 PM moved to 4.")
    }

    @Test func aQuestionsOwnAnswerIsNotSentAgainWhenMuseNamesNoQuestion() async throws {
        // Muse's assistant events carry no reply-to id (G17, 2026-10-21/22: every watch question
        // got its answer twice, the second as "a message from Muse").
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        fx.muse.script = choiceScript()
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        try fx.ask(turn: 3, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })

        fx.muse.post([MuseChatMessage(id: "a1", content: MuseAnswerContent(raw: "What is 2 times 7?", widgets: []), root: nil)])
        fx.muse.post([MuseChatMessage(id: "a3", content: MuseAnswerContent(raw: "Your 3 PM moved to 4.", widgets: []), root: nil)])
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.turn == 4 && $0.kind == .done } })
        try await Task.sleep(for: .milliseconds(100))
        let begins = fx.link.updates().filter { $0.kind == .begin }
        #expect(begins.count == 1)
        let words = fx.link.updates().filter { $0.turn == 4 && ($0.kind == .answer || $0.kind == .answerRestart) }
        #expect(words.map(text).joined() == "Your 3 PM moved to 4.")
    }

    @Test func aBusyWatchGetsTheMessageOnceItsQuestionIsOver() async throws {
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        // The watch says busy the first time (a question of its own is under way).
        fx.link.scriptReplies([.busy])
        fx.muse.post([MuseChatMessage(id: "a3", content: MuseAnswerContent(raw: "Done: flights booked.", widgets: []), root: nil)])
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })
        #expect(fx.link.updates().filter { $0.kind == .begin }.count == 1)
    }

    @Test func anOlderWatchKeepsMuseMessagesInTheMuseApp() async throws {
        let fx = PushToTalkFixture(listening: true)
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        fx.muse.post([MuseChatMessage(id: "a3", content: MuseAnswerContent(raw: "Hello", widgets: []), root: nil)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fx.link.updates().contains { $0.kind == .begin })
    }

    @Test func turningMessagesOffStopsFollowingTheChat() async throws {
        let fx = PushToTalkFixture(listening: true)
        fx.link.watchCapabilities = Self.conversation
        await fx.start()
        #expect(await fx.waitUntil { fx.muse.following > 0 })
        fx.preferences.update { $0.messagesOnWatch = false }
        try await Task.sleep(for: .milliseconds(100))
        fx.muse.post([MuseChatMessage(id: "a3", content: MuseAnswerContent(raw: "Hello", widgets: []), root: nil)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fx.link.updates().contains { $0.kind == .begin })
    }
}


/// What the watch ends up holding after a streamed answer, rebuilt from the updates the way the
/// firmware applies them (assistant_view.c): Restart replaces, Answer appends until Done.
struct MuseStreamedAnswerTests {
    static func watchText(_ updates: [AssistantUpdate], turn: Int) -> String {
        var text: [UInt8] = []
        var done = false
        for update in updates where update.turn == turn {
            switch update.kind {
            case .heard?: if done { text = []; done = false }
            case .answerRestart?: text = update.text
            case .answer?: if !done { text += update.text }
            case .done?: done = true
            default: break
            }
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Roger's 12:01 answer, as Muse wrote it (Markdown), streamed a few words at a time.
    static let raw = """
        Done — clean overview, last 7 days, Pebble data only.

        **Summary (Oct 15–21)**
        - **Steps:** 83,259 total, 11,894/day average (12,715/day for the 6 full days)
        - **Distance:** 76.5 km total (47.6 miles), 10.9 km/day average (11.7 km/day for full days)
        - **Daily:** Thu 10,133 steps / 9.34 km · Fri 19,598 / 18.34 km · Sat 12,713 / 11.64 km
        - **Heart rate: no data** — the watch returned “no heart_rate data” for both 7-day and 1-day reads, so there are no heart rate values to report

        The detailed report is attached below.
        """

    @Test(arguments: [3, 7, 13, 40])
    func aLongStreamedAnswerArrivesWhole(step: Int) async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityAnswerRestart
            | ProtocolConstants.capabilityFollowUp
        var script: [MuseQuestionEvent] = [.heard("clean overview only")]
        var end = Self.raw.startIndex
        while end < Self.raw.endIndex {
            end = Self.raw.index(end, offsetBy: step, limitedBy: Self.raw.endIndex) ?? Self.raw.endIndex
            script.append(.answer(String(Self.raw[..<end])))
        }
        fx.muse.script = script
        await fx.start()
        try fx.ask(turn: 2, seconds: 1)
        #expect(await fx.waitUntil { fx.link.updates().contains { $0.kind == .done } })
        let expected = WatchAnswerText.render(Self.raw, final: true)
        #expect(Self.watchText(fx.link.updates(), turn: 2) == expected)
    }

    @Test(arguments: [3, 13])
    func aLongAnswerToAPickArrivesWhole(step: Int) async throws {
        let fx = PushToTalkFixture()
        fx.link.watchCapabilities = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityAnswerRestart
            | ProtocolConstants.capabilityFollowUp
        fx.muse.script = [
            .heard("walking and heart rate"),
            .answer("Which format?\n\nA\nB"),
            .choice(MuseChoice(question: "Which format?", options: [MuseWidget.Option("Full report"), MuseWidget.Option("Clean overview only")])),
        ]
        var reply: [MuseQuestionEvent] = [.reaction("👍")]
        var end = Self.raw.startIndex
        while end < Self.raw.endIndex {
            end = Self.raw.index(end, offsetBy: step, limitedBy: Self.raw.endIndex) ?? Self.raw.endIndex
            reply.append(.answer(String(Self.raw[..<end])))
        }
        fx.muse.replyScript = reply
        await fx.start()
        try fx.ask(turn: 2, seconds: 1)
        _ = try #require(await fx.answerNextAction(status: .done, value: 1))
        #expect(await fx.waitUntil { fx.link.updates().filter { $0.kind == .done }.count == 2 })
        let expected = WatchAnswerText.render(Self.raw, final: true)
        #expect(Self.watchText(fx.link.updates(), turn: 2) == expected)
    }
}

// MARK: - Fixture

private final class PushToTalkFixture: @unchecked Sendable {
    let link = FakeAssistantLink()
    let muse: FakeMuse
    let preferences = MusePreferencesStore(defaults: UserDefaults(suiteName: "muse-ptt-\(UUID().uuidString)")!)
    let pairedName = StateSubject<String?>("MuseGadgetABC123")
    let service: MusePushToTalk

    let data = FakeData()

    /// `listening`: Muse's own messages are followed (off unless a test is about them).
    init(paired: Bool = true, holdLimit: Duration = .seconds(30), listening: Bool = false) {
        muse = FakeMuse(paired: paired)
        preferences.update { $0.messagesOnWatch = listening }
        service = MusePushToTalk(
            link: link, connector: muse, preferences: preferences, data: data, toolHoldLimit: holdLimit,
            messageRetryDelay: .milliseconds(50))
    }

    /// The watch picks option `index` of turn `turn`'s answer.
    func pick(turn: Int, index: Int) {
        link.push(.pttEvent(PttEvent(turn: turn, eventRaw: PttEventKind.pick.rawValue, detail: UInt8(index))))
    }

    /// Answers the next watch action the way the watch would, once it has been sent.
    func answerNextAction(status: WatchActionStatus, value: Int = 0, text: String = "") async -> WatchAction? {
        let before = link.actions().count
        guard await waitUntil({ self.link.actions().count > before }) else { return nil }
        let action = link.actions()[before]
        link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: status.rawValue, value: value, text: Array(text.utf8))))
        return action
    }

    func start() async {
        await service.start(paired: pairedName)
    }

    /// Real Speex frames of a quiet voice-band tone (about -46 dBFS, like the watch).
    func frames(count: Int) throws -> [[UInt8]] {
        let encoder = try SpeexFrameEncoder()
        let amplitude = 0.005 * 32768 * 2.0.squareRoot()
        return try (0..<count).map { index in
            let samples = (0..<320).map { i in
                Int16((amplitude * sin(2 * .pi * 300 * Double(index * 320 + i) / 16_000)).rounded())
            }
            return [UInt8](try encoder.encodeFrame(samples))
        }
    }

    /// Press, speak for `seconds`, release: the watch's side of one question.
    func ask(turn: Int, seconds: Double, dropping: Set<Int> = []) throws {
        let count = Int(seconds * 50)
        link.push(.pttEvent(PttEvent(turn: turn, eventRaw: PttEventKind.start.rawValue, detail: PttTrigger.inApp.rawValue, maxSeconds: 15)))
        let all = try frames(count: count)
        // Eight frames a message; a dropped frame is a hole in the numbering, and every message
        // says where it starts.
        var first = 0
        while first < count {
            var start = first
            var run: [[UInt8]] = []
            for index in first..<min(first + 8, count) {
                if dropping.contains(index) {
                    if !run.isEmpty { link.push(.pttAudio(PttAudio(turn: turn, firstFrame: start, frames: run))) }
                    run = []
                    start = index + 1
                } else {
                    run.append(all[index])
                }
            }
            if !run.isEmpty { link.push(.pttAudio(PttAudio(turn: turn, firstFrame: start, frames: run))) }
            first += 8
        }
        link.push(.pttEvent(PttEvent(turn: turn, eventRaw: PttEventKind.end.rawValue, detail: PttEndReason.released.rawValue, frameCount: count)))
    }

    func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 100) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class FakeAssistantLink: MuseAssistantLink, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AudioReceiverSession.AssistantInbound) -> Void)?
    private var sent: [[UInt8]] = []
    private var replies: [AudioReceiverSession.MuseSetupReply] = []
    private var token = 0
    private var _quietLink: [Bool] = []
    private var _resultBeforeAck = false
    var resultBeforeAck: Bool {
        get { lock.withLock { _resultBeforeAck } }
        set { lock.withLock { _resultBeforeAck = newValue } }
    }
    private var _capabilities: UInt32? = ProtocolConstants.capabilityPushToTalk | ProtocolConstants.capabilityAnswerRestart

    var quietLink: [Bool] { lock.withLock { _quietLink } }
    var watchCapabilities: UInt32? {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }

    func scriptReplies(_ scripted: [AudioReceiverSession.MuseSetupReply]) {
        lock.withLock { replies = scripted }
    }

    func sendControlRequest(_ build: @escaping @Sendable (Int) -> [UInt8]) async -> AudioReceiverSession.MuseSetupReply {
        let (reply, action): (AudioReceiverSession.MuseSetupReply, WatchAction?) = lock.withLock {
            token = token % 255 + 1
            let bytes = build(token)
            let reply = replies.isEmpty ? .ok : replies.removeFirst()
            if reply == .ok || _resultBeforeAck { sent.append(bytes) }
            var action: WatchAction?
            if _resultBeforeAck, case .decoded(let message) = AudioCompanionProtocol.decodeControlIn(bytes) {
                action = message as? WatchAction
            }
            return (reply, action)
        }
        if let action {
            push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.done.rawValue, value: 2)))
            try? await Task.sleep(for: .milliseconds(50))
        }
        return reply
    }

    func setAssistantHandler(_ handler: (@Sendable (AudioReceiverSession.AssistantInbound) -> Void)?) async {
        lock.withLock { self.handler = handler }
    }

    func setQuietLink(_ wanted: Bool) async {
        lock.withLock { _quietLink.append(wanted) }
    }

    func push(_ inbound: AudioReceiverSession.AssistantInbound) {
        let handler = lock.withLock { self.handler }
        handler?(inbound)
    }

    private func messages() -> [ControlInMessage] {
        lock.withLock { sent }.compactMap { bytes in
            if case .decoded(let message) = AudioCompanionProtocol.decodeControlIn(bytes) {
                return message as? ControlInMessage
            }
            return nil
        }
    }

    func updates() -> [AssistantUpdate] { messages().compactMap { $0 as? AssistantUpdate } }
    func actions() -> [WatchAction] { messages().compactMap { $0 as? WatchAction } }
}

private final class FakeMuse: MuseVoiceConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let paired: Bool
    private var _script: [MuseQuestionEvent] = []
    private var _replyScript: [MuseQuestionEvent] = []
    private var _toolCall: (String, MuseJSON)?
    private var _toolResults: [MuseJSON] = []
    private var handler: MuseLinkSession.CommandHandler?
    private var _notes: [Data] = []
    private var _replies: [String] = []
    private var _opens = 0
    private var _openFailure: MuseQuestionFailure?
    private var _done = true
    private var _chat: [([MuseChatMessage], Set<String>)] = []
    private var _following = 0
    private var _askFailures: [MuseQuestionFailure] = []
    private var _chatIDs: [String?] = []

    init(paired: Bool) { self.paired = paired }

    var isPaired: Bool { paired }
    var script: [MuseQuestionEvent] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var replyScript: [MuseQuestionEvent] {
        get { lock.withLock { _replyScript } }
        set { lock.withLock { _replyScript = newValue } }
    }
    var notes: [Data] { lock.withLock { _notes } }
    var replies: [String] { lock.withLock { _replies } }
    /// A call Muse makes in the middle of answering, before its scripted events.
    var toolCall: (String, MuseJSON)? {
        get { lock.withLock { _toolCall } }
        set { lock.withLock { _toolCall = newValue } }
    }
    var toolResults: [MuseJSON] { lock.withLock { _toolResults } }
    var opens: Int { lock.withLock { _opens } }
    /// False: the question ends at its deadline with Muse still at work.
    var done: Bool {
        get { lock.withLock { _done } }
        set { lock.withLock { _done = newValue } }
    }
    /// How many times the chat has been followed.
    var following: Int { lock.withLock { _following } }
    /// Messages Muse finishes on the chat, handed to whoever follows it.
    func post(_ messages: [MuseChatMessage], typedElsewhere: Set<String> = []) {
        lock.withLock { _chat.append((messages, typedElsewhere)) }
    }
    fileprivate func nextPosted() -> ([MuseChatMessage], Set<String>)? {
        lock.withLock { _chat.isEmpty ? nil : _chat.removeFirst() }
    }
    fileprivate func startedFollowing() { lock.withLock { _following += 1 } }
    var openFailure: MuseQuestionFailure? {
        get { lock.withLock { _openFailure } }
        set { lock.withLock { _openFailure = newValue } }
    }
    /// Thrown by the next asks, one each, before Muse takes a note.
    var askFailures: [MuseQuestionFailure] {
        get { lock.withLock { _askFailures } }
        set { lock.withLock { _askFailures = newValue } }
    }
    /// The chat each link was opened on.
    var chatIDs: [String?] { lock.withLock { _chatIDs } }
    fileprivate func nextAskFailure() -> MuseQuestionFailure? {
        lock.withLock { _askFailures.isEmpty ? nil : _askFailures.removeFirst() }
    }

    func open(
        chatID: String?, commands: MuseJSON, handler: @escaping MuseLinkSession.CommandHandler
    ) async throws(MuseQuestionFailure) -> any MuseVoiceConversation {
        if let failure = openFailure { throw failure }
        lock.withLock {
            _opens += 1
            _chatIDs.append(chatID)
            self.handler = handler
        }
        return Conversation(muse: self)
    }

    /// Calls the gadget's handler as Muse would at any time; nil before a link was opened.
    func call(_ command: String, _ params: MuseJSON) async -> MuseJSON? {
        let handler = lock.withLock { self.handler }
        return await handler?(command, params, nil, UUID().uuidString)
    }

    /// Runs the scripted call through the gadget's handler, as Muse would mid-answer.
    fileprivate func callTool() async {
        let (call, handler) = lock.withLock { (_toolCall, self.handler) }
        guard let call, let handler else { return }
        let result = await handler(call.0, call.1, nil, UUID().uuidString)
        lock.withLock { _toolResults.append(result) }
    }

    fileprivate func took(_ wav: Data) -> [MuseQuestionEvent] {
        lock.withLock {
            _notes.append(wav)
            return _script
        }
    }

    fileprivate func took(reply text: String) -> [MuseQuestionEvent] {
        lock.withLock {
            _replies.append(text)
            return _replyScript
        }
    }

    private final class Conversation: MuseVoiceConversation, @unchecked Sendable {
        let muse: FakeMuse
        init(muse: FakeMuse) { self.muse = muse }
        var isOpen: Bool { get async { true } }
        func close() async {}
        func ask(
            wav: Data, instructions: String, timeout: Duration,
            onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
        ) async throws -> Bool {
            if let failure = muse.nextAskFailure() { throw failure }
            await muse.callTool()
            for event in muse.took(wav) { await onEvent(event) }
            return muse.done
        }
        func reply(
            text: String, timeout: Duration, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
        ) async throws -> Bool {
            for event in muse.took(reply: text) { await onEvent(event) }
            return true
        }
        func followChat(onMessages: @escaping @Sendable ([MuseChatMessage], Set<String>) async -> Void) async throws {
            muse.startedFollowing()
            while !Task.isCancelled {
                if let (messages, typed) = muse.nextPosted() { await onMessages(messages, typed) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

private final class FakeData: MuseDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _followUps: [MuseFollowUp] = [MuseFollowUp(id: "f1", text: "Send Sam the deck", due: nil)]
    private var _decided: [String] = []
    private var _paused: Int?
    private var _marks: [String?] = []
    private var _searches: [(Date, Date, String?)] = []

    var followUps: [MuseFollowUp] { lock.withLock { _followUps } }
    var decided: [String] { lock.withLock { _decided } }
    var paused: Int? { lock.withLock { _paused } }
    var marks: [String?] { lock.withLock { _marks } }
    var searches: [(Date, Date, String?)] { lock.withLock { _searches } }

    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText] {
        lock.withLock { _searches.append((from, to, query)) }
        return [MuseConversationText(start: from, end: to, title: "Budget", text: "Alex: the budget is fine.")]
    }

    func answerFromRecordings(_ question: String) async -> String? { "Alex said the budget is fine." }
    func recap(day: Date, week: Bool) async -> String? { week ? nil : "A quiet day." }
    func reminderHome() async -> ReminderHome { .app }
    func appReminders(completedSince: Date?) async -> [MuseAppReminder] { [] }
    func appReminder(id: String) async -> MuseAppReminder? { nil }
    func addAppReminder(title: String, due: Date?) async -> MuseAppReminder? { nil }
    func updateAppReminder(id: String, _ change: MuseEventKitSource.ReminderChange) async -> MuseAppReminder? { nil }
    func fileAwayAppReminder(id: String) async -> MuseAppReminder? { nil }
    func followUpsToReview(limit: Int) async -> [MuseFollowUp] { followUps }
    func decideFollowUp(id: String, remind: Bool) async -> MuseFollowUpDecision? {
        lock.withLock {
            guard let index = _followUps.firstIndex(where: { $0.id == id }) else { return nil }
            let item = _followUps.remove(at: index)
            _decided.append("\(id): \(remind ? "remind" : "skip")")
            return MuseFollowUpDecision(
                id: id, title: item.text, keptInApple: false, list: "Pebble Audio", reminderID: "pa:\(id)")
        }
    }
    func pauseRecording(minutes: Int) async -> Bool {
        lock.withLock { _paused = minutes }
        return true
    }
    func resumeRecording() async -> Bool { true }
    func markMoment(_ label: String?) async -> Bool {
        lock.withLock { _marks.append(label) }
        return true
    }
}

/// Muse reaching the wearer's data: Ask first, with the watch asking.
struct MuseToolsTests {
    @Test func allowOnceLetsThisQuestionReadAndTheNextOneAsksAgain() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "steps"]) }
        _ = try #require(await fx.answerNextAction(status: .done, value: 0))
        // The health read itself, on the watch.
        _ = try #require(await fx.answerNextAction(status: .done, text: "8100"))
        #expect((await reply.value)["ok"]?.bool == true)
        #expect(fx.preferences.current.value.access(.health) == .ask)

        // Another read for the same answer goes straight through.
        let before = fx.link.actions().count
        let again = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "distance"]) }
        _ = try #require(await fx.answerNextAction(status: .done, text: "6200"))
        #expect((await again.value)["ok"]?.bool == true)
        #expect(fx.link.actions().count == before + 1)

        // A new question asks again.
        fx.link.push(.pttEvent(PttEvent(turn: 9, eventRaw: PttEventKind.start.rawValue, detail: PttTrigger.inApp.rawValue, maxSeconds: 15)))
        try await Task.sleep(for: .milliseconds(50))
        let next = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "steps"]) }
        let prompt = try #require(await fx.answerNextAction(status: .done, value: 2))
        #expect(WatchActionRequest.parse(prompt.payload).map { if case .choose = $0 { true } else { false } } == true)
        #expect((await next.value)["ok"]?.bool == false)
    }

    @Test func heartRateComesByDayWithTheLatestReading() async throws {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.health] = .allowed }
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "heart_rate", "days": 2]) }
        let latest = try #require(await fx.answerNextAction(status: .done, text: "72,300"))
        #expect(WatchActionRequest.parse(latest.payload) == .health(.heartRate, days: 1))
        let daily = try #require(await fx.answerNextAction(status: .done, text: "70/55/140,-1"))
        #expect(WatchActionRequest.parse(daily.payload) == .health(.heartRateDaily, days: 2))
        let payload = try #require((await reply.value)["payload"])
        #expect(payload["latest"]?["bpm"]?.number == 72)
        #expect(payload["days"]?.array?.first?["average_bpm"]?.number == 70)
        #expect(payload["days"]?.array?.first?["highest_bpm"]?.number == 140)
        #expect(payload["days"]?.array?.last?["average_bpm"] == .null)

        // Monitoring off is said as such, not as "no data".
        let off = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "heart_rate"]) }
        _ = try #require(await fx.answerNextAction(status: .failed, text: WatchActionRequest.heartRateOff))
        #expect((await off.value)["error"]?.string?.hasPrefix("heart_rate_off:") == true)
    }

    @Test func theFirstUseIsAskedOnTheWatchAndAlwaysAllowIsKept() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        #expect(fx.preferences.current.value.access(.followUps) == .ask)
        let reply = Task { await fx.service.runCommand(MuseTools.followUpsCommand, ["action": "list"]) }
        let prompt = try #require(await fx.answerNextAction(status: .done, value: 1))
        guard case .choose(let question, let options, _)? = WatchActionRequest.parse(prompt.payload) else {
            Issue.record("the prompt wasn't a choice")
            return
        }
        #expect(question == "Let Muse read your follow-ups? What it reads goes to Meta.")
        #expect(options == ["Allow Once", "Always Allow", "Not Now", "Never Allow"])
        let result = await reply.value
        #expect(result["payload"]?["follow_ups"]?.array?.first?["task"]?.string == "Send Sam the deck")
        #expect(fx.preferences.current.value.access(.followUps) == .allowed)

        // Allowed: the next call goes straight through, with no question on the watch.
        let before = fx.link.actions().count
        let again = await fx.service.runCommand(MuseTools.followUpsCommand, ["action": "remind", "id": "f1"])
        #expect(again["payload"]?["reminder"]?["list"]?.string == "Pebble Audio")
        #expect(fx.link.actions().count == before)
        #expect(fx.data.decided == ["f1: remind"])
    }

    @Test func notNowRefusesOnceAndAsksAgainNextTime() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.conversationsCommand, ["action": "search", "query": "budget"]) }
        let prompt = try #require(await fx.answerNextAction(status: .done, value: 2))
        if case .choose(let question, _, _)? = WatchActionRequest.parse(prompt.payload) {
            #expect(question == "Let Muse read your conversations? What it reads, including what others said, goes to Meta.")
        }
        let result = await reply.value
        #expect(result["ok"]?.bool == false)
        #expect(result["error"]?.string == "The person said not now. Do not ask for their conversations again in this conversation.")
        #expect(fx.data.searches.isEmpty)
        #expect(fx.preferences.current.value.access(.conversations) == .ask)
    }

    @Test func neverAllowTurnsTheSourceOffAndHidesIt() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "steps"]) }
        _ = try #require(await fx.answerNextAction(status: .done, value: 3))
        #expect((await reply.value)["error"]?.string == "The person does not allow Muse to read their health data. Do not ask for it again.")
        #expect(fx.preferences.current.value.access(.health) == .off)
        let offered = MuseTools.commands(for: fx.preferences.current.value, hasData: true)
        #expect(offered[MuseTools.healthCommand] == nil)
        #expect(offered[MuseTools.conversationsCommand] != nil)
    }

    @Test func noAnswerOnTheWatchIsNotPermission() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.followUpsCommand, ["action": "list"]) }
        _ = try #require(await fx.answerNextAction(status: .timedOut))
        #expect((await reply.value)["error"]?.string == "The person has not answered yet. You can ask again later.")
        #expect(fx.preferences.current.value.access(.followUps) == .ask)
    }

    @Test func allowedWithoutIOSAccessHoldsTheCallAndQueuesThePrompt() async throws {
        guard !MuseEventKitSource.calendarAuthorized, !MuseEventKitSource.calendarRefused else { return }
        let fx = PushToTalkFixture(holdLimit: .seconds(3))
        await fx.start()
        let started = ContinuousClock.now
        let reply = Task { await fx.service.runCommand(MuseTools.calendarCommand, ["action": "list"]) }
        _ = try #require(await fx.answerNextAction(status: .done, value: 1))
        // The watch is told what to do on the phone, in the model's words.
        let notice = try #require(await fx.answerNextAction(status: .done))
        #expect(WatchActionRequest.parse(notice.payload) == .notice("Open Pebble Audio on your iPhone to give it access to your calendar."))
        let result = await reply.value
        // Held open until the limit, then not answered: Muse may ask again later.
        #expect(ContinuousClock.now - started >= .seconds(3))
        #expect(result["error"]?.string == "The person has not answered yet. You can ask again later.")
        #expect(fx.preferences.current.value.access(.calendar) == .allowed)
        #expect(fx.preferences.current.value.pendingPhoneAccess == [.calendar])
    }

    @Test func anOffSourceIsRefusedPlainly() async {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.reminders] = .off }
        await fx.start()
        let result = await fx.service.runCommand(MuseTools.remindersCommand, ["action": "list"])
        if !MuseEventKitSource.remindersRefused {
            #expect(result["error"]?.string == "The person does not allow Muse to read their reminders. Do not ask for it again.")
        }
        let prompts = fx.link.actions().filter { action in
            if case .choose = WatchActionRequest.parse(action.payload) { return true }
            return false
        }
        #expect(prompts.isEmpty)
    }

    @Test func healthComesFromTheWatchAsDailyValues() async throws {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.health] = .allowed }
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "sleep", "days": 2]) }
        let action = try #require(await fx.answerNextAction(status: .done, text: "27000,-1"))
        #expect(WatchActionRequest.parse(action.payload) == .health(.sleepSeconds, days: 2))
        let days = try #require((await reply.value)["payload"]?["days"]?.array)
        #expect(days.count == 2)
        #expect(days[0]["sleep_minutes"]?.number == 450)
        #expect(days[1]["sleep_minutes"] == .null)
    }

    @Test func musicSaysWhatIsPlaying() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.musicCommand, ["action": "now_playing"]) }
        let action = try #require(await fx.answerNextAction(status: .done, text: "Clair de lune\nDebussy"))
        #expect(WatchActionRequest.parse(action.payload) == .music(.nowPlaying))
        let result = await reply.value
        #expect(result["payload"]?["title"]?.string == "Clair de lune")
        #expect(result["payload"]?["artist"]?.string == "Debussy")
    }

    @Test func recordingControlNeedsNoQuestion() async {
        let fx = PushToTalkFixture()
        await fx.start()
        let paused = await fx.service.runCommand(MuseTools.recordingCommand, ["action": "pause", "minutes": 30])
        #expect(paused["ok"]?.bool == true)
        #expect(fx.data.paused == 30)
        let marked = await fx.service.runCommand(MuseTools.recordingCommand, ["action": "mark", "label": "parking spot"])
        #expect(marked["ok"]?.bool == true)
        #expect(fx.data.marks == ["parking spot"])
        #expect(fx.link.actions().isEmpty)
    }

    @Test func aRecapAndAnAnswerComeFromThePhone() async {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.conversations] = .allowed }
        await fx.start()
        let recap = await fx.service.runCommand(MuseTools.conversationsCommand, ["action": "recap", "date": "2026-10-20"])
        #expect(recap["payload"]?["recap"]?.string == "A quiet day.")
        let answer = await fx.service.runCommand(MuseTools.conversationsCommand, ["action": "ask", "query": "What did Alex say?"])
        #expect(answer["payload"]?["answer"]?.string == "Alex said the budget is fine.")
        let search = await fx.service.runCommand(
            MuseTools.conversationsCommand, ["action": "search", "query": "budget", "from": "2026-10-20", "to": "2026-10-20"])
        #expect(search["payload"]?["conversations"]?.array?.count == 1)
        let range = try? #require(fx.data.searches.last)
        #expect(range?.2 == "budget")
        // A bare "to" date reaches the end of that day.
        if let range { #expect(range.1.timeIntervalSince(range.0) == 24 * 60 * 60) }
    }

    @Test func datesAreReadInTheirCommonForms() {
        #expect(MuseTools.date("2026-10-21T15:00:00-05:00")?.hasTime == true)
        #expect(MuseTools.date("2026-10-21T15:00:00.250Z") != nil)
        #expect(MuseTools.date("2026-10-21 09:30")?.hasTime == true)
        #expect(MuseTools.date("2026-10-21")?.hasTime == false)
        #expect(MuseTools.date("tomorrow") == nil)
    }

    @Test func reversedConversationRangeIsAnErrorBeforeTheProvider() async {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.dataAccess[.conversations] = .allowed }
        await fx.start()
        let result = await fx.service.runCommand(MuseTools.conversationsCommand,
            ["action": "search", "from": "2026-10-28", "to": "2026-10-26"])
        #expect(result["ok"]?.bool == false)
    }

    @Test func everyCommandIsOfferedOnlyWhileItsSwitchAllows() {
        let all = MuseTools.commands(for: MusePreferences(), hasData: true).object ?? [:]
        #expect(all.count == 14)
        let none = MuseTools.commands(
            for: MusePreferences(watchActions: [], dataAccess: Dictionary(uniqueKeysWithValues: MuseSource.allCases.map { ($0, .off) })),
            hasData: true).object ?? [:]
        #expect(none.isEmpty)
        // Without the app's data, the tools that need it aren't offered.
        let noData = MuseTools.commands(for: MusePreferences(), hasData: false).object ?? [:]
        #expect(noData[MuseTools.conversationsCommand] == nil)
        #expect(noData[MuseTools.recordingCommand] == nil)
        #expect(noData[MuseTools.calendarCommand] != nil)
    }
}

