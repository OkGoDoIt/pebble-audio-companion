import Foundation

/// Muse's work on one request, followed through its chat event stream — a port of Meta's
/// `linux/src/musegadget/muse_turn.py` (Apache-2.0).
///
/// Create it before sending the request, `feed` it every event from `subscribeChat`, and
/// `acknowledge` it with the request's `ChatAck`. It returns typed events for this request only:
/// status, each change to an answer message, and task completion. Events from other chats and
/// other requests are dropped.
///
/// Not ported yet from the reference: follow-up requests within one turn (`expect_follow_up`), the
/// cross-turn `ReplayScope`, and ignoring parentless messages for a window. A turn per request,
/// on a fresh subscription, doesn't need them.
public struct MuseTurn: Sendable {
    public struct AgentStatus: Sendable, Equatable {
        public let activityCode: String?
        public let activityText: String?
    }

    /// One assistant message answering the request, as it stands after the latest event. `text` is
    /// the best current text: the streamed deltas, replaced by Muse's final text when it sends one.
    public struct Reply: Sendable, Equatable {
        public let messageID: String
        public var text = ""
        public var streamed = ""
        public var done = false
        /// Proven to answer this request (its parent chain reaches it, or it is on the gadget's
        /// own chat), rather than merely carrying no parent on a shared chat.
        public var bound = false
        /// The widgets the text places (`[[hatch_widget:<id>]]`), as their latest event had them.
        public var widgets: [MuseWidget] = []
    }

    public enum Event: Sendable, Equatable {
        case status(AgentStatus)
        case reply(Reply)
        case taskFinished
    }

    public struct Invalid: Error, Equatable {
        public let reason: String
    }

    /// Silence after which a turn without a terminal task status counts as answered.
    public static let replyQuiet: TimeInterval = 3
    static let maxIDBytes = 512
    static let maxPendingEvents = 64
    static let maxTextBytes = 64 * 1024
    static let maxMessages = 32
    static let maxWidgets = 16
    static let maxObservedIDs = 256
    static let maxIgnoredMessages = 256
    static let activityCodes: Set<String> = [
        "working", "responding", "idle", "online", "thinking", "researching", "planning", "listening",
        "speaking", "processing", "generating", "executing",
    ]
    static let terminalTaskStatuses: Set<String> = ["completed", "failed", "errored", "cancelled", "canceled"]
    static let statusEvents: Set<String> = ["agent.status", "task.status"]
    static let messageEvents: Set<String> = [
        "delta.message_start", "delta.text_append", "delta.message_done", "message.assistant",
    ]

    public private(set) var sessionID: String?
    /// The gadget owns `sessionID`'s chat: every event on it belongs to the current turn, and the
    /// acknowledgement must confirm the chat as a thread.
    public let ownsChat: Bool
    public private(set) var acknowledged = false
    public private(set) var busy = false
    public private(set) var taskFinished = false
    public private(set) var activityCode: String?
    public private(set) var lastActivity: TimeInterval

    private let clock: @Sendable () -> TimeInterval
    private var userIDs: Set<String> = []
    private var replyOrder: [String] = []
    private var repliesByID: [String: Reply] = [:]
    private var pending: [MuseJSON] = []
    private var pendingTextBytes = 0
    private var observedIDs: Set<String> = []
    private var runningTaskIDs: Set<String> = []
    private var ignoredMessages: [String] = []

    public init(
        sessionID: String? = nil, ownsChat: Bool = false,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sessionID = sessionID
        self.ownsChat = ownsChat
        self.clock = clock
        self.lastActivity = clock()
    }

    /// Every assistant message bound to the request, in arrival order.
    public var replies: [Reply] { replyOrder.compactMap { repliesByID[$0] } }

