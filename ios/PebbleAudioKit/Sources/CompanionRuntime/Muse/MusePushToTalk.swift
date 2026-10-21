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
/// may set a timer or an alarm on the watch, or put a choice to the wearer.
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

        public init(
            askedAt: Date, seconds: Double, missingFrames: Int, level: VoiceNoteLevel.Report?,
            heard: String?, answered: Bool, problem: AssistantError?
        ) {
            self.askedAt = askedAt
            self.seconds = seconds
            self.missingFrames = missingFrames
            self.level = level
            self.heard = heard
            self.answered = answered
            self.problem = problem
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
    static let instructions =
        "Asked on a Pebble watch. Your reply is read as plain text on the watch's small screen: "
        + "answer in a few short sentences, without tables, images or links."
    /// The longest Muse may take over an answer: room for a data call held open while the person
    /// answers (`MuseTools.holdLimitSeconds`) and the answer after it.
    static let answerTimeout: Duration = .seconds(MuseTools.dataCallLimitSeconds + 60)
    /// A link to Muse stays open this long after an answer, for a follow-up.
    static let followUpWindow: Duration = .seconds(60)
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

    private enum Outgoing {
        case update(turn: Int, kind: AssistantUpdateKind, detail: UInt8, text: [UInt8])
    }

    private var outbox: [Outgoing] = []
    private var sending = false

    private var nextActionID = 0
    /// Muse's calls still running: the link must not close under one.
    private var commandsInFlight = 0
    private let tools: MuseTools
    private let hasData: Bool
    private var actionWaiters: [Int: CheckedContinuation<WatchActionResult?, Never>] = [:]

    public init(
        link: any MuseAssistantLink,
        connector: any MuseVoiceConnector,
        preferences: MusePreferencesStore,
        data: (any MuseDataProvider)? = nil,
        eventKit: MuseEventKitSource = MuseEventKitSource(),
        // MuseTools.holdLimitSeconds: a little under the 180 s Muse is given for a data call.
        toolHoldLimit: Duration = .seconds(170),
        keepAwake: @escaping @Sendable () -> Void = {},
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.link = link
        self.connector = connector
        self.preferences = preferences
        self.keepAwake = keepAwake
        self.log = log
        self.hasData = data != nil
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
            }
        }
        await link.setQuietLink(paired.value != nil)
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
            case .start?: begin(event)
            case .end?: await end(event)
            case .cancel?: cancel(event)
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
    }

    private func cancel(_ event: PttEvent) {
        guard let current = turn, current.id == event.turn else { return }
        log("question \(event.turn): cancelled on the watch (\(event.detail))")
        current.finished = true
        turn = nil
        // A link opened for it stays for the next question, then closes.
        scheduleIdleClose()
    }

    private func end(_ event: PttEvent) async {
        guard let current = turn, current.id == event.turn, !current.finished else { return }
        current.frameCount = event.frameCount
        await answer(current)
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
        // Whatever the stream held back as unfinished Markdown goes now.
        sendAnswer(current, rendered: WatchAnswerText.render(current.answerText, final: true))
        current.finished = true
        if current.answerText.isEmpty {
            let error: AssistantError = (current.heard ?? "").isEmpty ? .didNotCatch : .noAnswer
            log("question \(current.id): no answer (\(done ? "Muse finished" : "timed out"))")
            send(turn: current.id, .error, detail: error.rawValue)
            report(current, seconds: level.durationSeconds, missing: missing, level: level, problem: error)
        } else {
            log("question \(current.id): answered (\(current.answerText.utf8.count) bytes)\(done ? "" : ", cut off by the deadline")")
            send(turn: current.id, .done)
            report(current, seconds: level.durationSeconds, missing: missing, level: level, problem: nil)
        }
        scheduleIdleClose()
    }

    private func relay(_ event: MuseQuestionEvent, serial: Int) {
        guard let current = turn, current.serial == serial, !current.finished else { return }
        switch event {
        case .heard(let text):
            current.heard = text
            guard !current.sentHeard else { return }
            current.sentHeard = true
            send(turn: current.id, .heard, text: Self.cut(text, bytes: ProtocolConstants.assistantTextMaxBytes))
        case .status(let text):
            send(turn: current.id, .status, text: Self.cut(text, bytes: 63))
        case .answer(let text):
            current.answerText = text
            sendAnswer(current, rendered: WatchAnswerText.render(text, final: false))
        }
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
    }

    private func report(_ current: Turn, seconds: Double, missing: Int, level: VoiceNoteLevel.Report?, problem: AssistantError?) {
        lastQuestion.value = QuestionReport(
            askedAt: current.startedAt, seconds: seconds, missingFrames: missing, level: level,
            heard: current.heard, answered: problem == nil, problem: problem)
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
            return await self.runCommand(command, params)
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
        if commandsInFlight > 0 {
            scheduleIdleClose()
            return
        }
        let open = conversation
        conversation = nil
        await open?.close()
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
                    case .status: break
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

    /// What Muse calls while answering: runs on the watch or the phone, through `MuseTools`.
    func runCommand(_ command: String, _ params: MuseJSON) async -> MuseJSON {
        commandsInFlight += 1
        defer { commandsInFlight -= 1 }
        return await tools.run(command, params, watch: self)
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
