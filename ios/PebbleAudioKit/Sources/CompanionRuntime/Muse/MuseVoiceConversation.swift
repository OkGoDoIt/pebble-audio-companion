import Foundation
import MuseLink

/// What came back about a spoken question, as it arrived.
public enum MuseQuestionEvent: Sendable, Equatable {
    /// What Muse heard, from its transcript of the voice note.
    case heard(String)
    /// What Muse says it is doing ("Searching the web").
    case status(String)
    /// The whole answer so far.
    case answer(String)
    /// The answer ends on a choice for the wearer (a widget the Muse app draws as buttons).
    case choice(MuseChoice)
    /// Muse reacted to the question with an emoji, as the Muse app shows on the person's message.
    case reaction(String)
    /// Muse took the message: its ids, so a later message answering it can be told apart.
    case asked(Set<String>)
    /// Muse waits for the person's OK on their phone, for this (`display.action_label`) when it says.
    case approval(String?)
    /// The answer as Muse wrote it: Markdown with widget placeholders, and the widgets.
    case content(MuseAnswerContent)
}

/// An answer as Muse wrote it, before it is made into watch text.
public struct MuseAnswerContent: Sendable, Equatable {
    public let raw: String
    public let widgets: [MuseWidget]
    /// The ids of Muse's messages it is made of.
    public let messageIDs: [String]

    public init(raw: String, widgets: [MuseWidget], messageIDs: [String] = []) {
        self.raw = raw
        self.widgets = widgets
        self.messageIDs = messageIDs
    }
}

/// A message Muse sent on the watch's chat that no question was waiting for: one it started, or
/// an answer that came after its question was over.
public struct MuseChatMessage: Sendable, Equatable {
    public let id: String
    public let content: MuseAnswerContent
    /// The user message it answers; nil when Muse started it.
    public let root: String?

    public init(id: String, content: MuseAnswerContent, root: String?) {
        self.id = id
        self.content = content
        self.root = root
    }
}

/// Options Muse put to the wearer (its buttons, or list rows that send a message), and the
/// question they answer when it can be told. Picking one sends its `reply` as the wearer's
/// next message, as a tap does in the Muse app.
public struct MuseChoice: Sendable, Equatable {
    public let question: String?
    public let options: [MuseWidget.Option]

    public init(question: String?, options: [MuseWidget.Option]) {
        self.question = question
        self.options = options
    }
}

/// Why a spoken question got no answer.
public enum MuseQuestionFailure: Error, Equatable, Sendable {
    /// No gadget tokens, or Muse no longer accepts them, or the account has no VM.
    case notSetUp
    /// No network, or Muse's servers didn't take the connection.
    case unreachable
    /// Muse turned the question away (HTTP status).
    case refused(Int)
    /// Muse would not take a message on this chat (HTTP 409): it holds the chat for something
    /// still under way there. `approvalPending` when an approval was waiting on it.
    case chatBusy(approvalPending: Bool)
}

/// A link to Muse kept for a run of questions: open at the press, reused for a follow-up.
public protocol MuseVoiceConversation: Sendable {
    /// Sends one voice note and reports what happens until Muse is done. True when Muse said it
    /// was done; false when `timeout` passed first.
    func ask(
        wav: Data, instructions: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
    ) async throws -> Bool
    /// Sends the wearer's typed (or picked) reply to the same chat, the same way.
    func reply(
        text: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
    ) async throws -> Bool
    var isOpen: Bool { get async }
    func close() async
    /// Follows the chat until the link ends, reporting each message Muse finishes there, for the
    /// caller to decide who it is for. User messages seen on the chat are reported as
    /// `typedElsewhere` (they weren't sent by this gadget unless the caller knows otherwise).
    func followChat(onMessages: @escaping @Sendable ([MuseChatMessage], Set<String>) async -> Void) async throws
}

