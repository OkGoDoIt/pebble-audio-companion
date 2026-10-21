import Foundation

/// Muse's messages on a chat, as a standing subscription sees them: every assistant message that
/// finishes while it listens, with the user message it answers.
///
/// Muse is an agent: besides answering, it writes by itself (a scheduled task's result, an
/// update, a worker's report: "agent-initiated messages … arrive as new assistant messages
/// without a preceding user message", Muse, 2026-10-21), and an answer can come long after
/// whoever asked stopped waiting. A question follows its own turn (`MuseTurn`); this sees the
/// rest. Who should hear about a message is the caller's call: `root` says what it answers.
///
/// A subscription first replays recent events. Messages seen in the first `settle` seconds are
/// that replay, and are never reported. Messages finishing close together (Muse's bubbles of one
/// turn) are reported together, once `quiet` seconds pass with no message activity.
public struct MuseInbox: Sendable {
    public struct Message: Sendable, Equatable {
        public let id: String
        /// Muse's words, its finished text when it sent one.
        public var text: String
        public var widgets: [MuseWidget]
        /// The user message this answers, following replies to replies; nil for a message Muse
        /// started.
        public var root: String?
    }

    public static let settle: TimeInterval = 3
    public static let quiet: TimeInterval = 3
    static let maxTracked = 64
    static let maxTextBytes = 64 * 1024

    private struct Tracked {
        var text = ""
        var finished: String?
        var widgets: [MuseWidget] = []
        var parent: String?
        var done = false
        var reported = false
        /// Seen in the replay: never reported.
        var replayed = false
    }

    private let sessionID: String?
    private var startedAt: TimeInterval
    private var lastActivity: TimeInterval = 0
    private var messages: [String: Tracked] = [:]
    private var order: [String] = []
    /// User messages seen on the chat, by id.
    public private(set) var userMessages: Set<String> = []

    public init(sessionID: String?, startedAt: TimeInterval) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    /// Reads one chat event at `now`.
    public mutating func feed(_ event: MuseJSON, now: TimeInterval) {
        guard event["type"]?.string == "event", let name = event["event"]?.string, let payload = event["payload"],
            payload.object != nil
        else { return }
        if let eventSession = payload["session_id"]?.string ?? event["session_id"]?.string, let sessionID,
            eventSession != sessionID
        {
            return
        }
        let id = payload["message_id"]?.string ?? event["message_id"]?.string ?? payload["id"]?.string
        guard let id, !id.isEmpty, id.utf8.count <= 512 else { return }
        if name == "message.user" || payload["role"]?.string == "user" {
            userMessages.insert(id)
            if userMessages.count > Self.maxTracked * 4 { userMessages.removeFirst() }
            return
        }
        guard MuseTurn.messageEvents.contains(name) else { return }
        var tracked = messages[id] ?? Tracked()
        if messages[id] == nil {
            tracked.replayed = now - startedAt < Self.settle
            order.append(id)
            if order.count > Self.maxTracked {
                let dropped = order.removeFirst()
                messages[dropped] = nil
            }
        }
        if let parent = payload["reply_to_message_id"]?.string ?? payload["parent_message_id"]?.string,
            !parent.isEmpty, parent != id
        {
            tracked.parent = parent
        }
        if name == "delta.text_append", !tracked.done, let delta = payload["text"]?.string,
            tracked.text.utf8.count + delta.utf8.count <= Self.maxTextBytes
        {
            tracked.text += MuseTurn.stripControls(delta)
        }
        for widget in MuseWidget.collect(payload["widgets"]) {
            if let index = tracked.widgets.firstIndex(where: { $0.id == widget.id }) {
                tracked.widgets[index] = widget
            } else if tracked.widgets.count < MuseTurn.maxWidgets {
                tracked.widgets.append(widget)
            }
        }
        if name == "delta.message_done" || name == "message.assistant" {
            if let text = payload["display_text"]?.string ?? payload["content"]?.string, text.utf8.count <= Self.maxTextBytes {
                tracked.finished = MuseTurn.stripControls(text)
            }
            if name == "delta.message_done" || payload["display_text_ready"]?.bool != false { tracked.done = true }
        }
        messages[id] = tracked
        lastActivity = now
    }

    /// Messages that finished and went quiet since the last call, oldest first, each reported once.
    public mutating func due(now: TimeInterval) -> [Message] {
        guard now - lastActivity >= Self.quiet else { return [] }
        var out: [Message] = []
        for id in order {
            guard var tracked = messages[id], tracked.done, !tracked.reported else { continue }
            tracked.reported = true
            messages[id] = tracked
            guard !tracked.replayed else { continue }
            let text = (tracked.finished ?? tracked.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !tracked.widgets.isEmpty else { continue }
            out.append(Message(id: id, text: text, widgets: tracked.widgets, root: root(of: id)))
        }
        return out
    }

    /// The user message a message answers: its parent, or its parent's, while those are Muse's.
    func root(of id: String) -> String? {
        var current = messages[id]?.parent
        var hops = 0
        while let parent = current, let tracked = messages[parent], hops < 16 {
            current = tracked.parent
            hops += 1
            if current == nil { return nil }
        }
        return current
    }
}
