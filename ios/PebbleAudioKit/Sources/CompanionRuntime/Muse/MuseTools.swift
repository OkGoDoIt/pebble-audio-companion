import Foundation
import MuseLink
import WireProtocol

/// The app's side of what Muse can reach while it answers a question from the watch: the
/// person's recordings, reminders, follow-ups and recording control. Provided by the app, which
/// owns them.
public protocol MuseDataProvider: Sendable {
    /// Conversations that overlap `from`–`to`, newest first, their text cut to fit `characters`
    /// in all; with `query`, only the conversations (and passages) that match it.
    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText]
    /// An answer to `question` from the person's own AI, reading their recordings. Nil when no AI
    /// is set up or it couldn't answer.
    func answerFromRecordings(_ question: String) async -> String?
    /// What happened on `day`, or in its calendar week. Nil when there is nothing.
    func recap(day: Date, week: Bool) async -> String?

    // Reminders the app keeps itself (`docs/reminders.md`): the reminders tool's "Pebble Audio"
    // list while the app is their home. Only reminders: never a follow-up waiting for review.

    /// Where reminders are kept.
    func reminderHome() async -> ReminderHome
    /// Open reminders, and with `completedSince` the ones completed since then.
    func appReminders(completedSince: Date?) async -> [MuseAppReminder]
    /// One reminder, nil when there is none by that id (or it was filed away).
    func appReminder(id: String) async -> MuseAppReminder?
    /// A new reminder an assistant was asked for. Nil when it couldn't be added.
    func addAppReminder(title: String, due: Date?) async -> MuseAppReminder?
    /// Its title, due day, or done; the rest of `change` is never set. The reminder as it is now.
    func updateAppReminder(id: String, _ change: MuseEventKitSource.ReminderChange) async -> MuseAppReminder?
    /// Files it away (off the list, kept, findable). What it was; nil when there is none.
    func fileAwayAppReminder(id: String) async -> MuseAppReminder?

    // Follow-ups: what the app noticed, waiting for review.

    /// Follow-ups waiting for review, oldest said first.
    func followUpsToReview(limit: Int) async -> [MuseFollowUp]
    /// Turns a follow-up waiting for review into a reminder, or skips it. Nil when no follow-up
    /// with that id is waiting.
    func decideFollowUp(id: String, remind: Bool) async -> MuseFollowUpDecision?
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

/// A follow-up waiting for review: something the app noticed, not something decided.
public struct MuseFollowUp: Sendable, Equatable {
    public let id: String
    public let text: String
    public let due: Date?
    /// When it was said.
    public let saidAt: Date?
    /// The conversation's title.
    public let conversation: String?
    /// The words said.
    public let quote: String?
    /// Why it might matter.
    public let why: String?

    public init(
        id: String = "", text: String, due: Date?, saidAt: Date? = nil, conversation: String? = nil,
        quote: String? = nil, why: String? = nil
    ) {
        self.id = id
        self.text = text
        self.due = due
        self.saidAt = saidAt
        self.conversation = conversation
        self.quote = quote
        self.why = why
    }
}

/// A reminder the app keeps itself.
public struct MuseAppReminder: Sendable, Equatable {
    public let id: String
    public let title: String
    /// The day it is due, at its start.
    public let due: Date?
    public let done: Bool

    public init(id: String, title: String, due: Date?, done: Bool) {
        self.id = id
        self.title = title
        self.due = due
        self.done = done
    }
}

/// Where a follow-up went when it was decided.
public struct MuseFollowUpDecision: Sendable, Equatable {
    public let id: String
    public let title: String
    /// Its reminder is kept in Apple Reminders.
    public let keptInApple: Bool
    /// The list it is in: "Pebble Audio", or the Apple list's name.
    public let list: String
    /// The reminders tool's id for it, when known now.
    public let reminderID: String?