extension MuseVoiceConversation {
    public func followChat(onMessages: @escaping @Sendable ([MuseChatMessage], Set<String>) async -> Void) async throws {}
}

/// Opens links to Muse as this gadget.
public protocol MuseVoiceConnector: Sendable {
    var isPaired: Bool { get }
    /// `commands` registers the gadget's watch actions (`commands_v2`); empty for none.
    func open(
        chatID: String?, commands: MuseJSON, handler: @escaping MuseLinkSession.CommandHandler
    ) async throws(MuseQuestionFailure) -> any MuseVoiceConversation
}

/// One voice question at a time over a `MuseLinkSession`.
actor LiveMuseVoiceConversation: MuseVoiceConversation {
    /// The first message of the watch's own chat, which Muse names the chat from.
    static let chatOpening =
        "Pebble watch: this chat is for the questions I ask out loud on my Pebble watch. Its microphone "
        + "is small, so a recording can be quiet or unclear: work out what I most likely meant rather "
        + "than taking odd words literally, and ask if you really can't tell."

    private let session: MuseLinkSession
    private let chatID: String?
    private let trace: (@Sendable (String) -> Void)?

    init(session: MuseLinkSession, chatID: String?, trace: (@Sendable (String) -> Void)?) {
        self.session = session
        self.chatID = chatID
        self.trace = trace
    }

    var isOpen: Bool {
        get async { await session.outcome == nil }
    }

    func close() async {
        await session.close()
    }

    func followChat(onMessages: @escaping @Sendable ([MuseChatMessage], Set<String>) async -> Void) async throws {
        let events = try await session.subscribeChat(sessionID: chatID)
        trace?("following the chat")
        let inbox = InboxBox(MuseInbox(sessionID: chatID, startedAt: ProcessInfo.processInfo.systemUptime))
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let (due, typed) = await inbox.due()
                if !due.isEmpty { await onMessages(due, typed) }
            }
        }
        defer { ticker.cancel() }
        for try await event in events { await inbox.feed(event) }
        trace?("the chat's events ended")
    }

    func ask(
        wav: Data, instructions: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
    ) async throws -> Bool {
        try await run(timeout: timeout, onEvent: onEvent) { session, chatID in
            try await session.sendVoice(wav: wav, sessionID: chatID, message: instructions)
        }
    }

    func reply(
        text: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
    ) async throws -> Bool {
        try await run(timeout: timeout, onEvent: onEvent) { session, chatID in
            try await session.sendChat(text, sessionID: chatID)
        }
    }

    private func run(
        timeout: Duration, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void,
        send: (MuseLinkSession, String?) async throws -> MuseLinkSession.ChatAck
    ) async throws -> Bool {
        let trace = self.trace
        let follower = VoiceTurnFollower(sessionID: chatID, onEvent: onEvent, trace: trace)
        var readers: [Task<Void, Never>] = []
        defer { readers.forEach { $0.cancel() } }
        func follow(_ events: AsyncThrowingStream<MuseJSON, Error>) {
            readers.append(Task {
                do {
                    for try await event in events { try await follower.feed(event) }
                } catch {
                    trace?("chat events ended: \(error)")
                }
            })
        }

        // The watch's own chat doesn't exist until its first message, and Muse answers a
        // subscription to it with 404: then the note goes first and the subscription right after,
        // the order Meta's ESP32 gadget always uses.
        var subscribed = false
        do {
            follow(try await session.subscribeChat(sessionID: chatID))
            subscribed = true
        } catch let MuseLinkSession.Failure.http(status, _) where status == 404 && chatID != nil {
            trace?("the watch's chat is new; naming it, then subscribing after the note")
            // Muse names a new chat from its first message. Without this line it named the
            // watch's chat after the first question's content ("Transcribe audio file").
            let named = try? await session.sendChat(Self.chatOpening, sessionID: chatID)
            trace?("chat opening: HTTP \(named?.status ?? 0)")
        }

        let ack = try await send(session, chatID)
        trace?("message acknowledged: HTTP \(ack.status)")
        guard ack.ok else {
            // Meta's own words for why, when it gives any: the 409s of 2026-10-22 were read
            // blind, with the body thrown away.
            if let reason = Self.refusalReason(ack.response) { trace?("refused: \(reason)") }
            guard ack.status == 409 else { throw MuseQuestionFailure.refused(ack.status) }
            // Muse holds the chat. Its replay, already subscribed, says whether an approval is
            // why: give it a moment to arrive.
            let clock = ContinuousClock()
            let until = clock.now + .seconds(1)
            while subscribed, !(await follower.hasApprovalSnapshot()), clock.now < until {
                try await Task.sleep(for: .milliseconds(100))
            }
            await follower.summarize()
            throw MuseQuestionFailure.chatBusy(approvalPending: await follower.approvalsWaiting())
        }
        if !subscribed { follow(try await session.subscribeChat(sessionID: chatID)) }
        try await follower.acknowledge(ack.response)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await follower.isComplete()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        await follower.summarize()
        return await follower.isComplete()
    }
}

