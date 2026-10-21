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
        try fx.ask(turn: 3, seconds: 1, dropping: [10, 11, 12])
        #expect(await fx.waitUntil { fx.link.updates().last?.kind == .done })
        let note = try #require(fx.muse.notes.first)
        #expect(note.count == PcmWav.headerBytes + 50 * 320 * 2)
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
        try fx.ask(turn: 4, seconds: 0.1)
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

    // MARK: - Watch actions

    @Test func aTimerIsSetOnTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.timerCommand, ["seconds": 90, "label": "Pasta"]) }
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let action = try #require(fx.link.actions().first)
        #expect(WatchActionRequest.parse(action.payload) == .timer(seconds: 90, label: "Pasta"))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.done.rawValue)))
        let result = await reply.value
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["seconds"]?.number == 90)
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
        #expect(offered.object?.keys.sorted() == [MuseTools.timerCommand])
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

// MARK: - Fixture

private final class PushToTalkFixture: @unchecked Sendable {
    let link = FakeAssistantLink()
    let muse: FakeMuse
    let preferences = MusePreferencesStore(defaults: UserDefaults(suiteName: "muse-ptt-\(UUID().uuidString)")!)
    let pairedName = StateSubject<String?>("MuseGadgetABC123")
    let service: MusePushToTalk

    let data = FakeData()

    init(paired: Bool = true, holdLimit: Duration = .seconds(30)) {
        muse = FakeMuse(paired: paired)
        service = MusePushToTalk(
            link: link, connector: muse, preferences: preferences, data: data, toolHoldLimit: holdLimit)
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

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
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
        lock.withLock {
            token = token % 255 + 1
            let bytes = build(token)
            let reply = replies.isEmpty ? .ok : replies.removeFirst()
            if reply == .ok { sent.append(bytes) }
            return reply
        }
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
    private var _notes: [Data] = []
    private var _replies: [String] = []
    private var _opens = 0
    private var _openFailure: MuseQuestionFailure?

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
    var opens: Int { lock.withLock { _opens } }
    var openFailure: MuseQuestionFailure? {
        get { lock.withLock { _openFailure } }
        set { lock.withLock { _openFailure = newValue } }
    }

    func open(
        chatID: String?, commands: MuseJSON, handler: @escaping MuseLinkSession.CommandHandler
    ) async throws(MuseQuestionFailure) -> any MuseVoiceConversation {
        if let failure = openFailure { throw failure }
        lock.withLock { _opens += 1 }
        return Conversation(muse: self)
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
            for event in muse.took(wav) { await onEvent(event) }
            return true
        }
        func reply(
            text: String, timeout: Duration, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
        ) async throws -> Bool {
            for event in muse.took(reply: text) { await onEvent(event) }
            return true
        }
    }
}

private final class FakeData: MuseDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _followUps: [MuseFollowUp] = [MuseFollowUp(text: "Send Sam the deck", due: nil)]
    private var _paused: Int?
    private var _marks: [String?] = []
    private var _searches: [(Date, Date, String?)] = []

    var followUps: [MuseFollowUp] { lock.withLock { _followUps } }
    var paused: Int? { lock.withLock { _paused } }
    var marks: [String?] { lock.withLock { _marks } }
    var searches: [(Date, Date, String?)] { lock.withLock { _searches } }

    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText] {
        lock.withLock { _searches.append((from, to, query)) }
        return [MuseConversationText(start: from, end: to, title: "Budget", text: "Alex: the budget is fine.")]
    }

    func answerFromRecordings(_ question: String) async -> String? { "Alex said the budget is fine." }
    func recap(day: Date, week: Bool) async -> String? { week ? nil : "A quiet day." }
    func openFollowUps(limit: Int) async -> [MuseFollowUp] { followUps }
    func addFollowUp(_ text: String, due: Date?) async -> Bool {
        lock.withLock { _followUps.append(MuseFollowUp(text: text, due: due)) }
        return true
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
    @Test func theFirstUseIsAskedOnTheWatchAndAllowIsKept() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        #expect(fx.preferences.current.value.access(.followUps) == .ask)
        let reply = Task { await fx.service.runCommand(MuseTools.followUpsCommand, ["action": "list"]) }
        let prompt = try #require(await fx.answerNextAction(status: .done, value: 0))
        guard case .choose(let question, let options, _)? = WatchActionRequest.parse(prompt.payload) else {
            Issue.record("the prompt wasn't a choice")
            return
        }
        #expect(question == "Let Muse read your follow-ups? What it reads goes to Meta.")
        #expect(options == ["Allow", "Not Now", "Don't Allow"])
        let result = await reply.value
        #expect(result["payload"]?["follow_ups"]?.array?.first?["text"]?.string == "Send Sam the deck")
        #expect(fx.preferences.current.value.access(.followUps) == .allowed)

        // Allowed: the next call goes straight through, with no question on the watch.
        let before = fx.link.actions().count
        let again = await fx.service.runCommand(MuseTools.followUpsCommand, ["action": "add", "text": "Book flights"])
        #expect(again["ok"]?.bool == true)
        #expect(fx.link.actions().count == before)
        #expect(fx.data.followUps.map(\.text) == ["Send Sam the deck", "Book flights"])
    }

    @Test func notNowRefusesOnceAndAsksAgainNextTime() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.conversationsCommand, ["action": "search", "query": "budget"]) }
        let prompt = try #require(await fx.answerNextAction(status: .done, value: 1))
        if case .choose(let question, _, _)? = WatchActionRequest.parse(prompt.payload) {
            #expect(question == "Let Muse read your conversations? What it reads, including what others said, goes to Meta.")
        }
        let result = await reply.value
        #expect(result["ok"]?.bool == false)
        #expect(result["error"]?.string == "The person said not now. Do not ask for their conversations again in this conversation.")
        #expect(fx.data.searches.isEmpty)
        #expect(fx.preferences.current.value.access(.conversations) == .ask)
    }

    @Test func dontAllowTurnsTheSourceOffAndHidesIt() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MuseTools.healthCommand, ["metric": "steps"]) }
        _ = try #require(await fx.answerNextAction(status: .done, value: 2))
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
        _ = try #require(await fx.answerNextAction(status: .done, value: 0))
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

    @Test func everyCommandIsOfferedOnlyWhileItsSwitchAllows() {
        let all = MuseTools.commands(for: MusePreferences(), hasData: true).object ?? [:]
        #expect(all.count == 12)
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

