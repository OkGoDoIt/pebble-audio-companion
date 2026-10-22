import Foundation
import MuseLink
import WireProtocol

/// The app's side of what Muse can reach while it answers a question from the watch: the
/// person's recordings, follow-ups and recording control. Provided by the app, which owns them.
public protocol MuseDataProvider: Sendable {
    /// Conversations that overlap `from`–`to`, newest first, their text cut to fit `characters`
    /// in all; with `query`, only the conversations (and passages) that match it.
    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText]
    /// An answer to `question` from the person's own AI, reading their recordings. Nil when no AI
    /// is set up or it couldn't answer.
    func answerFromRecordings(_ question: String) async -> String?
    /// What happened on `day`, or in the seven days ending on it. Nil when there is nothing.
    func recap(day: Date, week: Bool) async -> String?
    func openFollowUps(limit: Int) async -> [MuseFollowUp]
    func addFollowUp(_ text: String, due: Date?) async -> Bool
    /// Pauses recording for `minutes` (0: until resumed). False when recording isn't on.
    func pauseRecording(minutes: Int) async -> Bool
    func resumeRecording() async -> Bool
    /// Marks this moment in the recording, with an optional label.
    func markMoment(_ label: String?) async -> Bool
}

public struct MuseConversationText: Sendable, Equatable {
    public let start: Date
    public let end: Date?
    public let title: String?
    public let text: String

    public init(start: Date, end: Date?, title: String?, text: String) {
        self.start = start
        self.end = end
        self.title = title
        self.text = text
    }
}

public struct MuseFollowUp: Sendable, Equatable {
    public let text: String
    public let due: Date?

    public init(text: String, due: Date?) {
        self.text = text
        self.due = due
    }
}

/// What tools need from the watch: run an action there and wait for how it ended, and say what
/// is happening on its screen.
protocol MuseWatchSide: Sendable {
    func runWatchAction(_ request: WatchActionRequest, wait: Duration) async -> WatchActionResult?
    func showStatus(_ text: String) async
}

