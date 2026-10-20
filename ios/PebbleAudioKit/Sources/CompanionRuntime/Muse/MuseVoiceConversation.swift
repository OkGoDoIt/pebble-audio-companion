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
}

/// Why a spoken question got no answer.
public enum MuseQuestionFailure: Error, Equatable, Sendable {
    /// No gadget tokens, or Muse no longer accepts them, or the account has no VM.
    case notSetUp
    /// No network, or Muse's servers didn't take the connection.
    case unreachable
    /// Muse turned the question away (HTTP status).
    case refused(Int)
}

/// A link to Muse kept for a run of questions: open at the press, reused for a follow-up.
public protocol MuseVoiceConversation: Sendable {
    /// Sends one voice note and reports what happens until Muse is done. True when Muse said it
    /// was done; false when `timeout` passed first.
    func ask(
        wav: Data, instructions: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
    ) async throws -> Bool
    var isOpen: Bool { get async }
    func close() async
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

    func ask(
        wav: Data, instructions: String, timeout: Duration,
        onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void
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
            trace?("the watch's chat is new; subscribing after the note")
        }

        let ack = try await session.sendVoice(wav: wav, sessionID: chatID, message: instructions)
        trace?("voice note acknowledged: HTTP \(ack.status)")
        guard ack.ok else { throw MuseQuestionFailure.refused(ack.status) }
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
    private let trace: (@Sendable (String) -> Void)?
    /// The first events' shapes, for the flight recorder (names and keys only).
    private var shapes: [String] = []
    private var eventCount = 0

    init(sessionID: String?, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void, trace: (@Sendable (String) -> Void)? = nil) {
        turn = MuseTurn(sessionID: sessionID)
        self.onEvent = onEvent
        self.trace = trace
    }

    /// One line saying what the turn saw, without any of its text.
    func summarize() {
        trace?("turn saw \(eventCount) event(s), \(turn.replies.count) reply(ies), answer \(turn.answerText.count) chars, complete \(turn.isComplete()); first: \(shapes.joined(separator: " "))")
    }

    func feed(_ event: MuseJSON) async throws {
        eventCount += 1
        if shapes.count < 12 { shapes.append(MuseLinkSession.shape(event)) }
        if Self.isUserMessage(event) {
            if acknowledged { await noteHeard(event) } else { heldUserMessages.append(event) }
            return
        }
        await emit(try turn.feed(event))
    }

    func acknowledge(_ response: MuseJSON?) async throws {
        let result = response?["result"] ?? response
        trace?("acknowledgement keys: \(result?.object?.keys.sorted().joined(separator: ",") ?? "none")")
        userIDs = Set(["message_id", "reply_to_message_id"].compactMap { result?[$0]?.string }.filter { !$0.isEmpty })
        let held = try turn.acknowledge(response)
        acknowledged = true
        for message in heldUserMessages { await noteHeard(message) }
        heldUserMessages = []
        await emit(held)
    }

    func isComplete() -> Bool { turn.isAnswered() }

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
                let answer = turn.answerText
                guard answer != lastAnswer else { continue }
                lastAnswer = answer
                await onEvent(.answer(answer))
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