extension LiveMuseVoiceConversation {
    /// Why Muse refused a message, from its response body: an error's message or code, cut short.
    static func refusalReason(_ response: MuseJSON?) -> String? {
        guard let response else { return nil }
        let error = response["error"]
        let candidates: [String?] = [
            error?["message"]?.string, error?["code"]?.string, error?.string,
            response["message"]?.string, response["detail"]?.string, response["code"]?.string,
        ]
        guard let reason = candidates.lazy.compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        return String(reason.prefix(200))
    }
}

/// Follows one voice note's turn: what Muse heard, what it is doing, and its answer.
actor VoiceTurnFollower {
    private var turn: MuseTurn
    private let onEvent: @Sendable (MuseQuestionEvent) async -> Void
    private var userIDs: Set<String> = []
    private var acknowledged = false
    private var heldUserMessages: [MuseJSON] = []
    private var lastAnswer = ""
    private var lastStatus = ""
    private var lastHeard = ""
    private var lastChoice: MuseChoice?
    private var widgetShapes: Set<String> = []
    private let sessionID: String?
    /// Approvals already waiting when the turn began; nil before Muse's first snapshot.
    private var knownApprovals: Set<String>?
    /// This question's approvals still waiting for the person.
    private var ownApprovals: Set<String> = []
    /// Every approval waiting in Muse's latest snapshot, on any chat.
    private var pendingApprovals: Set<String> = []
    /// Muse reacted to the question: an answer even with no words.
    private var reacted = false
    private var reactionShapes = 0
    private var approvalShapes = 0
    private let trace: (@Sendable (String) -> Void)?
    /// The first events' shapes, for the flight recorder (names and keys only).
    private var shapes: [String] = []
    private var eventCount = 0
    /// How many of each event the turn saw, by name, for the flight recorder.
    private var eventNames: [String: Int] = [:]

    init(sessionID: String?, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void, trace: (@Sendable (String) -> Void)? = nil) {
        turn = MuseTurn(sessionID: sessionID)
        self.sessionID = sessionID
        self.onEvent = onEvent
        self.trace = trace
    }

    /// One line saying what the turn saw, without any of its text.
    func summarize() {
        let markers = WatchAnswerText.markerNames(turn.answerText)
        if !markers.isEmpty { trace?("markers in the answer: \(markers.joined(separator: ", "))") }
        trace?("events: " + eventNames.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        trace?("turn saw \(eventCount) event(s), \(turn.replies.count) reply(ies), answer \(turn.answerText.count) chars, complete \(turn.isComplete()); first: \(shapes.joined(separator: " "))")
    }

    func feed(_ event: MuseJSON) async throws {
        eventCount += 1
        if shapes.count < 12 { shapes.append(MuseLinkSession.shape(event)) }
        if let name = event["event"]?.string, eventNames.count < 64 || eventNames[name] != nil {
            eventNames[String(name.prefix(48)), default: 0] += 1
        }
        traceWidgets(event)
        if event["event"]?.string == "approvals.snapshot" {
            await noteApprovals(event)
            return
        }
        if let emoji = reaction(event) {
            reacted = true
            trace?("Muse reacted to the question")
            await onEvent(.reaction(emoji))
            return
        }
        if Self.isUserMessage(event) {
            if acknowledged { await noteHeard(event) } else { heldUserMessages.append(event) }
            return
        }
        await emit(try turn.feed(event))
    }

    /// A widget's layout the first time it is seen, for the flight recorder (never its words):
    /// Meta doesn't document widgets, and this is how a new kind gets read right.
    private func traceWidgets(_ event: MuseJSON) {
        // `presentations` (cards Muse shows on their own, outside the text) are only logged
        // until their layout is known.
        // A card Muse shows on its own (`delta.presentation`): its layout, until it is read.
        if event["event"]?.string == "delta.presentation", let payload = event["payload"],
            widgetShapes.count < 6, widgetShapes.insert("presentation" + MuseWidget.shape(payload)).inserted
        {
            trace?("delta.presentation \(String(MuseWidget.shape(payload).prefix(900)))")
        }
        for key in ["widgets", "presentations"] {
            guard let widgets = event["payload"]?[key], widgets != .null, widgets != .array([]), widgets != .object([:])
            else { continue }
            let shape = MuseWidget.shape(widgets)
            guard widgetShapes.count < 6, widgetShapes.insert(key + shape).inserted else { continue }
            let read = MuseWidget.collect(widgets).map {
                "\($0.kind.map { MuseWidget.shape(.string($0), key: "type") } ?? "untyped"): \($0.options.count) option(s), "
                    + "\($0.lines.count) line(s)\($0.title == nil ? "" : ", a title")"
            }
            trace?("\(key) \(String(shape.prefix(900))) read as \(read.isEmpty ? "nothing" : read.joined(separator: "; "))")
        }
    }

    /// Muse waits for an OK before some steps (a purchase, a permission, a password, a sign-in),
    /// shown in its app as an approval card. The watch says where to give it, and the question
    /// stays open until it is answered, so what Muse does next still reaches the watch. An
    /// approval is this question's when its scope names this chat or it appears while the
    /// question is being asked.
    ///
    /// Answering one from the watch was looked into (2026-10-21): Muse's clients decide with
    /// `POST /approvals/{id}/decide` on its Sentinel service, signed in as the person. Nothing
    /// shows a gadget may, Meta's own gadgets send people to the phone, and its SDK terms rule out
    /// working around safety measures; so the watch points to the phone.
    private func noteApprovals(_ event: MuseJSON) async {
        let pending = event["payload"]?["pending_approvals"]?.array ?? []
        if !pending.isEmpty, approvalShapes < 2 {
            approvalShapes += 1
            trace?("approvals pending: \(String(MuseWidget.shape(.array(pending)).prefix(900)))")
        }
        var ids: Set<String> = []
        var onThisChat: Set<String> = []
        var labels: [String: String] = [:]
        for item in pending {
            let id = ["approval_id", "id", "request_id"].lazy.compactMap { item[$0]?.string }.first ?? item.compactString()
            ids.insert(id)
            if let label = (item["display"]?["action_label"]?.string ?? item["display"]?["title"]?.string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
            {
                labels[id] = label
            }
            if let chat = sessionID,
                ["session_id", "chat_id", "thread_id"].contains(where: { key in
                    [item, item["scope"], item["context"]].contains { $0?[key]?.string == chat }
                })
            {
                onThisChat.insert(id)
            }
        }
        let appeared = knownApprovals.map { ids.subtracting($0) } ?? []
        knownApprovals = (knownApprovals ?? []).union(ids)
        pendingApprovals = ids
        let waiting = !ownApprovals.isEmpty
        ownApprovals = ownApprovals.union(appeared).union(onThisChat).intersection(ids)
        if ownApprovals.isEmpty, waiting {
            trace?("the approval was answered")
            lastStatus = ""
        }
        guard !ownApprovals.isEmpty, !waiting else { return }
        trace?("Muse is waiting for an approval")
        lastStatus = Self.waitingForOK
        await onEvent(.status(Self.waitingForOK))
        await onEvent(.approval(ownApprovals.sorted().lazy.compactMap { labels[$0] }.first))
    }

    func acknowledge(_ response: MuseJSON?) async throws {
        let result = response?["result"] ?? response
        trace?("acknowledgement keys: \(result?.object?.keys.sorted().joined(separator: ",") ?? "none")")
        userIDs = Set(["message_id", "reply_to_message_id"].compactMap { result?[$0]?.string }.filter { !$0.isEmpty })
        let held = try turn.acknowledge(response)
        acknowledged = true
        if !userIDs.isEmpty { await onEvent(.asked(userIDs)) }
        for message in heldUserMessages { await noteHeard(message) }
        heldUserMessages = []
        await emit(held)
    }

    /// Muse's first approvals snapshot has arrived.
    func hasApprovalSnapshot() -> Bool { knownApprovals != nil }

    /// An approval is waiting for the person, on this chat or any.
    func approvalsWaiting() -> Bool { !pendingApprovals.isEmpty }

    /// Muse has answered (in words, or with only a reaction) and isn't waiting on the person to
    /// approve something.
    func isComplete() -> Bool {
        (turn.isAnswered() || (reacted && turn.isComplete())) && ownApprovals.isEmpty
    }

    /// A reaction Muse set on the question (`muse.react_to_user_message`): one emoji, or its care
    /// reaction `hatch:heart_v1`. Meta doesn't document the event, so any event named for a
    /// reaction that carries an emoji counts, unless it names another message.
    private func reaction(_ event: MuseJSON) -> String? {
        guard let name = event["event"]?.string, name.contains("reaction"), let payload = event["payload"] else { return nil }
        let target = ["target_message_id", "user_message_id", "reply_to_message_id", "message_id"].lazy
            .compactMap { payload[$0]?.string ?? payload["reaction"]?[$0]?.string }.first
        if let target, !userIDs.isEmpty, !userIDs.contains(target) { return nil }
        if reactionShapes < 2 {
            reactionShapes += 1
            trace?("reaction \(name) \(MuseWidget.shape(payload))")
        }
        // `reactions.updated` carries the message's reactions as a whole (seen 2026-10-21);
        // other forms name one.
        let raw = Self.reactionValue(payload["reactions"]) ?? ["emoji", "reaction", "value", "key"].lazy
            .compactMap { payload[$0]?.string ?? payload["reaction"]?[$0]?.string }.first
        guard let raw, let emoji = Self.reactionText(raw) else { return nil }
        return emoji
    }

    /// The newest reaction in a message's reactions: a list of emoji or of objects that name one,
    /// or an object keyed by emoji.
    static func reactionValue(_ value: MuseJSON?) -> String? {
        guard let value else { return nil }
        if let text = value.string { return reactionText(text) == nil ? nil : text }
        let keys = ["emoji", "reaction", "value", "key", "id", "type"]
        if let list = value.array {
            for item in list.reversed() {
                if let text = item.string, reactionText(text) != nil { return text }
                if let found = keys.lazy.compactMap({ item[$0]?.string }).first(where: { reactionText($0) != nil }) {
                    return found
                }
            }
            return nil
        }
        guard let object = value.object else { return nil }
        if let found = keys.lazy.compactMap({ object[$0]?.string }).first(where: { reactionText($0) != nil }) {
            return found
        }
        return object.keys.sorted().first { reactionText($0) != nil }
    }

    /// The emoji a reaction shows: itself, or a heart for Muse's own care reaction.
    static func reactionText(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("hatch:") { return value.contains("heart") ? "\u{2764}" : nil }
        guard !value.isEmpty, value.count <= 2, value.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F })
        else { return nil }
        return value
    }

    private func emit(_ events: [MuseTurn.Event]) async {
        for event in events {
            switch event {
            case .status(let status):
                guard let text = status.activityText?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty, text != lastStatus
                else { continue }
                lastStatus = text
                await onEvent(.status(text))
            case .reply:
                let raw = turn.answerText
                let widgets = turn.replies.flatMap(\.widgets)
                let answer = MuseWidget.substitute(raw, widgets: widgets, elsewhere: Self.seeInMuse)
                if answer != lastAnswer {
                    lastAnswer = answer
                    await onEvent(.content(MuseAnswerContent(raw: raw, widgets: widgets, messageIDs: turn.replies.map(\.messageID))))
                    await onEvent(.answer(answer))
                }
                if let widget = widgets.last(where: \.isChoice) {
                    // Buttons sit under the question they answer; a list names itself.
                    let asked = MuseWidget.question(before: widget.id, in: raw)
                    let choice = MuseChoice(
                        question: widget.isOnlyOptionsWidget ? asked : (widget.title ?? asked), options: widget.options)
                    if choice != lastChoice {
                        lastChoice = choice
                        await onEvent(.choice(choice))
                    }
                }
            case .taskFinished:
                break
            }
        }
    }

    private func noteHeard(_ event: MuseJSON) async {
        guard let payload = event["payload"] else { return }
        let id = payload["message_id"]?.string ?? event["message_id"]?.string ?? payload["id"]?.string
        if let id, !userIDs.isEmpty, !userIDs.contains(id) { return }
        let raw = payload["content"]?.string ?? payload["text"]?.string ?? payload["display_text"]?.string
            ?? payload["transcript"]?.string ?? ""
        let heard = Self.heardText(raw)
        guard !heard.isEmpty, heard != lastHeard else { return }
        lastHeard = heard
        await onEvent(.heard(heard))
    }

    static func isUserMessage(_ event: MuseJSON) -> Bool {
        guard event["type"]?.string == "event" else { return false }
        if event["event"]?.string == "message.user" { return true }
        return event["payload"]?["role"]?.string == "user"
            && Self.messageEvents.contains(event["event"]?.string ?? "")
    }

    /// What a widget the watch can't draw (a map, a chart, a card) says in its place.
    static let seeInMuse = "See it in Muse on your phone"
    /// Muse is waiting for the wearer to approve a step in its app.
    static let waitingForOK = "Muse needs your OK on your phone"

    static let messageEvents: Set<String> = [
        "delta.message_start", "delta.text_append", "delta.message_done", "message.assistant",
    ]

    /// Muse echoes a voice note as "<transcript>\n[file:audio/wav …]", or "[Voice note]" before it
    /// has transcribed it: the transcript is what it heard.
    static func heardText(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[file:") && $0 != "[Voice note]" }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The chat's inbox, shared by the event reader and the clock that hands out what is due.
private actor InboxBox {
    private var inbox: MuseInbox

    init(_ inbox: MuseInbox) { self.inbox = inbox }

    func feed(_ event: MuseJSON) { inbox.feed(event, now: ProcessInfo.processInfo.systemUptime) }

    func due() -> ([MuseChatMessage], Set<String>) {
        let messages = inbox.due(now: ProcessInfo.processInfo.systemUptime).map {
            MuseChatMessage(id: $0.id, content: MuseAnswerContent(raw: $0.text, widgets: $0.widgets, messageIDs: [$0.id]), root: $0.root)
        }
        return (messages, inbox.userMessages)
    }
}