    /// The request's whole answer so far: every reply's text, in order.
    public var answerText: String {
        replies.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Binds the turn to the user message in Muse's acknowledgement; returns the events held until
    /// now.
    public mutating func acknowledge(_ response: MuseJSON?) throws(Invalid) -> [Event] {
        let result = response?["result"] ?? response
        guard let result, result.object != nil else { throw Invalid(reason: "invalid chat acknowledgement") }
        let ids = Set(["message_id", "reply_to_message_id"].compactMap { result[$0]?.string }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { throw Invalid(reason: "acknowledgement omitted the user message id") }
        guard ids.allSatisfy({ $0.utf8.count <= Self.maxIDBytes }) else { throw Invalid(reason: "oversized chat identifier") }
        userIDs = ids
        let acknowledgedSession = result["session_id"]?.string
        if ownsChat, sessionID == nil || acknowledgedSession != sessionID || result["is_thread"]?.bool != true {
            throw Invalid(reason: "Muse did not acknowledge the gadget's dedicated side chat")
        }
        if sessionID == nil, let acknowledgedSession { sessionID = acknowledgedSession }
        acknowledged = true
        let held = pending
        pending = []
        pendingTextBytes = 0
        var events: [Event] = []
        for event in held { events += try feed(event) }
        return events
    }

    /// Reads one raw chat event; returns what it means for this request, often nothing.
    public mutating func feed(_ event: MuseJSON) throws(Invalid) -> [Event] {
        guard event["type"]?.string == "event", let payload = event["payload"], payload.object != nil else { return [] }
        let eventSession = payload["session_id"]?.string ?? event["session_id"]?.string
        if ownsChat {
            guard let sessionID, eventSession == sessionID else { return [] }
            observedIDs.formUnion(try Self.eventIDs(event))
            guard observedIDs.count <= Self.maxObservedIDs else { throw Invalid(reason: "too many activity identifiers") }
        }
        if let eventSession, let sessionID, eventSession != sessionID { return [] }
        guard acknowledged else {
            guard pending.count < Self.maxPendingEvents else { throw Invalid(reason: "too many events before acknowledgement") }
            pendingTextBytes += ["text", "display_text", "content", "transcript"]
                .compactMap { payload[$0]?.string?.utf8.count }.reduce(0, +)
            guard pendingTextBytes <= Self.maxTextBytes else { throw Invalid(reason: "too much pending reply text") }
            pending.append(event)
            return []
        }
        let scoped = ownsChat && sessionID != nil && eventSession == sessionID
        guard let name = event["event"]?.string else { return [] }
        if Self.statusEvents.contains(name) { return status(name, payload, scoped: scoped) }
        if Self.messageEvents.contains(name) { return try message(name, event, payload, scoped: scoped) }
        return []
    }

    /// Muse has answered: at least one reply arrived and Muse is done. Unlike `isComplete`, a
    /// subscription's replay of an earlier request's "completed" can't end a turn that has heard
    /// nothing yet.
    public func isAnswered(now: TimeInterval? = nil) -> Bool {
        !replies.isEmpty && isComplete(now: now)
    }

    /// Muse is done answering: every reply is done and Muse is idle, finished, or quiet.
    public func isComplete(now: TimeInterval? = nil) -> Bool {
        let now = now ?? clock()
        return !busy && replies.allSatisfy(\.done) && (taskFinished || now - lastActivity >= Self.replyQuiet)
    }

    static func eventIDs(_ event: MuseJSON, includeParents: Bool = true) throws(Invalid) -> Set<String> {
        guard let payload = event["payload"], payload.object != nil else { return [] }
        var keys = ["message_id", "id", "task_id"]
        if includeParents { keys += ["reply_to_message_id", "parent_message_id"] }
        var ids: Set<String> = []
        for key in keys {
            if let value = payload[key]?.string, !value.isEmpty {
                guard value.utf8.count <= maxIDBytes else { throw Invalid(reason: "oversized chat identifier") }
                ids.insert((key == "task_id" ? "task:" : "message:") + value)
            }
        }
        if let value = event["message_id"]?.string, !value.isEmpty {
            guard value.utf8.count <= maxIDBytes else { throw Invalid(reason: "oversized chat identifier") }
            ids.insert("message:" + value)
        }
        return ids
    }

    private mutating func status(_ name: String, _ payload: MuseJSON, scoped: Bool) -> [Event] {
        let activity = payload["activity_code"]?.string
        let status = payload["status"]?.string
        let parent = payload["reply_to_message_id"]?.string ?? payload["parent_message_id"]?.string
        let reply = payload["message_id"]?.string.flatMap { repliesByID[$0] }
        let explicitlyLinked = parent.map(userIDs.contains) == true || reply?.bound == true
        let terminal = status.map(Self.terminalTaskStatuses.contains) ?? false
        let wasFinished = taskFinished
        let taskID = payload["task_id"]?.string

        if ownsChat, name == "task.status" {
            if terminal, !(taskID.map(runningTaskIDs.contains) ?? false), !explicitlyLinked { return [] }
            if status == "running", let taskID { runningTaskIDs.insert(taskID) }
            if terminal, let taskID { runningTaskIDs.remove(taskID) }
        }
        if name == "task.status", status != nil {
            taskFinished = terminal && !(ownsChat && !runningTaskIDs.isEmpty)
        }
        if let activity {
            busy = !["", "online", "idle"].contains(activity) && !Self.terminalTaskStatuses.contains(activity)
            if name == "agent.status" { activityCode = Self.activityCodes.contains(activity) ? activity : "other" }
        } else if let status {
            busy = !["", "idle"].contains(status) && !terminal
        }
        if ownsChat, !runningTaskIDs.isEmpty {
            taskFinished = false
            busy = true
        } else if name == "task.status", taskFinished {
            busy = false
        }
        lastActivity = clock()
        if name == "agent.status", scoped || explicitlyLinked, !taskFinished {
            return [.status(AgentStatus(activityCode: activity, activityText: payload["activity_text"]?.string.map(Self.stripControls)))]
        }
        return taskFinished && !wasFinished ? [.taskFinished] : []
    }

    private mutating func message(_ name: String, _ event: MuseJSON, _ payload: MuseJSON, scoped: Bool) throws(Invalid) -> [Event] {
        guard let messageID = payload["message_id"]?.string ?? event["message_id"]?.string ?? payload["id"]?.string,
            !messageID.isEmpty, payload["role"]?.string != "user"
        else { return [] }
        let parent = payload["reply_to_message_id"]?.string ?? payload["parent_message_id"]?.string
        var reply = repliesByID[messageID]
        if let parent, !parent.isEmpty, !userIDs.contains(parent), repliesByID[parent] == nil, !(scoped && parent == messageID) {
            if reply == nil { ignore(messageID) }
            return []
        }
        if reply == nil {
            if ignoredMessages.contains(messageID) { return [] }
            guard repliesByID.count < Self.maxMessages else { throw Invalid(reason: "too many messages for one request") }
            reply = Reply(messageID: messageID)
            replyOrder.append(messageID)
        }
        guard var current = reply else { return [] }
        var bound = current.bound || scoped
        if let parent, !parent.isEmpty {
            bound = scoped || userIDs.contains(parent) || repliesByID[parent]?.bound == true
        }
        lastActivity = clock()
        if name == "delta.text_append", !current.done, let delta = payload["text"]?.string, !delta.isEmpty {
            let clean = Self.stripControls(delta)
            current.text += clean
            current.streamed += clean
        }
        for widget in MuseWidget.collect(payload["widgets"]) {
            if let index = current.widgets.firstIndex(where: { $0.id == widget.id }) {
                current.widgets[index] = widget
            } else if current.widgets.count < Self.maxWidgets {
                current.widgets.append(widget)
            }
        }
        if name == "delta.message_done" || name == "message.assistant" {
            var completed = payload["display_text"]?.string
            if completed == nil {
                if let transcript = payload["transcript"] {
                    completed = transcript.string ?? Self.transcriptText(transcript, messageID: messageID)
                    if completed?.isEmpty != false, transcript.string == nil { completed = payload["content"]?.string }
                } else {
                    completed = payload["content"]?.string
                }
            }
            if let completed { current.text = Self.stripControls(completed) }
            if name == "delta.message_done" || payload["display_text_ready"]?.bool != false {
                current.done = true
            }
        }
        current.bound = bound
        guard current.text.utf8.count <= Self.maxTextBytes, current.streamed.utf8.count <= Self.maxTextBytes else {
            throw Invalid(reason: "more than 64 KiB of reply text")
        }
        repliesByID[messageID] = current
        return [.reply(current)]
    }

    private mutating func ignore(_ messageID: String) {
        ignoredMessages.removeAll { $0 == messageID }
        ignoredMessages.append(messageID)
        if ignoredMessages.count > Self.maxIgnoredMessages { ignoredMessages.removeFirst() }
    }

    /// Only assistant text content from Muse's structured transcript.
    static func transcriptText(_ value: MuseJSON, messageID: String?) -> String {
        if let text = value.string { return text }
        guard let messages = value["messages"]?.array else { return "" }
        var assistants = messages.filter { $0["role"]?.string == "assistant" }
        if let messageID { assistants = assistants.filter { $0["id"]?.string == messageID } }
        guard let content = assistants.last?["content"]?.array else { return "" }
        return content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }

    /// C0 and C1 controls removed, except tab and newline, so reply text can't drive a terminal.
    static func stripControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value == 0x09 || value == 0x0A { return true }
            return !(value <= 0x1F || (0x7F...0x9F).contains(value))
        }))
    }
}
