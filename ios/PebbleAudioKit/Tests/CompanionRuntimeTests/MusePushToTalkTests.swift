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

    // MARK: - Watch actions

    @Test func aTimerIsSetOnTheWatch() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task { await fx.service.runCommand(MusePushToTalk.timerCommand, ["seconds": 90, "label": "Pasta"]) }
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let action = try #require(fx.link.actions().first)
        #expect(WatchActionRequest.parse(action.payload) == .timer(seconds: 90, label: "Pasta"))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: action.actionId, statusRaw: WatchActionStatus.done.rawValue)))
        let result = await reply.value
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["seconds"]?.number == 90)
    }

    @Test func aChoiceComesBackAsTheOptionPicked() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task {
            await fx.service.runCommand(
                MusePushToTalk.choiceCommand,
                ["question": "Which table?", "options": "Window\n- Bar\nPatio", "timeout_seconds": 30])
        }
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        let actions = fx.link.actions()
        let joined = actions.flatMap(\.payload)
        #expect(WatchActionRequest.parse(joined) == .choose(question: "Which table?", options: ["Window", "Bar", "Patio"], timeoutSeconds: 30))
        fx.link.push(.watchActionResult(WatchActionResult(actionId: actions[0].actionId, statusRaw: WatchActionStatus.done.rawValue, value: 2)))
        let result = await reply.value
        #expect(result["payload"]?["chosen"]?.string == "Patio")
    }

    @Test func aDeclinedChoiceIsAnAnswerToo() async throws {
        let fx = PushToTalkFixture()
        await fx.start()
        let reply = Task {
            await fx.service.runCommand(MusePushToTalk.choiceCommand, ["question": "Tea?", "options": ["Yes", "No"]])
        }
        #expect(await fx.waitUntil { !fx.link.actions().isEmpty })
        fx.link.push(.watchActionResult(WatchActionResult(actionId: fx.link.actions()[0].actionId, statusRaw: WatchActionStatus.declined.rawValue)))
        let result = await reply.value
        #expect(result["ok"]?.bool == true)
        #expect(result["payload"]?["declined"]?.bool == true)
    }

    @Test func anActionTurnedOffIsRefusedWithoutTouchingTheWatch() async {
        let fx = PushToTalkFixture()
        fx.preferences.update { $0.watchActions = [.choice] }
        await fx.start()
        let result = await fx.service.runCommand(MusePushToTalk.alarmCommand, ["hour": 7, "minute": 30])
        #expect(result["ok"]?.bool == false)
        #expect(fx.link.actions().isEmpty)
        // And it was never offered to Muse.
        #expect(MusePushToTalk.commands(for: [.choice]).object?.keys.sorted() == [MusePushToTalk.choiceCommand])
    }

    @Test func badParametersAreRefused() async {
        let fx = PushToTalkFixture()
        await fx.start()
        let result = await fx.service.runCommand(MusePushToTalk.timerCommand, ["seconds": 0])
        #expect(result["ok"]?.bool == false)
        let choice = await fx.service.runCommand(MusePushToTalk.choiceCommand, ["question": "Pick", "options": "Only one"])
        #expect(choice["ok"]?.bool == false)
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

    init(paired: Bool = true) {
        muse = FakeMuse(paired: paired)
        service = MusePushToTalk(link: link, connector: muse, preferences: preferences)
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

    var quietLink: [Bool] { lock.withLock { _quietLink } }

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
    private var _notes: [Data] = []
    private var _opens = 0
    private var _openFailure: MuseQuestionFailure?

    init(paired: Bool) { self.paired = paired }

    var isPaired: Bool { paired }
    var script: [MuseQuestionEvent] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var notes: [Data] { lock.withLock { _notes } }
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
    }
}
