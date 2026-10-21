import AudioCodec
import Foundation
import MuseLink
import Receiver
import WireProtocol

/// The audio companion link as push-to-talk needs it. `ReceiverService` is the real one.
public protocol MuseAssistantLink: Sendable {
    func sendControlRequest(_ build: @escaping @Sendable (Int) -> [UInt8]) async -> AudioReceiverSession.MuseSetupReply
    func setAssistantHandler(_ handler: (@Sendable (AudioReceiverSession.AssistantInbound) -> Void)?) async
    func setQuietLink(_ wanted: Bool) async
    /// The watch's Info `watch_capabilities`, nil before it has been read.
    var watchCapabilities: UInt32? { get }
}

extension ReceiverService: MuseAssistantLink {}

/// Questions asked on the watch, answered by Muse (protocol Sections 4.4 and 4.5).
///
/// The watch holds the button and streams the question's Speex frames as they are spoken. At the
/// press this opens a link to Muse, so it is ready by the release; at the release the frames are
/// decoded, brought to a level a recognizer can hear, and sent as one voice note. What Muse heard,
/// what it is doing and its answer go back to the watch as they arrive. While it answers, Muse
/// may set a timer or an alarm on the watch. An answer that ends on Muse's own buttons becomes a
/// picker on the watch, and the pick goes back to Muse as the wearer's reply.
public actor MusePushToTalk: MuseWatchSide {
    /// The last question, for the Muse screen: what Muse heard, and what was done to the audio.
    public struct QuestionReport: Equatable, Sendable {
        public let askedAt: Date
        public let seconds: Double
        /// Frames the watch counted that never arrived (shown as silence in the note).
        public let missingFrames: Int
        public let level: VoiceNoteLevel.Report?
        public var heard: String?
        public var answered: Bool
        public var problem: AssistantError?
        /// Muse's answer, as the watch showed it.
        public var answer: String?
        /// What Muse asked of the watch or the phone while answering, in order.
        public var tools: [MuseToolUse]

        public init(
            askedAt: Date, seconds: Double, missingFrames: Int, level: VoiceNoteLevel.Report?,
            heard: String?, answered: Bool, problem: AssistantError?, answer: String? = nil,
            tools: [MuseToolUse] = []
        ) {
            self.askedAt = askedAt
            self.seconds = seconds
            self.missingFrames = missingFrames
            self.level = level
            self.heard = heard
            self.answered = answered
            self.problem = problem
            self.answer = answer
            self.tools = tools
        }
    }

    public nonisolated let lastQuestion = StateSubject<QuestionReport?>(nil)

    /// A check of the voice level against Muse itself: the next question is also sent at each of
    /// `levelCheckTargets`, to a chat of its own, and what Muse heard at each is kept side by
    /// side. It is how the automatic target was chosen, and how a wearer can check it.
    public struct LevelCheck: Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case waiting, running, done, failed }
        public struct Result: Equatable, Sendable {
            public let targetDBFS: Double
            public let gainDB: Double
            public var heard: String?
        }

        public var phase: Phase
        public var speechLevelDBFS: Double?
        public var results: [Result]
    }

    public nonisolated let levelCheck = StateSubject<LevelCheck?>(nil)
    public static let levelCheckTargets: [Double] = [-30, -26, -22, -18]
    /// Where Automatic puts the loud end of a question's speech.
    public static let automaticTargetDBFS = VoiceNoteLevel.Settings.automaticTargetDBFS
    static let levelCheckInstructions =
        "This is a test recording. Reply with exactly the words spoken in it, and nothing else."

    /// What Muse is told with every question. Not the person's words: how to answer them.
    /// The recording comes from a small wrist microphone, so Muse is told to answer what was most
    /// likely meant: taken literally, a misheard word sent it off on the wrong question.
    static let instructions =
        "Asked out loud on a Pebble watch. The recording is from a small wrist microphone and may be "
        + "quiet or unclear: answer what I most likely meant rather than taking odd words literally, "
        + "and ask if you really can't tell. Your reply is read as plain text on the watch's small "
        + "screen: answer in a few short sentences, without tables, images or links."
    /// The longest Muse may take over an answer: room for a call Muse makes (it ends one at about
    /// two minutes) and the answer after it, or for the person to approve a step on their phone.
    static let answerTimeout: Duration = .seconds(240)
    /// A link to Muse stays open this long after an answer, for a follow-up.
    static let followUpWindow: Duration = .seconds(60)
    /// How long the watch shows a choice Muse offered, and how many in a row it follows.
    static let choiceSeconds = 120
    static let maxChoiceRounds = 5
    /// The picker's heading when Muse's answer names no question.
    static let choiceQuestion = "Your answer"
    /// Beside a single button: not picking it.
    static let leaveIt = "Not now"
    /// Fewer frames than this (0.2 s) is not a question.
    static let minimumFrames = 10
    /// The watch keeps 1536 bytes of an answer; past that it shows an ellipsis.
    static let watchAnswerBytes = 1_536

    private let link: any MuseAssistantLink
    private let connector: any MuseVoiceConnector
    private let preferences: MusePreferencesStore
    private let keepAwake: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    private final class Turn {
        /// Unique for the life of the process; the watch's turn numbers wrap at 255.
        let serial: Int
        let id: Int
        let trigger: PttTrigger?
        let startedAt = Date()
        var frames: [Int: Data] = [:]
        var frameCount: Int?
        var opening: Task<any MuseVoiceConversation, Error>?
        var finished = false
        var sentAnswer = ""
        var answerText = ""
        var heard: String?
        var sentHeard = false
        /// The choice the latest answer ends on, offered on the watch once it is done.
        var choice: MuseChoice?
        /// Muse's reaction to what was asked, shown after it on the watch.
        var reaction: String?
        /// What Muse asked of the watch or the phone while answering.
        var tools: [MuseToolUse] = []
        /// The answer as Muse wrote it, for a watch that shows its options as buttons.
        var content: MuseAnswerContent?
        /// The ids of the message this sent Muse: a message answering one later is a late answer.
        var askedIDs: Set<String> = []
        /// The messages that answered it here, so the chat's listener doesn't send them again.
        var replyIDs: Set<String> = []
        /// The options the watch shows with the answer, for a pick that comes later.
        var offered: MuseChoice?
        /// What the watch says went to the phone ("Link sent to your phone"), once it did.
        var handoffLine: String?

        init(serial: Int, id: Int, trigger: PttTrigger?) {
            self.serial = serial
            self.id = id
            self.trigger = trigger
        }
    }

    private var turn: Turn?
    private var turnSerial = 0
    private var conversation: (any MuseVoiceConversation)?
    private var idleClose: Task<Void, Never>?
    private var started = false
    private var consumer: Task<Void, Never>?
    private var pairedFollower: Task<Void, Never>?
    private var preferencesFollower: Task<Void, Never>?
    private var isPaired = false
    private var listenedChat = ""


    private enum Outgoing {
        case update(turn: Int, kind: AssistantUpdateKind, detail: UInt8, text: [UInt8])
    }

    private var outbox: [Outgoing] = []
    private var sending = false

    /// The last few exchanges, newest last: a pick can come minutes later, and a late answer
    /// names the question it answers.
    private var recent: [Turn] = []
    static let recentTurns = 8
    /// The highest turn number the watch has seen, so a turn this begins comes after it.
    private var lastTurnSeen = 0
    /// Following the watch's chat for messages Muse sends by itself.
    private var listening = false
    private var listener: Task<Void, Never>?
    /// Messages from Muse waiting for the watch to take them.
    private var pendingMessages: [PendingMessage] = []
    private var messageRetry: Task<Void, Never>?
    /// How long a message from Muse waits for the watch before it's dropped.
    static let messageShelfLife: TimeInterval = 6 * 3600
    /// How long a message the watch couldn't take yet waits before it's offered again.
    private let messageRetryDelay: Duration

    private struct PendingMessage {
        let content: MuseAnswerContent
        /// For a late answer: the question it answers.
        let question: String?
        let replyIDs: Set<String>
        let receivedAt: Date
    }

    /// The watch keeps the conversation: options as buttons, picks, and turns this begins.
    private var watchKeepsConversation: Bool {
        (link.watchCapabilities ?? 0) & ProtocolConstants.capabilityConversation != 0
    }

    private var nextActionID = 0
    /// Muse's calls still running: the link must not close under one.
    private var commandsInFlight = 0
    private let tools: MuseTools
    private let hasData: Bool
    private let handoff: (any MusePhoneHandoffPosting)?
    private var actionWaiters: [Int: CheckedContinuation<WatchActionResult?, Never>] = [:]

    public init(
        link: any MuseAssistantLink,
        connector: any MuseVoiceConnector,
        preferences: MusePreferencesStore,
        data: (any MuseDataProvider)? = nil,
        eventKit: MuseEventKitSource = MuseEventKitSource(),
        // MuseTools.holdLimitSeconds: a little under the 180 s Muse is given for a data call.
        toolHoldLimit: Duration = .seconds(170),
        messageRetryDelay: Duration = .seconds(20),
        handoff: (any MusePhoneHandoffPosting)? = nil,
        keepAwake: @escaping @Sendable () -> Void = {},
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.link = link
        self.connector = connector
        self.preferences = preferences
        self.keepAwake = keepAwake
        self.log = log
        self.hasData = data != nil
        self.messageRetryDelay = messageRetryDelay
        self.handoff = handoff
        self.tools = MuseTools(
            preferences: preferences, data: data, eventKit: eventKit, holdLimit: toolHoldLimit, log: { log("tools: \($0)") })
    }

    /// Starts listening for questions. `paired` follows whether Muse is set up: while it is, the
    /// link to the watch stays up even with recording off, so a question can always reach here.
    public func start(paired: StateSubject<String?>) async {
        guard !started else { return }
        started = true
        // One consumer, in arrival order: a question's audio must not overtake its START.
        let (stream, continuation) = AsyncStream.makeStream(of: AudioReceiverSession.AssistantInbound.self)
        await link.setAssistantHandler { continuation.yield($0) }
        consumer = Task { [weak self] in
            for await inbound in stream { await self?.handle(inbound) }
        }
        let names = paired.stream()
        pairedFollower = Task { [weak self] in
            for await name in names {
                await self?.link.setQuietLink(name != nil)
                await self?.followSettings(paired: name != nil)
            }
        }
        let preferenceChanges = preferences.current.stream()
        preferencesFollower = Task { [weak self] in
            for await _ in preferenceChanges {
                await self?.followSettings(paired: nil)
            }
        }
        await link.setQuietLink(paired.value != nil)
        isPaired = paired.value != nil
        followSettings(paired: isPaired)
    }

    /// Muse's own messages are followed while Muse is set up and the person wants them.
    private func followSettings(paired: Bool?) {
        if let paired { isPaired = paired }
        let prefs = preferences.current.value
        let chat = prefs.chatPlace == .watchChat ? "watch" : "main"
        if listening, chat != listenedChat {
            // Another chat: follow that one from a new link.
            setListening(false)
            let open = conversation
            conversation = nil
            Task { await open?.close() }
        }
        listenedChat = chat
        setListening(isPaired && prefs.messagesOnWatch)
    }

    /// The next question from the watch is also sent at every check level.
    public func armLevelCheck() {
        levelCheck.value = LevelCheck(phase: .waiting, speechLevelDBFS: nil, results: [])
    }

    public func cancelLevelCheck() {
        if levelCheck.value?.phase != .running { levelCheck.value = nil }
    }

    // MARK: - From the watch

    func handle(_ inbound: AudioReceiverSession.AssistantInbound) async {
        switch inbound {
        case .pttEvent(let event):
            keepAwake()
            switch event.event {
            case .start?:
                lastTurnSeen = event.turn
                begin(event)
            case .end?: await end(event)
            case .cancel?: cancel(event)
            case .pick?: Task { await self.pick(event) }
            case nil: break
            }
        case .pttAudio(let audio):
            keepAwake()
            guard let turn, turn.id == audio.turn, !turn.finished else { return }
            for (offset, frame) in audio.frames.enumerated() {
                turn.frames[audio.firstFrame + offset] = Data(frame)
            }
        case .watchActionResult(let result):
            actionWaiters.removeValue(forKey: result.actionId)?.resume(returning: result)
        }
    }

    private func begin(_ event: PttEvent) {
        lastAskedAt = Date()
        log("question \(event.turn): listening (\(event.detail == PttTrigger.quickLaunch.rawValue ? "Quick Launch" : "in the app"))")
        turn?.finished = true
        turnSerial += 1
        let current = Turn(serial: turnSerial, id: event.turn, trigger: PttTrigger(rawValue: event.detail))
        turn = current
        guard connector.isPaired else {
            current.finished = true
            send(turn: current.id, .error, detail: AssistantError.notSetUp.rawValue)
            report(current, seconds: 0, missing: 0, level: nil, problem: .notSetUp)
            return
        }
        // Ready by the release: tokens, a VM and a link take a second or two.
        current.opening = Task { try await self.readyConversation() }
        Task { await tools.questionBegan() }
    }

    private func cancel(_ event: PttEvent) {
        guard let current = turn, current.id == event.turn else { return }
        log("question \(event.turn): cancelled on the watch (\(event.detail))")
        current.finished = true
        turn = nil
        // A link opened for it stays for the next question, then closes.
        scheduleIdleClose()
        Task { await self.deliverPending() }
    }

    private func end(_ event: PttEvent) async {
        guard let current = turn, current.id == event.turn, !current.finished else { return }
        current.frameCount = event.frameCount
        // Answered on its own: the watch's next press, and its replies to what Muse puts to it,
        // must reach here while Muse is still answering.
        Task { await self.answer(current) }
    }

    // MARK: - Asking Muse

    private func answer(_ current: Turn) async {
        let frameCount = current.frameCount ?? 0
        let (pcm, missing) = Self.decode(current.frames, frameCount: frameCount)
        let present = frameCount - missing
        current.frames = [:]
        guard present >= Self.minimumFrames else {
            log("question \(current.id): \(present) frame(s), nothing to ask")
            fail(current, .didNotCatch, seconds: Double(frameCount) / 50, missing: missing, level: nil)
            return
        }
        let settings: VoiceNoteLevel.Settings
        switch preferences.current.value.voiceLevel {
        case .automatic: settings = VoiceNoteLevel.Settings()
        case .fixed(let gain): settings = VoiceNoteLevel.Settings(fixedGainDB: Double(gain))
        }
        let (prepared, level) = VoiceNoteLevel.prepare(pcm, settings: settings)
        let checkLevels = levelCheck.value?.phase == .waiting
        if checkLevels { levelCheck.value?.phase = .running }
        defer { if checkLevels { Task { await self.runLevelCheck(pcm) } } }
        let wav = PcmWav.encodeMono16(pcm: Self.littleEndian(prepared), sampleRateHz: 16_000)
        log(
            "question \(current.id): \(String(format: "%.1f", level.durationSeconds)) s, "
                + "\(missing) missing, speech \(level.speechLevelDBFS.map { String(format: "%.0f", $0) } ?? "-") dBFS, "
                + "boosted \(String(format: "%.0f", level.gainDB)) dB, limited \(level.limitedSamples)")

        let conversation: any MuseVoiceConversation
        do {
            conversation = try await (current.opening ?? Task { try await self.readyConversation() }).value
        } catch {
            fail(current, Self.assistantError(error), seconds: level.durationSeconds, missing: missing, level: level)
            return
        }
        guard turn === current, !current.finished else { return }

        let keepAwake = self.keepAwake
        let awake = Task {
            while !Task.isCancelled {
                keepAwake()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { awake.cancel() }

        let done: Bool
        let serial = current.serial
        do {
            done = try await conversation.ask(
                wav: wav, instructions: Self.instructions, timeout: Self.answerTimeout
            ) { [weak self] event in
                await self?.relay(event, serial: serial)
            }
        } catch {
            log("question \(current.id): \(error)")
            self.conversation = nil
            await conversation.close()
            fail(current, Self.assistantError(error), seconds: level.durationSeconds, missing: missing, level: level)
            return
        }
        guard turn === current else { return }
        // A reaction and no words: the reaction is the answer.
        if current.answerText.isEmpty, let reaction = current.reaction { current.answerText = reaction }
        await handOff(current)
        // Whatever the stream held back as unfinished Markdown goes now.
        sendAnswer(current, rendered: WatchAnswerText.render(watchText(current), final: true))
        current.finished = true
        if current.answerText.isEmpty {
            let error = noAnswerError(current, done: done)
            log("question \(current.id): no answer (\(done ? "Muse finished" : error == .stillWorking ? "Muse is still working" : "timed out"))")
            send(turn: current.id, .error, detail: error.rawValue)
            report(current, seconds: level.durationSeconds, missing: missing, level: level, problem: error)
            remember(current)
        } else {
            log("question \(current.id): answered (\(current.answerText.utf8.count) bytes)\(done ? "" : ", cut off by the deadline")")
            report(current, seconds: level.durationSeconds, missing: missing, level: level, problem: nil)
            await finish(current)
        }
        scheduleIdleClose()
        await deliverPending()
    }

    /// Why a question got no words: nothing heard, Muse still at work (its answer will come as a
    /// message, to a watch that takes them), or no answer.
    private func noAnswerError(_ current: Turn, done: Bool) -> AssistantError {
        if (current.heard ?? "").isEmpty { return .didNotCatch }
        if !done, listening, watchKeepsConversation { return .stillWorking }
        return .noAnswer
    }

    /// What the watch shows of the answer: a watch that keeps the conversation shows Muse's
    /// options as buttons, so its text leaves them out.
    private func watchText(_ current: Turn) -> String {
        var text = current.answerText
        if watchKeepsConversation, let content = current.content {
            let apart = MuseWidget.substitute(
                content.raw, widgets: content.widgets, elsewhere: VoiceTurnFollower.seeInMuse, optionsApart: true)
            // A reaction and no words: the reaction is the answer.
            if !(apart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.widgets.isEmpty) { text = apart }
        }
        guard let line = current.handoffLine else { return text }
        // The phone has it now: say so once, where the answer ends.
        let trimmed = text.replacingOccurrences(of: "\n" + VoiceTurnFollower.seeInMuse, with: "")
            .replacingOccurrences(of: VoiceTurnFollower.seeInMuse, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : trimmed + "\n\n" + line
    }

    /// Hands what only the phone can open to it, with a notification there, once the answer is
    /// complete. The watch then says where it went.
    private func handOff(_ current: Turn) async {
        guard let handoff, current.handoffLine == nil else { return }
        let raw = current.content?.raw ?? current.answerText
        let widgets = current.content?.widgets ?? []
        guard !raw.isEmpty || !widgets.isEmpty else { return }
        let prefs = preferences.current.value
        let chat = MusePhoneHandoffPlanner.chatURL(watchChatID: prefs.chatPlace == .watchChat ? preferences.watchChatID() : nil)
        let truncated = WatchAnswerText.render(watchText(current), final: true).utf8.count > Self.watchAnswerBytes
        guard let plan = MusePhoneHandoffPlanner.plan(raw: raw, widgets: widgets, truncated: truncated, chat: chat) else { return }
        let posted = await handoff.post(plan)
        log("question \(current.id): \(plan.title.lowercased()) \(posted ? "went to the phone" : "stays in Muse (no notification)")")
        if posted { current.handoffLine = plan.watchLine }
    }

    /// The answer is complete. A watch that keeps the conversation gets its options with it, to
    /// pick now or later; an older one gets them as a picker after it.
    private func finish(_ current: Turn) async {
        guard watchKeepsConversation else {
            send(turn: current.id, .done)
            await offerChoices(current)
            return
        }
        if let choice = current.choice {
            let options = Array(choice.options.prefix(ProtocolConstants.assistantMaxOptions))
            for (index, option) in options.enumerated() {
                send(turn: current.id, .option, detail: UInt8(index), text: Self.cut(option.label, bytes: ProtocolConstants.assistantOptionMaxBytes))
            }
            current.offered = MuseChoice(question: choice.question, options: options)
            current.choice = nil
        }
        send(turn: current.id, .done)
        remember(current)
    }

    /// Keeps a finished exchange for a pick or a late answer.
    private func remember(_ current: Turn) {
        recent.removeAll { $0 === current || $0.id == current.id }
        recent.append(current)
        if recent.count > Self.recentTurns { recent.removeFirst() }
    }

    /// The wearer picked one of an answer's options, on the watch or its notification, maybe
    /// minutes later: it goes to Muse as their reply, and the answer comes on the same turn.
    private func pick(_ event: PttEvent) async {
        let index = Int(event.detail)
        guard let earlier = recent.last(where: { $0.id == event.turn }), let choice = earlier.offered,
            choice.options.indices.contains(index)
        else {
            log("question \(event.turn): a pick for options this phone no longer has")
            send(turn: event.turn, .error, detail: AssistantError.noAnswer.rawValue)
            return
        }
        let option = choice.options[index]
        lastAskedAt = Date()
        log("question \(event.turn): option \(index + 1) of \(choice.options.count) picked; asking Muse")
        turn?.finished = true
        turnSerial += 1
        let current = Turn(serial: turnSerial, id: event.turn, trigger: .followUp)
        current.heard = option.label
        current.sentHeard = true
        turn = current
        sendHeard(current)
        let serial = current.serial
        let done: Bool
        do {
            let conversation = try await readyConversation()
            done = try await conversation.reply(text: option.reply, timeout: Self.answerTimeout) { [weak self] event in
                await self?.relay(event, serial: serial)
            }
        } catch {
            log("question \(current.id): the pick didn't reach Muse: \(error)")
            let broken = conversation
            conversation = nil
            await broken?.close()
            guard turn === current else { return }
            current.finished = true
            send(turn: current.id, .error, detail: Self.assistantError(error).rawValue)
            return
        }
        guard turn === current else { return }
        if current.answerText.isEmpty, let reaction = current.reaction { current.answerText = reaction }
        await handOff(current)
        sendAnswer(current, rendered: WatchAnswerText.render(watchText(current), final: true))
        current.finished = true
        if current.answerText.isEmpty {
            let error = noAnswerError(current, done: done)
            send(turn: current.id, .error, detail: error.rawValue)
            remember(current)
        } else {
            log("question \(current.id): the pick was answered (\(current.answerText.utf8.count) bytes)")
            await finish(current)
        }
        scheduleIdleClose()
        await deliverPending()
    }

    /// Muse ended its answer on a choice (a widget its app draws as buttons). The watch shows the
    /// options as a picker; the one picked goes back to Muse as the wearer's reply, and Muse's
    /// answer to it replaces the question on the watch. A reply can end on another choice.
    private func offerChoices(_ current: Turn) async {
        for _ in 0..<Self.maxChoiceRounds {
            guard turn === current, let choice = current.choice else { return }
            current.choice = nil
            guard (link.watchCapabilities ?? 0) & ProtocolConstants.capabilityFollowUp != 0 else {
                log("question \(current.id): Muse offered a choice; this watch can only show it as text")
                return
            }
            var options = choice.options.map {
                String(decoding: Self.cut($0.label, bytes: ProtocolConstants.watchActionOptionMaxBytes), as: UTF8.self)
            }
            guard (1...ProtocolConstants.watchActionMaxOptions).contains(options.count) else {
                log("question \(current.id): Muse offered \(options.count) options; the watch shows them as text")
                return
            }
            // One button alone ("Book it") gets a way to leave it be.
            if options.count == 1 { options.append(Self.leaveIt) }
            let question = String(
                decoding: Self.cut(choice.question ?? Self.choiceQuestion, bytes: ProtocolConstants.watchActionQuestionMaxBytes), as: UTF8.self)
            let result = await runWatchAction(
                .choose(question: question, options: options, timeoutSeconds: Self.choiceSeconds), wait: .seconds(Self.choiceSeconds + 15))
            guard turn === current, let result, result.status == .done, choice.options.indices.contains(result.value) else { return }
            let picked = choice.options[result.value].reply
            log("question \(current.id): option \(result.value + 1) of \(choice.options.count) picked; asking Muse")

            current.finished = false
            current.answerText = ""
            current.sentAnswer = ""
            current.heard = picked
            current.reaction = nil
            current.sentHeard = true
            sendHeard(current)
            let serial = current.serial
            let done: Bool
            do {
                let conversation = try await readyConversation()
                done = try await conversation.reply(text: picked, timeout: Self.answerTimeout) { [weak self] event in
                    await self?.relay(event, serial: serial)
                }
            } catch {
                log("question \(current.id): the reply to the choice failed: \(error)")
                let broken = conversation
                conversation = nil
                await broken?.close()
                guard turn === current else { return }
                current.finished = true
                send(turn: current.id, .error, detail: Self.assistantError(error).rawValue)
                return
            }
            guard turn === current else { return }
            if current.answerText.isEmpty, let reaction = current.reaction { current.answerText = reaction }
            sendAnswer(current, rendered: WatchAnswerText.render(current.answerText, final: true))
            current.finished = true
            guard !current.answerText.isEmpty else {
                log("question \(current.id): no answer to the choice (\(done ? "Muse finished" : "timed out"))")
                send(turn: current.id, .error, detail: AssistantError.noAnswer.rawValue)
                return
            }
            log("question \(current.id): the choice was answered (\(current.answerText.utf8.count) bytes)")
            send(turn: current.id, .done)
        }
    }

    private func relay(_ event: MuseQuestionEvent, serial: Int) {
        guard let current = turn, current.serial == serial, !current.finished else { return }
        switch event {
        case .heard(let text):
            current.heard = text
            guard !current.sentHeard else { return }
            current.sentHeard = true
            sendHeard(current)
        case .reaction(let emoji):
            current.reaction = emoji
            if current.sentHeard { sendHeard(current) }
        case .status(let text):
            send(turn: current.id, .status, text: Self.cut(text, bytes: 63))
        case .answer(let text):
            current.answerText = text
            sendAnswer(current, rendered: WatchAnswerText.render(watchText(current), final: false))
        case .choice(let choice):
            current.choice = choice
        case .asked(let ids):
            current.askedIDs.formUnion(ids)
        case .content(let content):
            current.content = content
            current.replyIDs.formUnion(content.messageIDs)
        case .approval:
            break
        }
    }

    /// What was asked, with Muse's reaction after it, as the Muse app shows it on the message.
    private func sendHeard(_ current: Turn) {
        let heard = [current.heard, current.reaction].compactMap { $0 }.joined(separator: " ")
        send(turn: current.id, .heard, text: Self.cut(heard, bytes: ProtocolConstants.assistantTextMaxBytes))
    }

    /// Sends what `rendered` adds to what the watch already has. The watch only appends; a
    /// rendering that rewrote what was sent (Muse replacing its streamed text) adds nothing.
    private func sendAnswer(_ current: Turn, rendered: String) {
        guard rendered != current.sentAnswer else { return }
        let limit = Self.watchAnswerBytes + 64
        if rendered.hasPrefix(current.sentAnswer) {
            guard current.sentAnswer.utf8.count < limit else { return }
            let delta = String(rendered.dropFirst(current.sentAnswer.count))
            current.sentAnswer = rendered
            for piece in AssistantUpdate.chunks(of: delta) {
                enqueue(.update(turn: current.id, kind: .answer, detail: 0, text: piece))
            }
            return
        }
        // Muse's finished text differs from what streamed (its list formatting, say). A watch
        // that can replace its copy gets the whole answer again; an older one keeps what came.
        guard (link.watchCapabilities ?? 0) & ProtocolConstants.capabilityAnswerRestart != 0 else {
            log("question \(current.id): the answer changed after it streamed; this watch can't replace it")
            return
        }
        current.sentAnswer = rendered
        let pieces = AssistantUpdate.chunks(of: String(decoding: Array(rendered.utf8.prefix(limit)), as: UTF8.self))
        for (index, piece) in pieces.enumerated() {
            enqueue(.update(turn: current.id, kind: index == 0 ? .answerRestart : .answer, detail: 0, text: piece))
        }
    }

    private func fail(_ current: Turn, _ error: AssistantError, seconds: Double, missing: Int, level: VoiceNoteLevel.Report?) {
        guard turn === current else { return }
        current.finished = true
        send(turn: current.id, .error, detail: error.rawValue)
        report(current, seconds: seconds, missing: missing, level: level, problem: error)
        scheduleIdleClose()
        Task { await self.deliverPending() }
    }

    private func report(_ current: Turn, seconds: Double, missing: Int, level: VoiceNoteLevel.Report?, problem: AssistantError?) {
        let answer = WatchAnswerText.render(current.answerText, final: true)
        lastQuestion.value = QuestionReport(
            askedAt: current.startedAt, seconds: seconds, missingFrames: missing, level: level,
            heard: current.heard, answered: problem == nil, problem: problem,
            answer: answer.isEmpty ? nil : answer, tools: current.tools)
    }

    /// The open link, or a new one.
    private func readyConversation() async throws -> any MuseVoiceConversation {
        idleClose?.cancel()
        if let conversation, await conversation.isOpen { return conversation }
        conversation = nil
        let prefs = preferences.current.value
        let chatID: String? = prefs.chatPlace == .watchChat ? preferences.watchChatID() : nil
        let opened = try await connector.open(
            chatID: chatID, commands: MuseTools.commands(for: prefs, hasData: hasData)
        ) { [weak self] command, params, _ in
            guard let self else { return ["ok": false, "error": "The watch is not available."] }
            return await self.runCommandFromMuse(command, params)
        }
        conversation = opened
        return opened
    }

    private func scheduleIdleClose() {
        idleClose?.cancel()
        idleClose = Task { [weak self] in
            try? await Task.sleep(for: Self.followUpWindow)
            guard !Task.isCancelled else { return }
            await self?.closeIdle()
        }
    }

    private func closeIdle() async {
        if let turn, !turn.finished { return }
        // Muse's own messages come over this link.
        if listening { return }
        if commandsInFlight > 0 {
            scheduleIdleClose()
            return
        }
        let open = conversation
        conversation = nil
        await open?.close()
    }

    // MARK: - Muse's own messages

    /// While on, the link to Muse stays open and the watch's chat is followed: a message Muse
    /// sends by itself, or an answer that comes after its question was over, goes to the watch,
    /// which shows it, or makes it a notification when Muse isn't open there.
    public func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        listener?.cancel()
        listener = nil
        if on {
            log("Muse messages: following the watch's chat")
            listener = Task { [weak self] in await self?.listen() }
        } else {
            log("Muse messages: off")
            scheduleIdleClose()
        }
    }

    private func listen() async {
        var pause: Duration = .seconds(5)
        while !Task.isCancelled, listening {
            do {
                let conversation = try await readyConversation()
                pause = .seconds(5)
                try await conversation.followChat { [weak self] messages, typed in
                    await self?.received(messages, typedElsewhere: typed)
                }
            } catch {
                log("Muse messages: \(error)")
            }
            guard !Task.isCancelled, listening else { return }
            try? await Task.sleep(for: pause)
            pause = min(pause * 3, .seconds(300))
        }
    }

    /// Messages Muse finished on the watch's chat: the ones no question is showing go to the
    /// watch. Replies to what someone typed in the Muse app stay there.
    func received(_ messages: [MuseChatMessage], typedElsewhere typed: Set<String>) async {
        var late: Turn?
        var kept: [MuseChatMessage] = []
        for message in messages {
            // Muse's messages name no question they answer, so a question's own answer, seen
            // again by the chat, is known by its id alone.
            if shown(message.id) { continue }
            let asked = message.root.flatMap { root in
                ([turn].compactMap { $0 } + recent.reversed()).first { $0.askedIDs.contains(root) }
            }
            if let asked, !asked.finished || asked.replyIDs.contains(message.id) { continue }
            if asked == nil, let root = message.root, typed.contains(root) { continue }
            if late == nil { late = asked }
            kept.append(message)
        }
        log("Muse messages: \(messages.count) finished, \(kept.count) for the watch")
        guard !kept.isEmpty else { return }
        // Bubbles that came together go together.
        let content = MuseAnswerContent(
            raw: kept.map(\.content.raw).filter { !$0.isEmpty }.joined(separator: "\n\n"),
            widgets: kept.flatMap(\.content.widgets), messageIDs: kept.map(\.id))
        pendingMessages.append(PendingMessage(
            content: content, question: late?.heard, replyIDs: Set(kept.map(\.id)), receivedAt: Date()))
        if let late, lastQuestion.value?.askedAt == late.startedAt {
            // The phone's card shows the answer that came after all.
            let answer = WatchAnswerText.render(
                MuseWidget.substitute(content.raw, widgets: content.widgets, elsewhere: VoiceTurnFollower.seeInMuse), final: true)
            lastQuestion.value?.answer = answer
            lastQuestion.value?.answered = true
            lastQuestion.value?.problem = nil
        }
        await deliverPending()
    }

    /// Whether a question here already showed this message on the watch.
    private func shown(_ id: String) -> Bool {
        ([turn].compactMap { $0 } + recent).contains { $0.replyIDs.contains(id) }
    }

    /// Hands the watch what Muse sent, one message at a time, each as a turn of the phone's own.
    /// A question under way goes first; a watch that is away gets them when it is back.
    private func deliverPending() async {
        pendingMessages.removeAll { Date().timeIntervalSince($0.receivedAt) > Self.messageShelfLife }
        // A question that was under way may have shown them since.
        pendingMessages.removeAll { !$0.replyIDs.isEmpty && $0.replyIDs.allSatisfy(shown) }
        guard !pendingMessages.isEmpty else { return }
        guard watchKeepsConversation else {
            log("Muse messages: this watch can't show messages Muse starts; \(pendingMessages.count) left in the Muse app")
            pendingMessages.removeAll()
            return
        }
        while let next = pendingMessages.first {
            if let turn, !turn.finished {
                scheduleMessageRetry()
                return
            }
            let turnID = lastTurnSeen % 255 + 1
            let question = Self.cut(next.question ?? "", bytes: ProtocolConstants.assistantTextMaxBytes)
            let detail = (next.question == nil ? AssistantBegin.message : .lateAnswer).rawValue
            let reply = await link.sendControlRequest { token in
                AssistantUpdate(requestToken: token, turn: turnID, kind: .begin, detail: detail, text: question).encode()
            }
            guard reply == .ok else {
                log("Muse messages: the watch didn't take one yet (\(reply)); trying again shortly")
                scheduleMessageRetry()
                return
            }
            pendingMessages.removeFirst()
            lastTurnSeen = turnID
            turnSerial += 1
            let current = Turn(serial: turnSerial, id: turnID, trigger: nil)
            current.heard = next.question
            current.sentHeard = true
            current.content = next.content
            current.replyIDs = next.replyIDs
            current.answerText = WatchAnswerText.render(
                MuseWidget.substitute(next.content.raw, widgets: next.content.widgets, elsewhere: VoiceTurnFollower.seeInMuse),
                final: true)
            if let widget = next.content.widgets.last(where: \.isChoice) {
                let asked = MuseWidget.question(before: widget.id, in: next.content.raw)
                current.choice = MuseChoice(
                    question: widget.isOnlyOptionsWidget ? asked : (widget.title ?? asked), options: widget.options)
            }
            turn = current
            await handOff(current)
            sendAnswer(current, rendered: WatchAnswerText.render(watchText(current), final: true))
            current.finished = true
            await finish(current)
            log("question \(turnID): \(next.question == nil ? "a message from Muse" : "a late answer") went to the watch (\(current.answerText.utf8.count) bytes)")
        }
    }

    private func scheduleMessageRetry() {
        guard messageRetry == nil else { return }
        messageRetry = Task { [weak self] in
            try? await Task.sleep(for: self?.messageRetryDelay ?? .seconds(20))
            await self?.retryMessages()
        }
    }

    private func retryMessages() async {
        messageRetry = nil
        await deliverPending()
    }

    static func assistantError(_ error: Error) -> AssistantError {
        switch error {
        case let failure as MuseQuestionFailure:
            switch failure {
            case .notSetUp: return .notSetUp
            case .unreachable: return .unreachable
            case .refused(429): return .busy
            case .refused(401), .refused(403): return .notSetUp
            case .refused: return .unreachable
            }
        case is MuseLinkSession.Failure:
            return .unreachable
        default:
            return .unreachable
        }
    }

    /// Sends `pcm` at each check level to a fresh chat and records what Muse heard.
    private func runLevelCheck(_ pcm: [Int16]) async {
        let conversation: any MuseVoiceConversation
        do {
            conversation = try await connector.open(
                chatID: UUID().uuidString.lowercased(), commands: [:]
            ) { _, _, _ in ["ok": false, "error": "unsupported command"] }
        } catch {
            log("level check: could not reach Muse: \(error)")
            levelCheck.value?.phase = .failed
            return
        }
        defer { Task { await conversation.close() } }
        for target in Self.levelCheckTargets {
            let (prepared, report) = VoiceNoteLevel.prepare(pcm, settings: VoiceNoteLevel.Settings(targetDBFS: target))
            levelCheck.value?.speechLevelDBFS = report.speechLevelDBFS
            let wav = PcmWav.encodeMono16(pcm: Self.littleEndian(prepared), sampleRateHz: 16_000)
            let heard = HeardBox()
            do {
                _ = try await conversation.ask(
                    wav: wav, instructions: Self.levelCheckInstructions, timeout: .seconds(45)
                ) { event in
                    switch event {
                    case .heard(let text): await heard.setHeard(text)
                    case .answer(let text): await heard.setAnswer(text)
                    case .status, .choice, .reaction, .asked, .content, .approval: break
                    }
                }
            } catch {
                log("level check at \(Int(target)) dBFS: \(error)")
            }
            let text = await heard.best
            log("level check at \(Int(target)) dBFS (+\(Int(report.gainDB.rounded())) dB): \(text == nil ? "nothing" : "\(text!.count) chars")")
            levelCheck.value?.results.append(.init(targetDBFS: target, gainDB: report.gainDB, heard: text))
        }
        levelCheck.value?.phase = .done
    }

    // MARK: - To the watch

    private func send(turn: Int, _ kind: AssistantUpdateKind, detail: UInt8 = 0, text: [UInt8] = []) {
        enqueue(.update(turn: turn, kind: kind, detail: detail, text: text))
    }

    private func enqueue(_ item: Outgoing) {
        outbox.append(item)
        guard !sending else { return }
        sending = true
        Task { await self.drain() }
    }

    /// One update at a time on the watch's single request slot, in order. Answer pieces that
    /// arrive close together go together, so a fast stream isn't a write per word.
    private func drain() async {
        while !outbox.isEmpty {
            if case .update(_, .answer, _, _) = outbox[0] {
                try? await Task.sleep(for: .milliseconds(150))
            }
            let item = coalesce()
            guard case .update(let turnID, let kind, let detail, let text) = item else { continue }
            let delivered = await deliver { token in
                AssistantUpdate(requestToken: token, turn: turnID, kind: kind, detail: detail, text: text).encode()
            }
            if !delivered {
                log("question \(turnID): the watch didn't take an update; dropping the rest")
                outbox.removeAll { if case .update(turnID, _, _, _) = $0 { return true } else { return false } }
            }
        }
        sending = false
    }

    /// The head of the outbox, joined with the answer pieces right behind it while they fit.
    private func coalesce() -> Outgoing {
        let head = outbox.removeFirst()
        guard case .update(let turnID, let kind, _, var text) = head, kind == .answer || kind == .answerRestart
        else { return head }
        while case .update(turnID, .answer, _, let next)? = outbox.first,
            text.count + next.count <= ProtocolConstants.assistantTextMaxBytes
        {
            text += next
            outbox.removeFirst()
        }
        return .update(turn: turnID, kind: kind, detail: 0, text: text)
    }

    /// Sends one request, asking again while the watch is busy.
    private func deliver(_ build: @escaping @Sendable (Int) -> [UInt8]) async -> Bool {
        var unanswered = 0
        for _ in 0..<40 {
            switch await link.sendControlRequest(build) {
            case .ok:
                return true
            case .busy:
                try? await Task.sleep(for: .milliseconds(50))
            case .notSent, .noAnswer:
                unanswered += 1
                if unanswered >= 3 { return false }
                try? await Task.sleep(for: .milliseconds(200))
            case .rejected, .badState, .other:
                return false
            }
        }
        return false
    }

    // MARK: - Watch actions and tools

    /// When the wearer last asked from the watch (a question or a pick).
    private var lastAskedAt: Date?
    /// Muse may use the watch and read what it is allowed to only while answering a question asked
    /// on the watch: this long after it, to let a long task finish (the watch itself waits as long).
    /// The link now stays open, so a call can come at any time; outside this it is refused
    /// (docs/privacy-model.md, D7a and D7b).
    static let toolWindow: TimeInterval = 15 * 60
    static let outsideQuestion =
        "The person allows this only while you answer a question they asked on their Pebble watch."

    /// A call from Muse over the link: run while a watch question is being answered, refused otherwise.
    func runCommandFromMuse(_ command: String, _ params: MuseJSON) async -> MuseJSON {
        guard let lastAskedAt, Date().timeIntervalSince(lastAskedAt) < Self.toolWindow else {
            log("tools: \(command) refused: no question from the watch is open")
            return ["ok": false, "error": .string(Self.outsideQuestion)]
        }
        return await runCommand(command, params)
    }

    /// What Muse calls while answering: runs on the watch or the phone, through `MuseTools`.
    func runCommand(_ command: String, _ params: MuseJSON) async -> MuseJSON {
        commandsInFlight += 1
        defer { commandsInFlight -= 1 }
        let asking = turn
        let result = await tools.run(command, params, watch: self)
        let use = MuseToolUse(command: command, outcome: MuseTools.outcome(of: result))
        log("tools: \(command) \(Self.describe(use.outcome))")
        if let asking, !asking.finished || turn === asking { asking.tools.append(use) }
        return result
    }

    static func describe(_ outcome: MuseToolUse.Outcome) -> String {
        switch outcome {
        case .done: return "done"
        case .declined: return "declined"
        case .unanswered: return "not answered"
        case .failed: return "failed"
        }
    }

    /// Sends one watch action and waits up to `wait` for how it ended; nil when the watch never
    /// took it or never answered.
    func runWatchAction(_ request: WatchActionRequest, wait: Duration) async -> WatchActionResult? {
        nextActionID = nextActionID % 255 + 1
        let actionID = nextActionID
        let messages: [WatchAction]
        do {
            messages = try request.messages(actionId: actionID) { 0 }
        } catch {
            log("watch action \(actionID): \(error)")
            return nil
        }
        log("watch action \(actionID): \(Self.describe(request))")
        for message in messages {
            let delivered = await deliver { token in
                WatchAction(requestToken: token, actionId: message.actionId, flags: message.flags, payload: message.payload).encode()
            }
            guard delivered else {
                log("watch action \(actionID): the watch didn't take it")
                return nil
            }
        }
        let result = await waitForResult(actionID, wait)
        log("watch action \(actionID): \(result.map { $0.status.map { "\($0)" } ?? "\($0.statusRaw)" } ?? "no answer")")
        return result
    }

    /// Says on the watch what is happening, while a question is open: it also keeps the
    /// watch's screen from deciding Muse went quiet.
    func showStatus(_ text: String) async {
        guard let current = turn else { return }
        send(turn: current.id, .status, text: Self.cut(text, bytes: 63))
    }

    /// A log line that names what was asked, never what it carries.
    static func describe(_ request: WatchActionRequest) -> String {
        switch request {
        case .timer: return "timer"
        case .alarm: return "alarm"
        case .choose(_, let options, _): return "choice of \(options.count)"
        case .music(let command): return "music \(command)"
        case .quietTime(let on, _): return "Quiet Time \(on ? "on" : "off")"
        case .launchApp: return "open an app"
        case .findWatch: return "find the watch"
        case .health(let metric, let days): return "health \(metric) for \(days) day(s)"
        case .notice: return "notice"
        }
    }

    private func waitForResult(_ actionID: Int, _ wait: Duration) async -> WatchActionResult? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.resolveAction(actionID, nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { actionWaiters[actionID] = $0 }
    }

    private func resolveAction(_ actionID: Int, _ result: WatchActionResult?) {
        actionWaiters.removeValue(forKey: actionID)?.resume(returning: result)
    }

    // MARK: - Audio

    /// The question's frames, decoded in order; a frame the watch counted but that never came is
    /// 20 ms of silence. Returns the samples and how many frames were missing.
    static func decode(_ frames: [Int: Data], frameCount: Int) -> ([Int16], Int) {
        let frameSamples = 320
        var pcm: [Int16] = []
        pcm.reserveCapacity(frameCount * frameSamples)
        var missing = 0
        var run: [Data] = []
        let decoder = SpeexFrameDecoder()
        func flush() {
            guard !run.isEmpty else { return }
            if let decoded = try? decoder.decodeAll(frames: run) {
                decoded.withUnsafeBytes { raw in
                    pcm.append(contentsOf: raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) })
                }
                let expected = run.count * frameSamples
                let produced = decoded.count / 2
                if produced < expected { pcm.append(contentsOf: repeatElement(0, count: expected - produced)) }
            } else {
                pcm.append(contentsOf: repeatElement(0, count: run.count * frameSamples))
                missing += run.count
            }
            run = []
        }
        for index in 0..<max(0, frameCount) {
            if let frame = frames[index] {
                run.append(frame)
            } else {
                flush()
                missing += 1
                pcm.append(contentsOf: repeatElement(0, count: frameSamples))
            }
        }
        flush()
        return (pcm, missing)
    }

    static func littleEndian(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// At most `bytes` of UTF-8, cut between characters.
    static func cut(_ text: String, bytes: Int) -> [UInt8] {
        AssistantUpdate.chunks(of: text, maxBytes: bytes).first ?? []
    }
}

/// What Muse heard of one check recording: its own transcript, or failing that its reply.
private actor HeardBox {
    private var heard: String?
    private var answer: String?

    func setHeard(_ text: String) { heard = text }
    func setAnswer(_ text: String) { answer = text }

    var best: String? {
        let text = (heard?.isEmpty == false ? heard : answer)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
