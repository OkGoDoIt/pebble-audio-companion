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
        let events = try await session.subscribeChat(sessionID: chatID)
        let follower = VoiceTurnFollower(sessionID: chatID, onEvent: onEvent)
        let trace = self.trace
        let reader = Task {
            do {
                for try await event in events { try await follower.feed(event) }
            } catch {
                trace?("chat events ended: \(error)")
            }
        }
        defer { reader.cancel() }

        let ack = try await session.sendVoice(wav: wav, sessionID: chatID, message: instructions)
        trace?("voice note acknowledged: HTTP \(ack.status)")
        guard ack.ok else { throw MuseQuestionFailure.refused(ack.status) }
        try await follower.acknowledge(ack.response)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await follower.isComplete()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
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

    init(sessionID: String?, onEvent: @escaping @Sendable (MuseQuestionEvent) async -> Void) {
        turn = MuseTurn(sessionID: sessionID)
        self.onEvent = onEvent
    }

    func feed(_ event: MuseJSON) async throws {
        if Self.isUserMessage(event) {
            if acknowledged { await noteHeard(event) } else { heldUserMessages.append(event) }
            return
        }
        await emit(try turn.feed(event))
    }

    func acknowledge(_ response: MuseJSON?) async throws {
        let result = response?["result"] ?? response
        userIDs = Set(["message_id", "reply_to_message_id"].compactMap { result?[$0]?.string }.filter { !$0.isEmpty })
        let held = try turn.acknowledge(response)
        acknowledged = true
        for message in heldUserMessages { await noteHeard(message) }
        heldUserMessages = []
        await emit(held)
    }

    func isComplete() -> Bool { turn.isComplete() }

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