    public init(id: String, title: String, keptInApple: Bool, list: String, reminderID: String?) {
        self.id = id
        self.title = title
        self.keptInApple = keptInApple
        self.list = list
        self.reminderID = reminderID
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
    private var inFlightChanges: [String: Task<MuseJSON, Never>] = [:]
    private var questionGeneration = 0
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
    static let timersCommand = "watch.timers"
    static let alarmCommand = "watch.set_alarm"
    static let alarmsCommand = "watch.alarms"
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
                "description": "Start a countdown timer on the user's Pebble watch. Returns its id and current state. Use watch.timers to list, check, pause, resume, change, restart or cancel timers. Maximum four live timers; timers do not survive a watch reboot.",
                "required": ["seconds": param("integer", "How long, in seconds, from 1 to 86400.")],
                "optional": ["label": param("string", "A word or two shown when it ends, like \"Pasta\".")],
                "timeout_ms": 30_000,
            ]
        }
        if actions.contains(.timer) {
            c[timersCommand] = [
                "description": "Manage Pebble watch countdowns. List first to get ids and labels; ask which timer if ambiguous. get reads live time remaining. update preserves omitted fields: seconds sets time remaining from now (and the restart duration), preserving paused state; label renames. restart starts the original or updated duration again. cancel removes a timer. Finished timers remain readable/restartable until their slot is reused. At most four running/paused timers; all are lost on watch reboot. Never create a replacement to edit a timer. After an unconfirmed change, read status before retrying.",
                "required": ["action": param("string", "list, create, get, pause, resume, update, restart or cancel.")],
                "optional": [
                    "id": param("integer", "Timer id from list/create; required except for list/create."),
                    "seconds": param("integer", "Required for create; optional for update: 1-86400 seconds remaining."),
                    "label": param("string", "With create/update: label, up to 48 UTF-8 bytes; empty clears it."),
                ],
                "timeout_ms": 60_000,
            ]
        }
        if actions.contains(.alarm) {
            c[alarmCommand] = [
                "description": "Create a regular or smart one-time alarm on the Pebble watch, in watch local time. A smart alarm may wake the user up to 30 minutes BEFORE this time, and rings at this time at the latest. The window is fixed. Alarms have no stored labels. Use watch.alarms to list, change or delete existing alarms; do not create a replacement when asked to change one.",
                "required": [
                    "hour": param("integer", "Hour, 0 to 23."),
                    "minute": param("integer", "Minute, 0 to 59."),
                ],
                "optional": ["smart": param("boolean", "true for smart wake, false for an exact alarm; false if omitted.")],
                "timeout_ms": 15_000,
            ]
        }
        if actions.contains(.alarm) {
            c[alarmsCommand] = [
                "description": "List, update or delete the watch's regular and smart alarms. Always list first to get an existing alarm's id; ask which one if ambiguous. Update preserves omitted fields, recurrence, sound and vibration. Smart wake uses a fixed 30-minute window before the alarm time. Alarms have no labels.",
                "required": ["action": param("string", "list, update or delete.")],
                "optional": [
                    "id": param("integer", "With update/delete: the id returned by list, 0-9."),
                    "hour": param("integer", "With update: new local hour, 0-23."),
                    "minute": param("integer", "With update: new minute, 0-59."),
                    "smart": param("boolean", "With update: true for smart wake; false for exact time."),
                    "enabled": param("boolean", "With update: enable or disable the alarm."),
                ],
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
                "description": "Request a pause or resume of Pebble Audio recording, or save a marked moment. Pause/resume changes the app's intent; it does not confirm watch capture. A mark can be saved without audio and is not a reminder.",
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
                    "The user's reminders: everything they said yes to or asked to be reminded of, in all of their lists, Apple Reminders lists (like Groceries or Work) and the Pebble Audio list, which holds the reminders they made from their recorded conversations. lists returns the list names and which one is the default; read returns reminders not done yet, each with its id, from one list or all of them; add adds one to a list by name; edit changes one by id: its title, due date, notes, list (to move it), or whether it is done; delete removes one by id. Each reply says what is now true, including the list the reminder is in. Follow-ups waiting for review are not reminders; they are in the followups tool.",
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
                    "period": param("string", "With recap: day or the calendar week containing date; day if not given."),
                ],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        if prefs.access(.followUps) != .off, hasData {
            c[followUpsCommand] = [
                "description":
                    "The user's follow-ups: things Pebble Audio noticed in their recorded conversations that they might want to act on, waiting for them to review. A follow-up is a suggestion, not a commitment and not their to-do list: never present follow-ups as things they have to do. read returns the ones waiting, each with its id, the task, when it was said, the conversation, the words said, and why it might matter. remind turns one into a reminder, and skip sets one aside; do either only when the user asks. To add something the user wants to remember, use the reminders tool.",
                "required": ["action": param("string", "One of: read, remind, skip.")],
                "optional": ["id": param("string", "With remind and skip: the follow-up's id, from read.")],
                "timeout_ms": .number(Double(dataCallLimitSeconds * 1000)),
            ]
        }
        return .object(c)
    }

    // MARK: - Running one

    /// A new question from the watch: what was allowed once is asked about again.
    func questionBegan() {
        questionGeneration += 1
        recentChanges.removeAll()
        allowedOnce.removeAll()
        changesAllowedOnce.removeAll()
        changesDeclined.removeAll()
    }

    func run(_ command: String, _ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        guard Self.commands(for: preferences.current.value, hasData: data != nil)[command] != nil else {
            return await perform(command, params, watch: watch)
        }
        let key = Self.changeKey(command, params)
        let now = clock()
        let generation = questionGeneration
        recentChanges.removeAll { now.timeIntervalSince($0.at) > Self.repeatWindow }
        if let key, let earlier = recentChanges.last(where: { $0.key == key }) {
            return earlier.result
        }
        let flightKey = key.map { "\(generation) \($0)" }
        if let flightKey, let pending = inFlightChanges[flightKey] { return await pending.value }
        let task = Task { await self.perform(command, params, watch: watch) }
        if let flightKey { inFlightChanges[flightKey] = task }
        let result = await task.value
        if let flightKey { inFlightChanges[flightKey] = nil }
        if let key, generation == questionGeneration,
           result["ok"]?.bool == true || result["outcome_unknown"]?.bool == true {
            if command == Self.alarmCommand || command == Self.alarmsCommand {
                recentChanges.removeAll { $0.key.hasPrefix(Self.alarmCommand + " ") || $0.key.hasPrefix(Self.alarmsCommand + " ") }
            }
            if command == Self.timersCommand, params["action"]?.string != "create",
               let changedID = Self.int(params["id"]) {
                // Editing one timer must not forget another timer's creation (including an
                // unconfirmed creation). Otherwise a later retry could start it twice.
                recentChanges.removeAll {
                    $0.key.hasPrefix(Self.timersCommand + " ") &&
                    Self.int($0.result["payload"]?["id"]) == changedID
                }
            }
            recentChanges.append((key, clock(), result))
        }
        return result
    }

    /// What identifies a call that changes something (a timer, an alarm, a new or deleted
    /// reminder, a follow-up decided, a calendar event): its command and parameters. Nil for a
    /// call that only reads.
    static func changeKey(_ command: String, _ params: MuseJSON) -> String? {
        if command == timerCommand || (command == timersCommand && params["action"]?.string == "create") {
            var canonical = params.object ?? [:]
            canonical["action"] = "create"
            canonical["label"] = params["label"] ?? ""
            return timersCommand + " " + MuseJSON.object(canonical).compactString()
        }
        switch command {
        case alarmCommand:
            break
        case timersCommand:
            guard !["list", "get"].contains(params["action"]?.string ?? "") else { return nil }
        case alarmsCommand:
            guard params["action"]?.string != "list" else { return nil }
        case remindersCommand:
            // An edit sets fields, so doing it twice is harmless, and a later edit may undo an
            // earlier one: only adds and deletes are answered from the first call.
            guard let action = MuseReminders.Action(params["action"]?.string), action == .add || action == .delete else { return nil }
        case followUpsCommand:
            // Answered from the first call: a repeat would find it decided already.
            guard let action = FollowUpAction(params["action"]?.string), action == .remind || action == .skip else { return nil }
        case calendarCommand:
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
            return await timers(["action": "create", "seconds": .number(Double(seconds)),
                                 "label": params["label"] ?? ""], watch: watch)
        case Self.timersCommand:
            guard prefs.watchActions.contains(.timer) else { return Self.turnedOff }
            return await timers(params, watch: watch)
        case Self.alarmCommand:
            guard prefs.watchActions.contains(.alarm) else { return Self.turnedOff }
            guard let hour = Self.int(params["hour"]), (0...23).contains(hour),
                let minute = Self.int(params["minute"]), (0...59).contains(minute)
            else { return Self.error("hour must be 0-23 and minute 0-59") }
            guard params["smart"] == nil || params["smart"]?.bool != nil else { return Self.error("smart must be a boolean") }
            let smart = params["smart"]?.bool ?? false
            var result = await watch.runWatchAction(.alarms(.create, hour: hour, minute: minute,
                                                           smart: smart ? 1 : 0, enabled: 1), wait: .seconds(10))
            if result?.status == .unsupported, !smart {
                result = await watch.runWatchAction(.alarm(hour: hour, minute: minute, label: ""), wait: .seconds(10))
                return Self.outcome(result) { _ in
                    ["set": true, "smart": false, "time": .string(String(format: "%02d:%02d", hour, minute))]
                }
            }
            guard result != nil else {
                return Self.unconfirmed("alarm", read: "watch.alarms list")
            }
            return Self.outcome(result) { result in
                ["set": true, "id": .number(Double(result.value)), "smart": .bool(smart),
                 "time": .string(String(format: "%02d:%02d", hour, minute)),
                 "wake_window_minutes": .number(smart ? 30 : 0)]
            }
        case Self.alarmsCommand:
            guard prefs.watchActions.contains(.alarm) else { return Self.turnedOff }
            return await alarms(params, watch: watch)
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
            guard params["minutes"] == nil || Self.int(params["minutes"]).map({ (0...1440).contains($0) }) == true else {
                return Self.error("minutes must be an integer from 0 to 1440")
            }
            let minutes = Self.int(params["minutes"]) ?? 0
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
            guard params["seconds"] == nil || Self.int(params["seconds"]).map({ (1...30).contains($0) }) == true else {
                return Self.error("seconds must be an integer from 1 to 30")
            }
            let seconds = Self.int(params["seconds"]) ?? 10
            let result = await watch.runWatchAction(.findWatch(seconds: seconds), wait: .seconds(10))
            return Self.outcome(result) { _ in ["buzzing_seconds": .number(Double(seconds))] }
        case Self.recordingCommand:
            guard prefs.watchActions.contains(.recording), let data else { return Self.turnedOff }
            return await recording(params, data: data)
        case Self.healthCommand:
            if let refusal = await permission(.health, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return await health(params, watch: watch)
        case Self.calendarCommand:
            let action = params["action"]?.string?.lowercased() ?? "list"
            guard ["list", "add"].contains(action) else { return Self.error("action must be list or add") }
            if let error = Self.calendarParameterError(params, action: action) { return Self.error(error) }
            if let refusal = await phoneAccess(.calendar, prefs: prefs, watch: watch, deadline: deadline,
                                               change: action == "add") { return refusal }
            return calendar(params)
        case Self.remindersCommand:
            return await reminders(params, prefs: prefs, watch: watch, deadline: deadline)
        case Self.conversationsCommand:
            guard let data else { return Self.turnedOff }
            if let refusal = await permission(.conversations, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            return await conversations(params, data: data)
        case Self.followUpsCommand:
            guard let data else { return Self.turnedOff }
            return await followUps(params, data: data, prefs: prefs, watch: watch, deadline: deadline)
        default:
            return Self.error("unsupported command")
        }
    }

    private func timers(_ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        let names = ["list", "create", "get", "pause", "resume", "update", "restart", "cancel"]
        guard let name = params["action"]?.string, let index = names.firstIndex(of: name),
              let operation = WatchActionRequest.TimerOperation(rawValue: UInt8(index)) else {
            return Self.error("action must be list, create, get, pause, resume, update, restart or cancel")
        }
        let id = Self.int(params["id"]).flatMap(UInt32.init(exactly:)) ?? 0
        guard index < 2 ? params["id"] == nil : id != 0 else { return Self.error("Use the timer id returned by list/create.") }
        guard params["label"] == nil || params["label"]?.string != nil else { return Self.error("label must be text") }
        let label = params["label"]?.string
        guard label.map({ $0.utf8.count <= ProtocolConstants.watchActionLabelMaxBytes && !$0.contains("\0") }) ?? true else {
            return Self.error("label must fit in 48 UTF-8 bytes and contain no null characters")
        }
        let seconds = Self.int(params["seconds"]) ?? 0
        guard params["seconds"] == nil || (1...86400).contains(seconds) else {
            return Self.error("seconds must be an integer from 1 to 86400")
        }
        let request = WatchActionRequest.timers(operation, id: id, seconds: seconds, label: label)
        guard (try? request.payload()) != nil else { return Self.error("Invalid fields for this timer action.") }
        var result = await watch.runWatchAction(request, wait: .seconds(10))
        if operation == .create, result?.status == .unsupported {
            // Only a definitive Unsupported permits fallback; never retry an ambiguous write.
            result = await watch.runWatchAction(.timer(seconds: seconds, label: label ?? ""), wait: .seconds(10))
            guard let result else { return Self.unconfirmed("timer", read: "watch.timers list after updating firmware") }
            return Self.outcome(result) { _ in
                ["set": true, "seconds": .number(Double(seconds)), "managed": false,
                 "note": "Timer started on older firmware. Update the watch for status, edits and cancellation."]
            }
        }
        guard let result else {
            return operation == .get || operation == .list ? Self.error("The watch did not answer; timer state is unknown.")
                : Self.unconfirmed("timer", read: "watch.timers list/get")
        }
        guard result.status == .done else {
            if result.status == .failed, let message = result.textString, !message.isEmpty { return Self.error(message) }
            return Self.outcome(result) { _ in [:] }
        }
        if operation == .cancel { return ["ok": true, "payload": ["id": .number(Double(id)), "cancelled": true]] }
        if operation == .list {
            let fields = (result.textString ?? "").split(separator: "\n")
            let ids = fields.compactMap { UInt32($0) }
            guard fields.count == ids.count, ids.count <= 4, !ids.contains(0), Set(ids).count == ids.count else {
                return Self.error("The watch returned an invalid timer list.")
            }
            var rows: [MuseJSON] = []
            for timerID in ids {
                let detail = await watch.runWatchAction(.timers(.get, id: timerID), wait: .seconds(10))
                guard detail?.status == .done, let row = Self.timerJSON(detail?.textString),
                      row["id"]?.number == Double(timerID) else {
                    return Self.error("Timer list changed or could not be fully read; list again before changing a timer.")
                }
                rows.append(row)
            }
            return ["ok": true, "payload": ["timers": .array(rows), "max_live_timers": 4, "survives_watch_restart": false]]
        }
        guard let row = Self.timerJSON(result.textString), operation == .create || row["id"]?.number == Double(id) else {
            return operation == .get ? Self.error("The watch returned invalid timer status.")
                : Self.unconfirmed("timer", read: "watch.timers list/get")
        }
        return ["ok": true, "payload": row]
    }

    private static func timerJSON(_ text: String?) -> MuseJSON? {
        guard let text else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fields = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4, let id = UInt32(fields[0]), id != 0,
              let state = Int(fields[1]), (1...3).contains(state),
              let ms = Int(fields[2]), (0...86_400_000).contains(ms),
              let duration = Int(fields[3]), (1...86400).contains(duration) else { return nil }
        return ["id": .number(Double(id)), "label": .string(String(parts[1])),
                "state": .string(["running", "paused", "finished"][state - 1]),
                "remaining_seconds": .number(Double((ms + 999) / 1000)),
                "duration_seconds": .number(Double(duration)), "survives_watch_restart": false]
    }

    private func alarms(_ params: MuseJSON, watch: any MuseWatchSide) async -> MuseJSON {
        let operation: WatchActionRequest.AlarmOperation
        switch params["action"]?.string {
        case "list": operation = .list
        case "update": operation = .update
        case "delete": operation = .delete
        default: return Self.error("action must be list, update or delete")
        }
        let id = Self.int(params["id"]) ?? -1
        guard operation == .list || (0...9).contains(id) else { return Self.error("List the alarms first, then use an id from 0 to 9.") }
        for (key, range) in [("hour", 0...23), ("minute", 0...59)] where params[key] != nil {
            guard let value = Self.int(params[key]), range.contains(value) else { return Self.error("Invalid \(key)") }
        }
        for key in ["smart", "enabled"] where params[key] != nil {
            guard params[key]?.bool != nil else { return Self.error("\(key) must be a boolean") }
        }
        if operation == .update, ["hour", "minute", "smart", "enabled"].allSatisfy({ params[$0] == nil }) {
            return Self.error("Specify at least one field to change.")
        }
        let request = WatchActionRequest.alarms(operation, id: operation == .list ? 0 : id,
            hour: Self.int(params["hour"]) ?? 255, minute: Self.int(params["minute"]) ?? 255,
            smart: params["smart"]?.bool.map { $0 ? 1 : 0 } ?? 255,
            enabled: params["enabled"]?.bool.map { $0 ? 1 : 0 } ?? 255)
        let result = await watch.runWatchAction(request, wait: .seconds(10))
        return Self.outcome(result) { result in
            if operation != .list { return ["id": .number(Double(id)), "action": params["action"] ?? .null] }
            // Fixed-width records fit all ten alarms in the 160-byte result: iHHMMsekDD.
            let rows: [MuseJSON] = (result.textString ?? "").split(separator: "\n").compactMap { row in
                let bytes = Array(row.utf8)
                guard bytes.count == 10 else { return nil }
                func number(_ range: Range<Int>, radix: Int = 10) -> Int {
                    Int(String(decoding: bytes[range], as: UTF8.self), radix: radix) ?? 0
                }
                let kinds = ["everyday", "weekends", "weekdays", "once", "custom"]
                let kind = number(7..<8)
                return ["id": .number(Double(number(0..<1))),
                        "hour": .number(Double(number(1..<3))), "minute": .number(Double(number(3..<5))),
                        "smart": .bool(number(5..<6) == 1), "enabled": .bool(number(6..<7) == 1),
                        "repeat": .string(kinds.indices.contains(kind) ? kinds[kind] : "unknown"),
                        "days_sunday_bit0": .number(Double(number(8..<10, radix: 16)))]
            }
            return ["alarms": .array(rows), "smart_wake_window_minutes": 30]
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
        switch source {
        case .followUps: return "Let Muse turn your follow-ups into reminders or skip them? What it reads goes to Meta."
        case .calendar: return "Let Muse add events to your calendar? What it reads goes to Meta."
        default: return "Let Muse add to, change, or delete your \(sourceName(source))? What it reads goes to Meta."
        }
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
        guard params["days"] == nil || Self.int(params["days"]).map({ (1...7).contains($0) }) == true else {
            return Self.error("days must be an integer from 1 to 7")
        }
        let days = Self.int(params["days"]) ?? 1
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

    private static func calendarParameterError(_ params: MuseJSON, action: String) -> String? {
        for key in action == "add" ? ["start", "end"] : ["from", "to"] where params[key] != nil {
            guard let text = params[key]?.string, date(text) != nil else { return "Invalid \(key) date." }
        }
        if action == "add" {
            guard let title = params["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = date(params["start"]?.string) else { return "add needs a title and a start" }
            if let end = date(params["end"]?.string), end.date <= start.date { return "end must be after start" }
        } else if let from = date(params["from"]?.string), let to = date(params["to"]?.string),
                  to.date < from.date || (to.hasTime && to.date == from.date) {
            return "to must be after from"
        }
        return nil
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

    /// Everything the person said yes to: their Apple Reminders lists, and the reminders Pebble
    /// Audio keeps itself, shown as one more list called "Pebble Audio" (`docs/reminders.md`).
    /// While the app keeps its reminders in Apple Reminders they are already in an Apple list, so
    /// that list is shown only while the app keeps them, or Apple Reminders can't be reached.
    private func appListShown() async -> Bool {
        guard let data else { return false }
        if !eventKit.remindersAuthorized { return true }
        return await data.reminderHome() == .app
    }

    /// Reading asks the way every source does. Changes (add, edit, delete) are asked about once
    /// per question under Ask first (see `permission`); a list Muse names that isn't there is an
    /// error naming the lists, never an add to another list.
    private func reminders(
        _ params: MuseJSON, prefs: MusePreferences, watch: any MuseWatchSide, deadline: ContinuousClock.Instant
    ) async -> MuseJSON {
        guard let action = MuseReminders.Action(params["action"]?.string) else {
            return Self.error("action must be lists, read, add, edit or delete")
        }
        let appList = await appListShown()
        // iOS's access is for Apple Reminders: a call that touches only the Pebble Audio list
        // goes on without it.
        let apple = needsApple(params, appList: appList)
        guard action.changes else {
            if let refusal = await remindersAccess(apple, prefs: prefs, watch: watch, deadline: deadline, change: false) {
                return refusal
            }
            return action == .lists ? reminderLists(appList: appList) : await readReminders(params, appList: appList)
        }
        let request: MuseReminders.Request
        switch MuseReminders.request(action, params) {
        case .invalid(let message): return Self.error(message)
        case .request(let parsed): request = parsed
        }
        guard prefs.access(.reminders) != .off else { return Self.reply(.notAllowed, .reminders) }
        if eventKit.remindersAuthorized || !apple {
            // A call that can't happen (no such list or reminder) isn't asked about on the
            // watch. Lists' names go to Muse only when it may read the reminders already.
            let namesAllowed = prefs.access(.reminders) == .allowed || mayReadOnce(.reminders)
            if case .failed(let reply) = await resolve(request, namesAllowed: namesAllowed, appList: appList) { return reply }
        }
        if let refusal = await remindersAccess(apple, prefs: prefs, watch: watch, deadline: deadline, change: true) {
            return refusal
        }
        // Again: the person may have taken a while, and iOS access may be new.
        switch await resolve(request, namesAllowed: true, appList: appList) {
        case .failed(let reply): return reply
        case .ready(let ready): return await apply(ready)
        }
    }

    private func remindersAccess(
        _ apple: Bool, prefs: MusePreferences, watch: any MuseWatchSide, deadline: ContinuousClock.Instant, change: Bool
    ) async -> MuseJSON? {
        apple
            ? await phoneAccess(.reminders, prefs: prefs, watch: watch, deadline: deadline, change: change)
            : await permission(.reminders, prefs: prefs, watch: watch, deadline: deadline, change: change)
    }

    /// Whether a call needs Apple Reminders: not when the Pebble Audio list is shown, Apple
    /// Reminders can't be read, and the call names nothing but that list and its reminders.
    private func needsApple(_ params: MuseJSON, appList: Bool) -> Bool {
        guard appList, !eventKit.remindersAuthorized else { return true }
        if let id = params["id"]?.string?.trimmingCharacters(in: .whitespaces), !id.isEmpty, MuseReminders.appID(id) == nil {
            return true
        }
        if let name = params["list"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
            MuseReminders.match(name, in: [MuseReminders.appList(isDefault: true)]) == .notFound
        {
            return true
        }
        return false
    }

    /// The lists Muse sees: Pebble Audio's own first when shown (the default one when Apple
    /// Reminders has none to offer), then the person's Apple lists.
    private func allLists(appList: Bool) -> [MuseEventKitSource.ReminderList] {
        let apple = eventKit.reminderLists()
        guard appList else { return apple }
        return [MuseReminders.appList(isDefault: !apple.contains(where: \.isDefault))] + apple
    }

    private func fetchReminders(listIDs: [String]?, since: Date?, appList: Bool) async -> [MuseEventKitSource.Reminder] {
        var found: [MuseEventKitSource.Reminder] = []
        let appleIDs = listIDs?.filter { $0 != MuseReminders.appListID }
        if eventKit.remindersAuthorized, appleIDs?.isEmpty != true {
            found += await eventKit.reminders(inLists: appleIDs, completedSince: since)
        }
        if appList, let data, listIDs?.contains(MuseReminders.appListID) ?? true {
            found += await data.appReminders(completedSince: since).map(MuseReminders.reminder)
        }
        return found
    }

    private func findReminder(_ id: String) async -> MuseEventKitSource.Reminder? {
        if let appID = MuseReminders.appID(id) {
            return await data?.appReminder(id: appID).map(MuseReminders.reminder)
        }
        return eventKit.reminder(id: id)
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
    private func resolve(_ request: MuseReminders.Request, namesAllowed: Bool, appList: Bool) async -> Resolution {
        let lists = allLists(appList: appList)
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
            guard let id = request.id, let found = await findReminder(id) else { return .failed(MuseReminders.noSuchReminder) }
            if lists.first(where: { $0.id == found.listID })?.canChange == false {
                return .failed(MuseReminders.listCannotChange(found.list))
            }
            existing = found
        }
        // The Pebble Audio list is the app's own: no notes, and nothing crosses to Apple's.
        let inApp = (existing?.listID ?? list?.id) == MuseReminders.appListID
        if inApp, request.notes != nil, request.action != .delete { return .failed(MuseReminders.appNoNotes) }
        if let existing, let list, (existing.listID == MuseReminders.appListID) != (list.id == MuseReminders.appListID) {
            return .failed(MuseReminders.noMoveAcrossHomes)
        }
        return .ready(ReadyChange(request: request, existing: existing, list: list))
    }

    /// Makes the change and says what is now true.
    private func apply(_ ready: ReadyChange) async -> MuseJSON {
        let request = ready.request
        let inApp = (ready.existing?.listID ?? ready.list?.id) == MuseReminders.appListID
        if inApp { return await applyInApp(ready) }
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
                let after = try eventKit.updateReminder(id: before.id, Self.change(request, listID: ready.list?.id))
                log("reminders: edited one")
                return ["ok": true, "payload": .object(Self.edited(before, after, request))]
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

    /// A change to the Pebble Audio list, made in the app. A delete files the reminder away:
    /// the person can find it there and bring it back.
    private func applyInApp(_ ready: ReadyChange) async -> MuseJSON {
        guard let data else { return MuseReminders.noSuchReminder }
        let request = ready.request
        switch request.action {
        case .add:
            var due: Date?
            if case .set(let date, _)? = request.due { due = date }
            guard let added = await data.addAppReminder(title: request.title ?? "", due: due) else {
                return Self.error("The reminder couldn't be added. Nothing was changed.")
            }
            log("reminders: added to Pebble Audio")
            return ["ok": true, "payload": ["added": MuseReminders.json(MuseReminders.reminder(added))]]
        case .edit:
            guard let before = ready.existing, let id = MuseReminders.appID(before.id) else { return MuseReminders.noSuchReminder }
            guard let after = await data.updateAppReminder(id: id, Self.change(request, listID: nil)) else {
                return Self.error("The reminder couldn't be changed.")
            }
            log("reminders: edited one in Pebble Audio")
            return ["ok": true, "payload": .object(Self.edited(before, MuseReminders.reminder(after), request))]
        case .delete:
            guard let before = ready.existing, let id = MuseReminders.appID(before.id) else { return MuseReminders.noSuchReminder }
            guard let filed = await data.fileAwayAppReminder(id: id) else {
                return Self.error("The reminder couldn't be deleted.")
            }
            log("reminders: filed one away in Pebble Audio")
            return [
                "ok": true,
                "payload": [
                    "deleted": MuseReminders.json(MuseReminders.reminder(filed)),
                    "filed_away": true,
                    "note": "It is off the person's reminders, filed away in Pebble Audio rather than erased: they can find it there and bring it back.",
                ],
            ]
        case .lists, .read:
            return Self.error("action must be lists, read, add, edit or delete")
        }
    }

    private static func change(_ request: MuseReminders.Request, listID: String?) -> MuseEventKitSource.ReminderChange {
        var change = MuseEventKitSource.ReminderChange(
            title: request.title, notes: request.notes, listID: listID, completed: request.completed)
        switch request.due {
        case .set(let date, let hasTime)?: change.due = .set(date, hasTime: hasTime)
        case .clear?: change.due = .clear
        case nil: break
        }
        return change
    }

    private static func edited(
        _ before: MuseEventKitSource.Reminder, _ after: MuseEventKitSource.Reminder, _ request: MuseReminders.Request
    ) -> [String: MuseJSON] {
        var payload: [String: MuseJSON] = [
            "updated": MuseReminders.json(after),
            "changed": .array(MuseReminders.changedFields(from: before, to: after).map { .string($0) }),
        ]
        if after.listID != before.listID { payload["moved_from"] = .string(before.list) }
        if request.completed == true, !after.completed {
            // A repeating reminder marked done comes back as its next time.
            payload["note"] = "It repeats: this time is done, and it is now due again at the date shown."
        }
        return payload
    }

    private func reminderLists(appList: Bool) -> MuseJSON {
        let lists = allLists(appList: appList)
        guard !lists.isEmpty else { return Self.error("There are no reminders lists on the phone.") }
        var payload: [String: MuseJSON] = ["lists": .array(lists.map { MuseReminders.json($0) })]
        if let fallback = lists.first(where: \.isDefault) { payload["default_list"] = .string(fallback.name) }
        if appList, !eventKit.remindersAuthorized { payload["note"] = .string(MuseReminders.noAppleAccess) }
        return ["ok": true, "payload": .object(payload)]
    }

    /// The most reminders one read sends.
    static let remindersPerRead = 60

    private func readReminders(_ params: MuseJSON, appList: Bool) async -> MuseJSON {
        var listIDs: [String]?
        var listName: String?
        if let name = params["list"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let lists = allLists(appList: appList)
            switch MuseReminders.match(name, in: lists) {
            case .found(let list):
                listIDs = [list.id]
                listName = list.name
            case .ambiguous(let candidates): return MuseReminders.ambiguousList(name, candidates, namesAllowed: true)
            case .notFound: return MuseReminders.noSuchList(name, lists, namesAllowed: true)
            }
        }
        let since = MuseReminders.bool(params["include_completed"]) == true ? clock().addingTimeInterval(-30 * 24 * 60 * 60) : nil
        let found = MuseReminders.ordered(await fetchReminders(listIDs: listIDs, since: since, appList: appList))
        let shown = found.prefix(Self.remindersPerRead)
        var payload: [String: MuseJSON] = ["reminders": .array(shown.map { MuseReminders.json($0) })]
        if let listName { payload["list"] = .string(listName) }
        if found.count > shown.count { payload["not_shown"] = .number(Double(found.count - shown.count)) }
        if appList, !eventKit.remindersAuthorized { payload["note"] = .string(MuseReminders.noAppleAccess) }
        return ["ok": true, "payload": .object(payload)]
    }

    private func conversations(_ params: MuseJSON, data: any MuseDataProvider) async -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "search"?, nil:
            for key in ["from", "to"] where params[key] != nil {
                guard Self.date(params[key]?.string) != nil else { return Self.error("Invalid \(key) date.") }
            }
            let now = clock()
            let from = Self.date(params["from"]?.string)?.date ?? now.addingTimeInterval(-24 * 60 * 60)
            let to = Self.date(params["to"]?.string).map { $0.hasTime ? $0.date : Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date } ?? now
            guard to > from else { return Self.error("to must be after from") }
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
            guard params["date"] == nil || Self.date(params["date"]?.string) != nil else { return Self.error("Invalid recap date.") }
            guard params["period"] == nil || ["day", "week"].contains(params["period"]?.string?.lowercased() ?? "") else {
                return Self.error("period must be day or week")
            }
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

    /// Follow-ups: what the app noticed in the person's conversations, waiting for them to review
    /// (`docs/reminders.md`). Muse can read them, and turn one into a reminder or skip it. It
    /// can't add one: something the person wants to remember is a reminder.
    enum FollowUpAction: Equatable {
        case read, remind, skip, add

        init?(_ name: String?) {
            switch name?.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_") {
            case nil, "read"?, "list"?, "get"?: self = .read
            case "remind"?, "remind_me"?, "accept"?, "keep"?: self = .remind
            case "skip"?, "dismiss"?: self = .skip
            case "add"?, "create"?, "new"?: self = .add
            default: return nil
            }
        }
    }

    static let followUpAddRefused = error(
        "Follow-ups are what Pebble Audio noticed for the person to review, so none can be added. To add something the person wants to remember, use the reminders tool with action add. Nothing was added.")

    private func followUps(
        _ params: MuseJSON, data: any MuseDataProvider, prefs: MusePreferences, watch: any MuseWatchSide,
        deadline: ContinuousClock.Instant
    ) async -> MuseJSON {
        guard let action = FollowUpAction(params["action"]?.string) else {
            return Self.error("action must be read, remind or skip")
        }
        switch action {
        case .add:
            return Self.followUpAddRefused
        case .read:
            if let refusal = await permission(.followUps, prefs: prefs, watch: watch, deadline: deadline) { return refusal }
            let items = await data.followUpsToReview(limit: 40)
            return ["ok": true, "payload": ["follow_ups": .array(items.map(Self.json))]]
        case .remind, .skip:
            guard let id = params["id"]?.string?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                return Self.error("\(action == .remind ? "remind" : "skip") needs the follow-up's id, from read")
            }
            if let refusal = await permission(.followUps, prefs: prefs, watch: watch, deadline: deadline, change: true) {
                return refusal
            }
            guard let decided = await data.decideFollowUp(id: id, remind: action == .remind) else {
                return Self.error(
                    "There is no follow-up waiting for review with that id; it may have been decided already. Call followups with action read to get current ids. Nothing was changed.")
            }
            log("followups: \(action == .remind ? "one became a reminder" : "one was skipped")")
            if action == .skip {
                return [
                    "ok": true,
                    "payload": [
                        "skipped": ["id": .string(decided.id), "task": .string(decided.title)],
                        "note": "Set aside, not deleted: it stays with its conversation, and the person can still turn it into a reminder.",
                    ],
                ]
            }
            var reminder: [String: MuseJSON] = [
                "task": .string(decided.title),
                "kept_in": .string(decided.keptInApple ? "Apple Reminders" : "Pebble Audio"),
                "list": .string(decided.list),
            ]
            if let reminderID = decided.reminderID { reminder["id"] = .string(reminderID) }
            return ["ok": true, "payload": ["reminder": .object(reminder)]]
        }
    }

    static func json(_ item: MuseFollowUp) -> MuseJSON {
        var entry: [String: MuseJSON] = ["id": .string(item.id), "task": .string(item.text)]
        if let saidAt = item.saidAt { entry["said_at"] = .string(isoFormatter.string(from: saidAt)) }
        if let title = item.conversation, !title.isEmpty { entry["conversation"] = .string(title) }
        if let quote = item.quote, !quote.isEmpty { entry["quote"] = .string(quote) }
        if let why = item.why, !why.isEmpty { entry["why"] = .string(why) }
        if let due = item.due { entry["due"] = .string(dayFormatter.string(from: due)) }
        return .object(entry)
    }

    private func recording(_ params: MuseJSON, data: any MuseDataProvider) async -> MuseJSON {
        switch params["action"]?.string?.lowercased() {
        case "pause"?:
            guard params["minutes"] == nil || Self.int(params["minutes"]).map({ (0...1440).contains($0) }) == true else {
                return Self.error("minutes must be an integer from 0 to 1440")
            }
            let minutes = Self.int(params["minutes"]) ?? 0
            return await data.pauseRecording(minutes: minutes)
                ? ["ok": true, "payload": ["pause_requested": true, "paused_minutes": .number(Double(minutes)),
                    "note": "Pause requested in the app; the watch must be connected to apply it."]]
                : Self.error("Recording isn't on.")
        case "resume"?:
            return await data.resumeRecording()
                ? ["ok": true, "payload": ["resume_requested": true,
                    "note": "Recording is enabled in the app. Actual capture depends on the watch connection and its recording state."]]
                : Self.error("Recording couldn't be resumed.")
        case "mark"?:
            return await data.markMoment(params["label"]?.string) ? ["ok": true, "payload": ["marked": true]] : Self.error("This moment couldn't be marked.")
        default:
            return Self.error("action must be pause, resume or mark")
        }
    }

    // MARK: - Helpers

    static let turnedOff: MuseJSON = ["ok": false, "error": "The user has turned this off."]

    static func unconfirmed(_ what: String, read: String) -> MuseJSON {
        ["ok": false, "outcome_unknown": true,
         "error": .string("The watch did not confirm this \(what). It may have changed; use \(read) to check before retrying. Do not assume failure or create a replacement.")]
    }

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
        if let number = value?.number { return Int(exactly: number) }
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