/// The tools the gadget registers with Muse, and what runs when Muse calls one.
///
/// Watch actions each have a switch (D7b). Data sources are Ask first: the first time Muse wants
/// one, the watch asks the wearer, and the answer is kept until changed in Settings › Muse. A
/// source that is off is never registered, so Muse doesn't know it exists.
actor MuseTools {
    private let preferences: MusePreferencesStore
    private let data: (any MuseDataProvider)?
    private let eventKit: any MuseEventKitAccess
    private let log: @Sendable (String) -> Void
    private var prompting = false
    private let clock: @Sendable () -> Date
    private let holdLimit: Duration
    /// Sources allowed once, for the question being answered: Muse often reads a source several
    /// times for one answer (steps, then distance, then heart rate).
    private var allowedOnce: [MuseSource: Date] = [:]
    /// Changes allowed once for the question being answered: when, and how many are left.
    private var changesAllowedOnce: [MuseSource: (at: Date, left: Int)] = [:]
    /// Not Now on a change: no more changes, and no more asking, for this question.
    private var changesDeclined: [MuseSource: Date] = [:]
    /// Calls that change something, and how they went, for a repeat that comes soon after.
    private var recentChanges: [(key: String, at: Date, result: MuseJSON)] = []
    /// A call that changes something, repeated within this, gets the first one's result: Muse
    /// retries a call whose reply it never got, and the timer may already be running.
    static let repeatWindow: TimeInterval = 180

    init(
        preferences: MusePreferencesStore, data: (any MuseDataProvider)?, eventKit: any MuseEventKitAccess = MuseEventKitSource(),
        clock: @escaping @Sendable () -> Date = { Date() }, holdLimit: Duration = .seconds(MuseTools.holdLimitSeconds),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.holdLimit = holdLimit
        self.preferences = preferences
        self.data = data
        self.eventKit = eventKit
        self.clock = clock
        self.log = log
    }

    // MARK: - Names

    static let timerCommand = "watch.set_timer"
    static let alarmCommand = "watch.set_alarm"
    static let musicCommand = "watch.music"
    static let quietTimeCommand = "watch.quiet_time"
    static let openAppCommand = "watch.open_app"
    static let findCommand = "watch.find"
    static let healthCommand = "health.read"
    static let calendarCommand = "calendar"
    static let remindersCommand = "reminders"
    static let conversationsCommand = "conversations"
    static let followUpsCommand = "followups"
    static let recordingCommand = "recording"

    /// The most transcript text one call sends to Meta.
    static let conversationCharacters = 6_000
    /// Muse's own limit for a data call, registered as its `timeout_ms`. Muse ends any call at
    /// about two minutes whatever is registered: a 180 s registration timed out at 125 s on
    /// 2026-10-21 (`node_invoke_timeout`).
    static let dataCallLimitSeconds = 120
    /// How long a call is held open waiting for the person (the watch prompt, or iOS's prompt
    /// after "Open Pebble Audio…"): a little under Muse's limit, so the reply still reaches it.
    static let holdLimitSeconds = 110

    // MARK: - What Muse is told

    /// The gadget's commands for what the person allows: actions switched on, and data sources
    /// that are not off.
    static func commands(for prefs: MusePreferences, hasData: Bool) -> MuseJSON {
        func param(_ type: String, _ description: String) -> MuseJSON {
            ["type": .string(type), "description": .string(description)]
        }
        let date = "an ISO 8601 date-time with its offset, like 2026-10-21T15:00:00-05:00, or a date, like 2026-10-21"
        var c: [String: MuseJSON] = [:]
        let actions = prefs.watchActions
        if actions.contains(.timer) {
            c[timerCommand] = [
                "description": "Start a countdown timer on the user's Pebble watch. When it ends, the watch buzzes and shows its label.",
                "required": ["seconds": param("integer", "How long, in seconds, from 1 to 86400.")],
                "optional": ["label": param("string", "A word or two shown when it ends, like \"Pasta\".")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.alarm) {
            c[alarmCommand] = [
                "description": "Set a one-time alarm on the user's Pebble watch, at a time of day in the watch's local time. It rings once, at the next time that clock time comes round.",
                "required": [
                    "hour": param("integer", "Hour, 0 to 23."),
                    "minute": param("integer", "Minute, 0 to 59."),
                ],
                "optional": ["label": param("string", "What it is for, like \"Flight\".")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.music) {
            c[musicCommand] = [
                "description": "Control the music or podcast playing on the user's phone, through their Pebble watch, or find out what is playing. Returns the title and artist when known.",
                "required": ["action": param("string", "One of: play, pause, next, previous, volume_up, volume_down, now_playing.")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.quietTime) {
            c[quietTimeCommand] = [
                "description": "Turn Quiet Time on or off on the user's Pebble watch. While it is on, notifications don't buzz.",
                "required": ["state": param("string", "on or off.")],
                "optional": ["minutes": param("integer", "With on: turn it back off after this many minutes. Leave out to keep it on until turned off.")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.launchApp) {
            c[openAppCommand] = [
                "description": "Open an app on the user's Pebble watch by its name, like Workout, Weather, Music or Alarms. Returns the app that was opened.",
                "required": ["name": param("string", "The app's name, or the start of it.")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.findWatch) {
            c[findCommand] = [
                "description": "Make the user's Pebble watch buzz and light up so they can find it.",
                "optional": ["seconds": param("integer", "How long, 1 to 30; 10 if not given.")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.recording), hasData {
            c[recordingCommand] = [
                "description": "Control the user's Pebble Audio recording: pause it (for a while or until resumed), resume it, or mark this moment so they can find it later.",
                "required": ["action": param("string", "One of: pause, resume, mark.")],
                "optional": [
                    "minutes": param("integer", "With pause: how long. Leave out to pause until resumed."),
                    "label": param("string", "With mark: a few words saying what the moment is."),
                ],
                "timeout_ms": 15_000,
            ]
        }
        if prefs.access(.health) != .off {
            c[healthCommand] = [
                "description": "Read the user's activity and sleep from their Pebble watch: steps, distance, active minutes, calories, sleep, or their latest heart rate. Daily values, today first.",
                "required": ["metric": param("string", "One of: steps, distance, active_minutes, calories, sleep, heart_rate.")],
                "optional": ["days": param("integer", "How many days, 1 to 7, today first; 1 if not given.")],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        if prefs.access(.calendar) != .off {
            c[calendarCommand] = [
                "description": "The user's calendar on their phone: list events in a time range, or add an event.",
                "required": ["action": param("string", "list or add.")],
                "optional": [
                    "from": param("string", "With list: start of the range, \(date). Today if not given."),
                    "to": param("string", "With list: end of the range, \(date). The end of the from day if not given."),
                    "title": param("string", "With add: the event's title."),
                    "start": param("string", "With add: when it starts, \(date)."),
                    "end": param("string", "With add: when it ends. An hour after the start if not given."),
                    "notes": param("string", "With add: notes for the event."),
                ],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        if prefs.access(.reminders) != .off {
            c[remindersCommand] = [
                "description":
                    "The user's reminders on their phone, in all of their lists (like Groceries or Work). lists returns the list names and which one is the default; read returns reminders not done yet, each with its id, from one list or all of them; add adds one to a list by name; edit changes one by id: its title, due date, notes, list (to move it), or whether it is done; delete removes one by id. Each reply says what is now true, including the list the reminder is in.",
                "required": ["action": param("string", "One of: lists, read, add, edit, delete.")],
                "optional": [
                    "list": param(
                        "string",
                        "A list's name, from lists. With read: only this list (all lists if not given). With add: the list to add to (the default list if not given). With edit: move the reminder to this list. A name that matches no list is an error that names the lists; nothing is added elsewhere."
                    ),
                    "id": param("string", "With edit and delete: the reminder's id, from read or add."),
                    "title": param("string", "With add: what to be reminded of. With edit: the new title."),
                    "due": param("string", "With add or edit: when it is due, \(date). With edit, none removes it."),
                    "notes": param("string", "With add or edit: notes. With edit, none removes them."),
                    "completed": param("string", "With edit: true marks it done, false marks it not done."),
                    "include_completed": param("string", "With read: true also includes reminders completed in the last 30 days."),
                ],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        if prefs.access(.conversations) != .off, hasData {
            c[conversationsCommand] = [
                "description": "The user's recorded conversations from their Pebble watch (other people's words included). search returns transcript text for a time range and/or words to look for; ask has the user's own AI read their recordings and returns only its answer; recap returns a summary of a day or a week.",
                "required": ["action": param("string", "search, ask or recap.")],
                "optional": [
                    "query": param("string", "With search: words to look for. With ask: the question."),
                    "from": param("string", "With search: start of the range, \(date). The last 24 hours if not given."),
                    "to": param("string", "With search: end of the range, \(date). Now if not given."),
                    "date": param("string", "With recap: the day, \(date). Today if not given."),
                    "period": param("string", "With recap: day or week; day if not given."),
                ],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        if prefs.access(.followUps) != .off, hasData {
            c[followUpsCommand] = [
                "description": "The user's follow-ups in Pebble Audio, things they said they would do: list the open ones, or add one.",
                "required": ["action": param("string", "list or add.")],
                "optional": [
                    "text": param("string", "With add: what to follow up on."),
                    "due": param("string", "With add: when, \(date)."),
                ],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        return .object(c)
    }

    // MARK: - Running one

    /// A new question from the watch: what was allowed once is asked about again.
    func questionBegan() {
        allowedOnce.removeAll()
        changesAllowedOnce.removeAll()
        changesDeclined.removeAll()
    }

    func run(_ command: String, _ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        let key = Self.changeKey(command, params)
        let now = clock()
        recentChanges.removeAll { now.timeIntervalSince($0.at) > Self.repeatWindow }
        if let key, let earlier = recentChanges.last(where: { $0.key == key }) {
            log("\(command) repeated within \(Int(Self.repeatWindow / 60)) minutes; answering with the first one's result")
            return earlier.result
        }
        let result = await perform(command, params, watch: watch)
        if let key, result["ok"]?.bool == true { recentChanges.append((key, now, result)) }
        return result
    }

    /// What identifies a call that changes something (a timer, an alarm, a new or deleted
    /// reminder, a new follow-up, a calendar event): its command and parameters. Nil for a call
    /// that only reads.
    static func changeKey(_ command: String, _ params: MuseJSON) -> String? {
        switch command {
        case timerCommand, alarmCommand:
            break
        case remindersCommand:
            // An edit sets fields, so doing it twice is harmless, and a later edit may undo an
            // earlier one: only adds and deletes are answered from the first call.
            guard let action = MuseReminders.Action(params["action"]?.string), action == .add || action == .delete else { return nil }
        case followUpsCommand, calendarCommand:
            guard let action = params["action"]?.string, ["add", "create", "complete"].contains(action) else { return nil }
        default:
            return nil
        }
        return command + " " + params.compactString()
    }

    private func perform(_ command: String, _ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        let prefs = preferences.current.value
        // The person may need time to answer; past this, the call ends as not answered.
        let deadline = ContinuousClock.now + holdLimit
        switch command {
        case Self.timerCommand:
            guard prefs.watchActions.contains(.timer) else { return Self.turnedOff }
            guard let seconds = Self.int(params["seconds"]), (1...86_400).contains(seconds) else {
                return Self.error("seconds must be between 1 and 86400")
            }
            let result = await watch.runWatchAction(.timer(seconds: seconds, label: params["label"]?.string ?? ""), wait: .seconds(10))
            return Self.outcome(result) { _ in ["set": true, "seconds": .number(Double(seconds))] }
        case Self.alarmCommand:
            guard prefs.watchActions.contains(.alarm) else { return Self.turnedOff }
            guard let hour = Self.int(params["hour"]), (0...23).contains(hour),
                let minute = Self.int(params["minute"]), (0...59).contains(minute)
            else { return Self.error("hour must be 0-23 and minute 0-59") }
            let result = await watch.runWatchAction(.alarm(hour: hour, minute: minute, label: params["label"]?.string ?? ""), wait: .seconds(10))
            return Self.outcome(result) { _ in ["set": true, "time": .string(String(format: "%02d:%02d", hour, minute))] }
        case Self.musicCommand:
            guard prefs.watchActions.contains(.music) else { return Self.turnedOff }
            guard let action = Self.musicAction(params["action"]?.string) else {
                return Self.error("action must be play, pause, next, previous, volume_up, volume_down or now_playing")
            }
            let result = await watch.runWatchAction(.music(action), wait: .seconds(10))
            if result?.status == .failed { return Self.error("No music player is connected to the watch.") }
            return Self.outcome(result) { result in
                guard let text = result.textString else { return ["done": true] }
                let parts = text.components(separatedBy: "\n")
                return ["done": true, "title": .string(parts.first ?? ""), "artist": .string(parts.count > 1 ? parts[1] : "")]
            }
        case Self.quietTimeCommand:
            guard prefs.watchActions.contains(.quietTime) else { return Self.turnedOff }
            let state = params["state"]?.string?.lowercased()
            guard state == "on" || state == "off" else { return Self.error("state must be on or off") }
            let minutes = max(0, min(Self.int(params["minutes"]) ?? 0, 24 * 60))
            let result = await watch.runWatchAction(.quietTime(on: state == "on", minutes: minutes), wait: .seconds(10))
            return Self.outcome(result) { _ in ["quiet_time": .string(state ?? "on")] }
        case Self.openAppCommand:
            guard prefs.watchActions.contains(.launchApp) else { return Self.turnedOff }
            guard let name = params["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return Self.error("name is needed")
            }
            let result = await watch.runWatchAction(.launchApp(name: name), wait: .seconds(10))
            if result?.status == .failed { return Self.error("No app on the watch is called \(name).") }
            return Self.outcome(result) { result in ["opened": .string(result.textString ?? name)] }
        case Self.findCommand:
            guard prefs.watchActions.contains(.findWatch) else { return Self.turnedOff }
            let seconds = min(max(Self.int(params["seconds"]) ?? 10, 1), ProtocolConstants.watchActionFindMaxSeconds)
            let result = await watch.runWatchAction(.findWatch(seconds: seconds), wait: .seconds(10))
            return Self.outcome(result) { _ in ["buzzing_seconds": .number(Double(seconds))] }
        case Self.recordingCommand:
            guard prefs.watchActions.contains(.recording), let data else { return Self.turnedOff }
            return await recording(params, data: data)
        case Self.healthCommand:
            if let refusal = await permission(.health, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return await health(params, watch: watch)
        case Self.calendarCommand:
            if let refusal = await phoneAccess(.calendar, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return calendar(params)
        case Self.remindersCommand:
            return await reminders(params, prefs: prefs, watch: watch, deadline: deadline)
        case Self.conversationsCommand:
            guard let data else { return Self.turnedOff }
            if let refusal = await permission(.conversations, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return await conversations(params, data: data)
        case Self.followUpsCommand:
            guard let data else { return Self.turnedOff }
            if let refusal = await permission(.followUps, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return await followUps(params, data: data)
        default:
            return Self.error("unsupported command")
        }
    }

    // MARK: - iOS's own permission

    /// Calendar and Reminders also need iOS's permission, which only an app on screen can ask
    /// for. Nil when the source may be read now; otherwise what to tell Muse, after telling the
    /// wearer on the watch what to do.
    /// `change`: the call changes something (see `permission`).
    private func phoneAccess(
        _ source: MuseSource, prefs: MusePreferences, watch: any MuseWatchSide, deadline: ContinuousClock.Instant,
        change: Bool = false
    ) async -> MuseJSON? {
        let what = source == .calendar ? "calendar" : "reminders"
        if phoneRefused(source) {
            _ = await watch.runWatchAction(.notice(Self.refusedNotice(what)), wait: .seconds(5))
            return Self.reply(.phoneRefused, source)
        }
        if let refusal = await permission(source, prefs: prefs, watch: watch, deadline: deadline, change: change) { return refusal }
        guard !phoneAuthorized(source) else { return nil }
        // Allowed on the watch, but iOS hasn't been asked: the app asks the next time it is
        // opened, once. The call is held open meanwhile, so the read goes on if the person does
        // it now.
        preferences.update { $0.pendingPhoneAccess.insert(source) }
        log("\(source.rawValue): iOS access still needed; asking when the app is next opened")
        _ = await watch.runWatchAction(.notice(Self.openAppNotice(what)), wait: .seconds(5))
        var lastStatus = ContinuousClock.now
        await watch.showStatus("Waiting for your iPhone")
        while ContinuousClock.now < deadline {
            if phoneAuthorized(source) {
                log("\(source.rawValue): iOS access given")
                return nil
            }
            if phoneRefused(source) { return Self.reply(.phoneRefused, source) }
            if ContinuousClock.now - lastStatus > .seconds(30) {
                // Keeps the watch's screen from deciding Muse went quiet.
                lastStatus = ContinuousClock.now
                await watch.showStatus("Waiting for your iPhone")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return Self.reply(.notAnswered, source)
    }

    private func phoneAuthorized(_ source: MuseSource) -> Bool {
        source == .calendar ? eventKit.calendarAuthorized : eventKit.remindersAuthorized
    }

    private func phoneRefused(_ source: MuseSource) -> Bool {
        source == .calendar ? eventKit.calendarRefused : eventKit.remindersRefused
    }

    /// Word for word from docs/privacy-model.md.
    static func openAppNotice(_ what: String) -> String {
        "Open Pebble Audio on your iPhone to give it access to your \(what)."
    }

    static func refusedNotice(_ what: String) -> String {
        "Pebble Audio can't read your \(what). You can allow it in iPhone Settings."
    }

    // MARK: - Asking first

    /// The question the watch asks the first time Muse wants to read a source. A change asks
    /// `changeQuestion` instead. Word for word from docs/privacy-model.md (D7a, D7c-e).
    static func consentQuestion(_ source: MuseSource) -> String {
        switch source {
        case .conversations:
            return "Let Muse read your conversations? What it reads, including what others said, goes to Meta."
        case .health: return "Let Muse read your health data? What it reads goes to Meta."
        case .calendar: return "Let Muse read your calendar? What it reads goes to Meta."
        case .reminders: return "Let Muse read your reminders? What it reads goes to Meta."
        case .followUps: return "Let Muse read your follow-ups? What it reads goes to Meta."
        }
    }

    /// Allow Once first, and highlighted: it lets this question's reads through and asks again
    /// next time (Roger, 2026-10-21).
    static let consentOptions = ["Allow Once", "Always Allow", "Not Now", "Never Allow"]
    /// How long an Allow Once lasts at most, if no new question ends it first.
    static let allowedOnceFor: TimeInterval = 10 * 60

    /// The question the watch asks the first time in a question that Muse wants to change a
    /// source, under Ask first. General, not about one item, and it covers reading too, so one
    /// "add eggs to my grocery list" is one prompt (Roger, 2026-10-22). Word for word from
    /// docs/privacy-model.md, section 4.
    static func changeQuestion(_ source: MuseSource) -> String {
        "Let Muse add to, change, or delete your \(sourceName(source))? What it reads goes to Meta."
    }

    /// How many changes one Allow Once covers; past that the watch asks again.
    static let changesPerAllowOnce = 10
    /// How long a change Allow Once or Not Now lasts at most, if no new question ends it first:
    /// the window in which Muse may act for a question asked on the watch.
    static let changeSession: TimeInterval = MusePushToTalk.toolWindow

    /// How a data call ended without reading anything. Each tells Muse plainly what happened, so
    /// it neither retries a refusal nor gives up on something still pending
    /// (docs/privacy-model.md, section 4, "What Muse is told"). Outcomes only: no data goes with
    /// them.
    enum Refusal {
        case notAllowed
        case notNow
        case phoneRefused
        case notAnswered
        /// Not Now on the watch's question about changes: for the rest of this question.
        case changeDeclined
    }

    static func reply(_ refusal: Refusal, _ source: MuseSource) -> MuseJSON {
        let name = sourceName(source)
        switch refusal {
        case .notAllowed:
            return error("The person does not allow Muse to read their \(name). Do not ask for it again.")
        case .notNow:
            return error("The person said not now. Do not ask for their \(name) again in this conversation.")
        case .phoneRefused:
            return error(
                "Pebble Audio has no access to the person's \(name) in iPhone Settings. They can allow it there. Do not ask again until they do.")
        case .notAnswered:
            return error("The person has not answered yet. You can ask again later.")
        case .changeDeclined:
            return error(
                "The person said not now to changing their \(name), so nothing was changed. Do not try another change in this conversation.")
        }
    }

    /// Nil when `source` may be used now: allowed already, or the wearer allows it on the watch.
    /// The call is held open while the watch asks, up to `deadline`.
    ///
    /// `change`: the call changes something. Under Ask first the watch asks `changeQuestion`
    /// once for the question being answered, even when reading was allowed once: Allow Once
    /// then lets through `changesPerAllowOnce` changes and the question's reads, and asks again
    /// after them; Not Now refuses every change for the rest of the question without asking
    /// again (reads are unaffected); Always Allow makes the source Allowed, Never Allow turns it
    /// off.
    private func permission(
        _ source: MuseSource, prefs: MusePreferences, watch: any MuseWatchSide, deadline: ContinuousClock.Instant,
        change: Bool = false
    ) async -> MuseJSON? {
        switch prefs.access(source) {
        case .allowed: return nil
        case .off: return Self.reply(.notAllowed, source)
        case .ask: break
        }
        if change, let answer = changeAnswered(source) { return answer.refusal }
        if !change, mayReadOnce(source) { return nil }
        // One question on the watch at a time; a second source waits its turn.
        while prompting {
            guard ContinuousClock.now < deadline else { return Self.reply(.notAnswered, source) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The answer may have come while waiting.
        switch preferences.current.value.access(source) {
        case .allowed: return nil
        case .off: return Self.reply(.notAllowed, source)
        case .ask: break
        }
        if change, let answer = changeAnswered(source) { return answer.refusal }
        if !change, mayReadOnce(source) { return nil }
        prompting = true
        defer { prompting = false }
        let left = Int((deadline - ContinuousClock.now).components.seconds)
        guard left >= 1 else { return Self.reply(.notAnswered, source) }
        log("asking the wearer about \(change ? "changing" : "reading") \(source.rawValue)")
        await watch.showStatus("Asking you first")
        // The watch keeps the question up until a few seconds before the call's own limit.
        let shown = min(max(left - 10, 10), 300)
        let result = await watch.runWatchAction(
            .choose(
                question: change ? Self.changeQuestion(source) : Self.consentQuestion(source), options: Self.consentOptions,
                timeoutSeconds: shown),
            wait: .seconds(shown + 8))
        switch (result?.status, result?.value) {
        case (.done?, 0?):
            allowedOnce[source] = clock()
            // This change is the first of the ones allowed.
            if change { changesAllowedOnce[source] = (clock(), Self.changesPerAllowOnce - 1) }
            log("\(source.rawValue): \(change ? "changes" : "reading") allowed once on the watch")
            return nil
        case (.done?, 1?):
            preferences.update { $0.dataAccess[source] = .allowed }
            log("\(source.rawValue): always allowed on the watch")
            return nil
        case (.done?, 3?):
            preferences.update { $0.dataAccess[source] = .off }
            log("\(source.rawValue): turned off on the watch")
            return Self.reply(.notAllowed, source)
        case (.done?, _), (.declined?, _):
            log("\(source.rawValue): not now\(change ? " to changes" : "")")
            if change { changesDeclined[source] = clock() }
            return Self.reply(change ? .changeDeclined : .notNow, source)
        default:
            log("\(source.rawValue): no answer on the watch")
            return Self.reply(.notAnswered, source)
        }
    }

    private struct ChangeAnswer {
        /// Nil: go ahead.
        let refusal: MuseJSON?
    }

    /// How the wearer already answered about changes in this question: nil when the watch must
    /// ask. An allowed change uses up one of those Allow Once let through.
    private func changeAnswered(_ source: MuseSource) -> ChangeAnswer? {
        let now = clock()
        if let since = changesDeclined[source], now.timeIntervalSince(since) < Self.changeSession {
            return ChangeAnswer(refusal: Self.reply(.changeDeclined, source))
        }
        if let grant = changesAllowedOnce[source], now.timeIntervalSince(grant.at) < Self.changeSession, grant.left > 0 {
            changesAllowedOnce[source] = (grant.at, grant.left - 1)
            return ChangeAnswer(refusal: nil)
        }
        return nil
    }

    /// Allowed once on the watch for the question being answered.
    private func mayReadOnce(_ source: MuseSource) -> Bool {
        guard let since = allowedOnce[source] else { return false }
        return clock().timeIntervalSince(since) < Self.allowedOnceFor
    }

    // MARK: - Sources

    private func health(_ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        guard let (metric, unit, scale) = Self.healthMetric(params["metric"]?.string) else {
            return Self.error("metric must be steps, distance, active_minutes, calories, sleep or heart_rate")
        }
        let days = min(max(Self.int(params["days"]) ?? 1, 1), ProtocolConstants.watchActionHealthMaxDays)
        if metric == .heartRate { return await heartRate(days: days, watch: watch) }
        let result = await watch.runWatchAction(.health(metric, days: days), wait: .seconds(10))
        guard result?.status == .done, let text = result?.textString else {
            return Self.error("The watch has no \(params["metric"]?.string ?? "health") data.")
        }
        let numbers = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: clock())
        let formatter = Self.dayFormatter
        let daysJSON: [MuseJSON] = numbers.enumerated().map { index, value in
            let day = calendar.date(byAdding: .day, value: -index, to: today) ?? today
            var entry: [String: MuseJSON] = ["date": .string(formatter.string(from: day))]
            entry[unit] = value < 0 ? .null : .number((Double(value) * scale).rounded())
            return .object(entry)
        }
        return ["ok": true, "payload": ["days": .array(daysJSON)]]
    }

    /// Heart rate: each day's average, lowest and highest from the watch's minute history, and
    /// the latest reading. Background heart rate off is said plainly, so Muse can say where to
    /// turn it on rather than that there is no data.
    private func heartRate(days: Int, watch: any MuseWatchSide) async -> MuseJSON {
        let latest = await watch.runWatchAction(.health(.heartRate, days: 1), wait: .seconds(10))
        if latest?.status == .failed, latest?.textString == WatchActionRequest.heartRateOff {
            return Self.error(
                "heart_rate_off: Heart rate monitoring is turned off on the watch. The person can turn it on in the watch's Health settings.")
        }
        var payload: [String: MuseJSON] = [:]
        if latest?.status == .done, let text = latest?.textString {
            let numbers = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 }
            if let bpm = numbers.first, bpm > 0 {
                payload["latest"] = [
                    "bpm": .number(Double(bpm)),
                    "measured_seconds_ago": numbers.count > 1 && numbers[1] >= 0 ? .number(Double(numbers[1])) : .null,
                ]
            }
        }
        // By day: a few seconds, as the watch reads its minute history a slice at a time.
        let daily = await watch.runWatchAction(.health(.heartRateDaily, days: days), wait: .seconds(30))
        if daily?.status == .done, let text = daily?.textString {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: clock())
            payload["days"] = .array(text.split(separator: ",").enumerated().map { index, field in
                let day = calendar.date(byAdding: .day, value: -index, to: today) ?? today
                var entry: [String: MuseJSON] = ["date": .string(Self.dayFormatter.string(from: day))]
                let parts = field.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 3, parts[0] > 0 {
                    entry["average_bpm"] = .number(Double(parts[0]))
                    entry["lowest_bpm"] = .number(Double(parts[1]))
                    entry["highest_bpm"] = .number(Double(parts[2]))
                } else {
                    entry["average_bpm"] = .null
                }
                return .object(entry)
            })
        }
        guard !payload.isEmpty else {
            return Self.error("no_heart_rate_data: The watch has no heart rate readings for that time.")
        }
        return ["ok": true, "payload": .object(payload)]
    }

    private func calendar(_ params: MuseJSON) -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "list"?, nil:
            let now = clock()
            let from = Self.date(params["from"]?.string)?.date ?? Calendar.current.startOfDay(for: now)
            let to = Self.date(params["to"]?.string).map { $0.hasTime ? $0.date : Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date }
                ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: from)) ?? from
            let events = eventKit.events(from: from, to: to, limit: 40)
            return ["ok": true, "payload": ["events": .array(events.map { Self.json($0) })]]
        case "add"?:
            guard let title = params["title"]?.string, !title.isEmpty, let start = Self.date(params["start"]?.string) else {
                return Self.error("add needs a title and a start")
            }
            do {
                let event = try eventKit.addEvent(
                    title: title, start: start.date, end: Self.date(params["end"]?.string)?.date, notes: params["notes"]?.string)
                return ["ok": true, "payload": ["added": Self.json(event)]]
            } catch {
                return Self.error("The event couldn't be added.")
            }
        default:
            return Self.error("action must be list or add")
        }
    }

    // MARK: - Reminders

    /// Reading asks the way every source does. Changes (add, edit, delete) are asked about once
    /// per question under Ask first (see `permission`); a list Muse names that isn't there is an
    /// error naming the lists, never an add to another list.
    private func reminders(
        _ params: MuseJSON, prefs: MusePreferences, watch: any MuseWatchSide, deadline: ContinuousClock.Instant
    ) async -> MuseJSON {
        guard let action = MuseReminders.Action(params["action"]?.string) else {
            return Self.error("action must be lists, read, add, edit or delete")
        }
        guard action.changes else {
            if let refusal = await phoneAccess(.reminders, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return action == .lists ? reminderLists() : await readReminders(params)
        }
        let request: MuseReminders.Request
        switch MuseReminders.request(action, params) {
        case .invalid(let message): return Self.error(message)
        case .request(let parsed): request = parsed
        }
        guard prefs.access(.reminders) != .off else { return Self.reply(.notAllowed, .reminders) }
        if eventKit.remindersAuthorized {
            // A call that can't happen (no such list or reminder) isn't asked about on the
            // watch. Lists' names go to Muse only when it may read the reminders already.
            let namesAllowed = prefs.access(.reminders) == .allowed || mayReadOnce(.reminders)
            if case .failed(let reply) = resolve(request, namesAllowed: namesAllowed) { return reply }
        }
        if let refusal = await phoneAccess(.reminders, prefs: prefs, watch: watch, deadline: deadline, change: true) {
            return refusal
        }
        // Again: the person may have taken a while, and iOS access may be new.
        switch resolve(request, namesAllowed: true) {
        case .failed(let reply): return reply
        case .ready(let ready): return apply(ready)
        }
    }

    private struct ReadyChange {
        let request: MuseReminders.Request
        /// Edit and delete: the reminder as it is.
        let existing: MuseEventKitSource.Reminder?
        /// Add: the list it goes to. Edit: the list it moves to.
        let list: MuseEventKitSource.ReminderList?
    }

    private enum Resolution {
        case ready(ReadyChange)
        case failed(MuseJSON)
    }

    /// The list and the reminder a change means, from the phone as it is now.
    private func resolve(_ request: MuseReminders.Request, namesAllowed: Bool) -> Resolution {
        let lists = eventKit.reminderLists()
        var list: MuseEventKitSource.ReminderList?
        if let name = request.list {
            switch MuseReminders.match(name, in: lists) {
            case .found(let found): list = found
            case .ambiguous(let candidates): return .failed(MuseReminders.ambiguousList(name, candidates, namesAllowed: namesAllowed))
            case .notFound: return .failed(MuseReminders.noSuchList(name, lists, namesAllowed: namesAllowed))
            }
        } else if request.action == .add {
            guard let fallback = lists.first(where: \.isDefault) else {
                return .failed(Self.error("There is no default reminders list. Name the list to add to."))
            }
            list = fallback
        }
        if let list, !list.canChange { return .failed(MuseReminders.listCannotChange(list.name)) }
        var existing: MuseEventKitSource.Reminder?
        if request.action != .add {
            guard let id = request.id, let found = eventKit.reminder(id: id) else { return .failed(MuseReminders.noSuchReminder) }
            if lists.first(where: { $0.id == found.listID })?.canChange == false {
                return .failed(MuseReminders.listCannotChange(found.list))
            }
            existing = found
        }
        return .ready(ReadyChange(request: request, existing: existing, list: list))
    }

    /// Makes the change and says what is now true.
    private func apply(_ ready: ReadyChange) -> MuseJSON {
        let request = ready.request
        do {
            switch request.action {
            case .add:
                var due: (Date, Bool)?
                if case .set(let date, let hasTime)? = request.due { due = (date, hasTime) }
                let added = try eventKit.addReminder(
                    title: request.title ?? "", due: due?.0, dueHasTime: due?.1 ?? false, notes: request.notes,
                    listID: ready.list?.id)
                log("reminders: added to a list")
                return ["ok": true, "payload": ["added": MuseReminders.json(added)]]
            case .edit:
                guard let before = ready.existing else { return MuseReminders.noSuchReminder }
                var change = MuseEventKitSource.ReminderChange(
                    title: request.title, notes: request.notes, listID: ready.list?.id, completed: request.completed)
                switch request.due {
                case .set(let date, let hasTime)?: change.due = .set(date, hasTime: hasTime)
                case .clear?: change.due = .clear
                case nil: break
                }
                let after = try eventKit.updateReminder(id: before.id, change)
                log("reminders: edited one")
                var payload: [String: MuseJSON] = [
                    "updated": MuseReminders.json(after),
                    "changed": .array(MuseReminders.changedFields(from: before, to: after).map { .string($0) }),
                ]
                if after.listID != before.listID { payload["moved_from"] = .string(before.list) }
                if request.completed == true, !after.completed {
                    // A repeating reminder marked done comes back as its next time.
                    payload["note"] = "It repeats: this time is done, and it is now due again at the date shown."
                }
                return ["ok": true, "payload": .object(payload)]
            case .delete:
                guard let before = ready.existing else { return MuseReminders.noSuchReminder }
                let deleted = try eventKit.deleteReminder(id: before.id)
                log("reminders: deleted one")
                return ["ok": true, "payload": ["deleted": MuseReminders.json(deleted)]]
            case .lists, .read:
                return Self.error("action must be lists, read, add, edit or delete")
            }
        } catch MuseEventKitSource.Failure.noSuchReminder {
            return MuseReminders.noSuchReminder
        } catch MuseEventKitSource.Failure.listCannotChange {
            return MuseReminders.listCannotChange(ready.list?.name ?? ready.existing?.list ?? "")
        } catch {
            switch request.action {
            case .add: return Self.error("The reminder couldn't be added. Nothing was changed.")
            case .delete: return Self.error("The reminder couldn't be deleted.")
            default: return Self.error("The reminder couldn't be changed.")
            }
        }
    }

    private func reminderLists() -> MuseJSON {
        let lists = eventKit.reminderLists()
        guard !lists.isEmpty else { return Self.error("There are no reminders lists on the phone.") }
        var payload: [String: MuseJSON] = ["lists": .array(lists.map { MuseReminders.json($0) })]
        if let fallback = lists.first(where: \.isDefault) { payload["default_list"] = .string(fallback.name) }
        return ["ok": true, "payload": .object(payload)]
    }

    /// The most reminders one read sends.
    static let remindersPerRead = 60

    private func readReminders(_ params: MuseJSON) async -> MuseJSON {
        var listIDs: [String]?
        var listName: String?
        if let name = params["list"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let lists = eventKit.reminderLists()
            switch MuseReminders.match(name, in: lists) {
            case .found(let list):
                listIDs = [list.id]
                listName = list.name
            case .ambiguous(let candidates): return MuseReminders.ambiguousList(name, candidates, namesAllowed: true)
            case .notFound: return MuseReminders.noSuchList(name, lists, namesAllowed: true)
            }
        }
        let since = MuseReminders.bool(params["include_completed"]) == true ? clock().addingTimeInterval(-30 * 24 * 60 * 60) : nil
        let found = MuseReminders.ordered(await eventKit.reminders(inLists: listIDs, completedSince: since))
        let shown = found.prefix(Self.remindersPerRead)
        var payload: [String: MuseJSON] = ["reminders": .array(shown.map { MuseReminders.json($0) })]
        if let listName { payload["list"] = .string(listName) }
        if found.count > shown.count { payload["not_shown"] = .number(Double(found.count - shown.count)) }
        return ["ok": true, "payload": .object(payload)]
    }

    private func conversations(_ params: MuseJSON, data: any MuseDataProvider) async -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "search"?, nil:
            let now = clock()
            let from = Self.date(params["from"]?.string)?.date ?? now.addingTimeInterval(-24 * 60 * 60)
            let to = Self.date(params["to"]?.string).map { $0.hasTime ? $0.date : Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date } ?? now
            let query = params["query"]?.string?.trimmingCharacters(in: .whitespaces)
            let found = await data.conversations(
                from: from, to: to, query: query?.isEmpty == false ? query : nil, characters: Self.conversationCharacters)
            log("conversations: \(found.count) sent")
            return ["ok": true, "payload": ["conversations": .array(found.map { Self.json($0) })]]
        case "ask"?:
            guard let question = params["query"]?.string ?? params["question"]?.string, !question.isEmpty else {
                return Self.error("ask needs the question in query")
            }
            guard let answer = await data.answerFromRecordings(question) else {
                return Self.error("The user's recordings couldn't answer that.")
            }
            return ["ok": true, "payload": ["answer": .string(answer)]]
        case "recap"?:
            let day = Self.date(params["date"]?.string)?.date ?? clock()
            let week = params["period"]?.string?.lowercased() == "week"
            guard let recap = await data.recap(day: day, week: week) else {
                return Self.error("There is no recap for that \(week ? "week" : "day").")
            }
            return ["ok": true, "payload": ["recap": .string(recap)]]
        default:
            return Self.error("action must be search, ask or recap")
        }
    }

    private func followUps(_ params: MuseJSON, data: any MuseDataProvider) async -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "list"?, nil:
            let items = await data.openFollowUps(limit: 40)
            return [
                "ok": true,
                "payload": ["follow_ups": .array(items.map { item in
                    var entry: [String: MuseJSON] = ["text": .string(item.text)]
                    if let due = item.due { entry["due"] = .string(Self.isoFormatter.string(from: due)) }
                    return .object(entry)
                })],
            ]
        case "add"?:
            guard let text = params["text"]?.string, !text.isEmpty else { return Self.error("add needs the text") }
            let added = await data.addFollowUp(text, due: Self.date(params["due"]?.string)?.date)
            return added ? ["ok": true, "payload": ["added": .string(text)]] : Self.error("The follow-up couldn't be added.")
        default:
            return Self.error("action must be list or add")
        }
    }

    private func recording(_ params: MuseJSON, data: any MuseDataProvider) async -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "pause"?:
            let minutes = max(0, Self.int(params["minutes"]) ?? 0)
            return await data.pauseRecording(minutes: minutes)
                ? ["ok": true, "payload": ["paused_minutes": .number(Double(minutes))]]
                : Self.error("Recording isn't on.")
        case "resume"?:
            return await data.resumeRecording() ? ["ok": true, "payload": ["recording": true]] : Self.error("Recording couldn't be resumed.")
        case "mark"?:
            return await data.markMoment(params["label"]?.string) ? ["ok": true, "payload": ["marked": true]] : Self.error("This moment couldn't be marked.")
        default:
            return Self.error("action must be pause, resume or mark")
        }
    }

    // MARK: - Helpers

    static let turnedOff: MuseJSON = ["ok": false, "error": "The user has turned this off."]

    static func error(_ message: String) -> MuseJSON { ["ok": false, "error": .string(message)] }

    /// How a call ended, read from its reply, for the Muse screen.
    static func outcome(of result: MuseJSON) -> MuseToolUse.Outcome {
        if result["ok"]?.bool == true { return .done }
        let message = result["error"]?.string ?? ""
        if message == turnedOff["error"]?.string { return .declined }
        for source in MuseSource.allCases {
            if [Refusal.notAllowed, .notNow, .phoneRefused, .changeDeclined].contains(where: { reply($0, source)["error"]?.string == message }) {
                return .declined
            }
        }
        if message == reply(.notAnswered, .health)["error"]?.string { return .unanswered }
        return .failed(message)
    }

    static func sourceName(_ source: MuseSource) -> String {
        switch source {
        case .conversations: return "conversations"
        case .health: return "health data"
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .followUps: return "follow-ups"
        }
    }

    static func outcome(_ result: WatchActionResult?, _ payload: (WatchActionResult) -> MuseJSON) -> MuseJSON {
        guard let result else { return error("The watch didn't answer.") }
        switch result.status {
        case .done?: return ["ok": true, "payload": payload(result)]
        case .unsupported?: return error("The watch can't do this; its software may need updating.")
        default: return error("The watch couldn't do this.")
        }
    }

    static func int(_ value: MuseJSON?) -> Int? {
        if let number = value?.number { return Int(number.rounded()) }
        if let text = value?.string { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func musicAction(_ name: String?) -> WatchActionRequest.MusicCommand? {
        switch name?.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "play"?, "resume"?: return .play
        case "pause"?, "stop"?: return .pause
        case "toggle"?, "play_pause"?: return .togglePlayPause
        case "next"?, "skip"?: return .next
        case "previous"?, "back"?: return .previous
        case "volume_up"?, "louder"?: return .volumeUp
        case "volume_down"?, "quieter"?: return .volumeDown
        case "now_playing"?, "what_is_playing"?: return .nowPlaying
        default: return nil
        }
    }

    /// The watch's metric, the field it is reported as, and the factor to that field's unit.
    static func healthMetric(_ name: String?) -> (WatchActionRequest.HealthMetric, String, Double)? {
        switch name?.lowercased() {
        case "steps"?: return (.steps, "steps", 1)
        case "distance"?: return (.distanceMeters, "meters", 1)
        case "active_minutes"?, "active"?: return (.activeSeconds, "active_minutes", 1.0 / 60)
        case "calories"?: return (.activeKCalories, "active_kcal", 1)
        case "sleep"?: return (.sleepSeconds, "sleep_minutes", 1.0 / 60)
        case "heart_rate"?, "heartrate"?: return (.heartRate, "bpm", 1)
        default: return nil
        }
    }

    struct ParsedDate {
        let date: Date
        let hasTime: Bool
    }

    /// ISO 8601 with or without fractional seconds or offset (local time then), or a bare date.
    static func date(_ text: String?) -> ParsedDate? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return ParsedDate(date: date, hasTime: true) }
        }
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return ParsedDate(date: date, hasTime: hasTime) }
        }
        return nil
    }

    /// Formatters are safe to share for formatting.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func json(_ event: MuseEventKitSource.Event) -> MuseJSON {
        var entry: [String: MuseJSON] = [
            "title": .string(event.title),
            "start": .string(isoFormatter.string(from: event.start)),
            "end": .string(isoFormatter.string(from: event.end)),
            "all_day": .bool(event.allDay),
            "calendar": .string(event.calendar),
        ]
        if let location = event.location { entry["location"] = .string(location) }
        return .object(entry)
    }

    static func json(_ conversation: MuseConversationText) -> MuseJSON {
        var entry: [String: MuseJSON] = [
            "start": .string(isoFormatter.string(from: conversation.start)),
            "transcript": .string(conversation.text),
        ]
        if let end = conversation.end { entry["end"] = .string(isoFormatter.string(from: end)) }
        if let title = conversation.title, !title.isEmpty { entry["title"] = .string(title) }
        return .object(entry)
    }
}

/// A request Muse made of the watch or the phone while answering a question, and how it ended,
/// for the Muse screen: its command, never what it carried.
public struct MuseToolUse: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case done
        /// The person said no, or has it turned off.
        case declined
        /// The watch asked and the person didn't answer in time.
        case unanswered
        /// It couldn't be done; the words say why.
        case failed(String)
    }

    public let command: String
    public let outcome: Outcome

    public init(command: String, outcome: Outcome) {
        self.command = command
        self.outcome = outcome
    }
}
