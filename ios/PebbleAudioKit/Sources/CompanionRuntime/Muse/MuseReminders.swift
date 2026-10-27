import Foundation
import MuseLink

/// Muse's reminders tool, the parts that decide without the phone: which list a name means, what
/// a call asks for, and what goes back to Muse.
///
/// A named list that isn't found is an error that says which lists there are. It never falls
/// back to the default list: on 2026-10-22 "add Small spatula to my Grocery list" landed in the
/// default list because "Groceries" doesn't contain "Grocery", and Muse was told it was added.
enum MuseReminders {
    typealias ReminderList = MuseEventKitSource.ReminderList
    typealias Reminder = MuseEventKitSource.Reminder

    enum Action: Equatable {
        case lists, read, add, edit, delete

        /// The action Muse named, with the other words it uses for each. No action reads.
        init?(_ name: String?) {
            switch name?.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_") {
            case nil, "read"?, "list"?, "get"?, "search"?: self = .read
            case "lists"?, "list_lists"?, "show_lists"?: self = .lists
            case "add"?, "create"?, "new"?: self = .add
            case "edit"?, "update"?, "change"?, "complete"?, "uncomplete"?, "reopen"?, "move"?: self = .edit
            case "delete"?, "remove"?: self = .delete
            default: return nil
            }
        }

        var changes: Bool { self == .add || self == .edit || self == .delete }
    }

    enum Due: Equatable {
        case set(Date, hasTime: Bool)
        case clear
    }

    /// A call that changes something, as Muse asked for it.
    struct Request: Equatable {
        let action: Action
        /// Edit and delete: the reminder's id.
        var id: String?
        /// Add: what to be reminded of. Edit: the new title.
        var title: String?
        /// Add: the list to add to. Edit: the list to move it to.
        var list: String?
        var listID: String?
        var priority: Int?
        var recurrence: MuseRecurrence.Change?
        var due: Due?
        var notes: String?
        var completed: Bool?
    }

    enum Parsed: Equatable {
        case request(Request)
        case invalid(String)
    }

    static let date = "an ISO 8601 date-time with its offset, like 2026-10-21T15:00:00-05:00, or a date, like 2026-10-21"

    /// What a change call asks for, or what is wrong with it.
    static func request(_ action: Action, _ params: MuseJSON) -> Parsed {
        func text(_ key: String) -> String? {
            guard let value = params[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return value
        }
        for key in ["id", "title", "list", "list_id", "due", "notes"] where params[key] != nil {
            if action == .edit, ["due", "notes"].contains(key), params[key] == .null { continue }
            guard params[key]?.string != nil else { return .invalid("\(key) must be text") }
        }
        var request = Request(action: action)
        request.id = text("id").flatMap { $0.isEmpty ? nil : $0 }
        request.list = text("list").flatMap { $0.isEmpty ? nil : $0 }
        if params["list_id"] != nil {
            guard let id = text("list_id"), !id.isEmpty, params["list"] == nil else { return .invalid("Use list_id or list name, not both") }
            request.listID = id
        }
        if params["priority"] != nil {
            guard action == .add || action == .edit, let priority = MuseTools.int(params["priority"]), (0...9).contains(priority) else { return .invalid("priority must be an integer 0-9 with add or edit") }
            request.priority = priority
        }
        if let raw = params["recurrence"] {
            guard action == .add || action == .edit, let rule = try? MuseRecurrence.parse(raw) else { return .invalid("Invalid recurrence; use frequency, interval, weekdays, month_days, months, count, or until. null removes it.") }
            request.recurrence = rule
        }
        switch action {
        case .add:
            guard let title = text("title"), !title.isEmpty else { return .invalid("add needs a title") }
            request.title = title
            if let raw = text("due"), !raw.isEmpty {
                guard let due = MuseTools.date(raw) else { return .invalid("due must be \(date)") }
                request.due = .set(due.date, hasTime: due.hasTime)
            }
            request.notes = text("notes").flatMap { $0.isEmpty ? nil : $0 }
        case .edit:
            guard request.id != nil else { return .invalid("edit needs the reminder's id, from read or from add") }
            if let title = text("title") {
                guard !title.isEmpty else { return .invalid("title can't be empty") }
                request.title = title
            }
            if params["due"] == .null { request.due = .clear }
            if params["notes"] == .null { request.notes = "" }
            if let raw = text("due") {
                if raw.isEmpty || ["none", "null", "clear", "remove"].contains(raw.lowercased()) {
                    request.due = .clear
                } else if let due = MuseTools.date(raw) {
                    request.due = .set(due.date, hasTime: due.hasTime)
                } else {
                    return .invalid("due must be \(date), or none to remove it")
                }
            }
            if let notes = text("notes") {
                request.notes = ["none", "null"].contains(notes.lowercased()) ? "" : notes
            }
            if params["completed"] != nil {
                guard let completed = bool(params["completed"]) else { return .invalid("completed must be true or false") }
                request.completed = completed
            } else {
                switch params["action"]?.string?.lowercased() {
                case "complete"?: request.completed = true
                case "uncomplete"?, "reopen"?: request.completed = false
                default: break
                }
            }
            guard request.title != nil || request.due != nil || request.notes != nil || request.list != nil
                || request.completed != nil || request.listID != nil || request.priority != nil || request.recurrence != nil
            else { return .invalid("edit needs something to change: title, due, notes, list or completed") }
        case .delete:
            guard request.id != nil else { return .invalid("delete needs the reminder's id, from read or from add") }
        case .lists, .read:
            break
        }
        return .request(request)
    }

    static func bool(_ value: MuseJSON?) -> Bool? {
        if let flag = value?.bool { return flag }
        if let number = value?.number { return number == 0 ? false : number == 1 ? true : nil }
        switch value?.string?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "true"?, "yes"?, "1"?, "done"?: return true
        case "false"?, "no"?, "0"?: return false
        default: return nil
        }
    }

    // MARK: - Which list

    enum ListMatch: Equatable {
        case found(ReminderList)
        /// More than one list fits as well as the others.
        case ambiguous([ReminderList])
        case notFound
    }

    /// The list `name` means: the same name in any case first; then the same words give or take
    /// "list", "my", spacing, punctuation, and plurals ("Grocery list" is "Groceries", "todo" is
    /// "To-Do"); then a name inside the other, only when one list fits.
    static func match(_ name: String, in lists: [ReminderList]) -> ListMatch {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !lists.isEmpty else { return .notFound }
        let exact = lists.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if exact.count > 1 { return .ambiguous(exact) }
        if let pick = exact.first { return .found(pick) }
        let wantedKey = key(wanted)
        guard !wantedKey.isEmpty else { return .notFound }
        let same = lists.filter { key($0.name) == wantedKey }
        if same.count > 1 { return .ambiguous(same) }
        if let pick = same.first { return .found(pick) }
        let partial = lists.filter { list in
            let listKey = key(list.name)
            guard listKey.count >= 3, wantedKey.count >= 3 else { return false }
            return listKey.contains(wantedKey) || wantedKey.contains(listKey)
        }
        switch partial.count {
        case 0: return .notFound
        case 1: return .found(partial[0])
        default: return .ambiguous(partial)
        }
    }

    // MARK: - The Pebble Audio list

    /// The reminders kept in Pebble Audio, shown to Muse as one more list while the app keeps them
    /// itself (`docs/reminders.md`). Its reminders' ids are the follow-up's id after `appIDPrefix`.
    static let appListID = "pa:list"
    static let appIDPrefix = "pa:"
    static let appListName = RemindersHome.newListTitle

    static func appList(isDefault: Bool) -> ReminderList {
        ReminderList(id: appListID, name: appListName, isDefault: isDefault)
    }

    /// The follow-up id in a reminder id from the Pebble Audio list, or nil for an Apple one.
    static func appID(_ id: String) -> String? {
        guard id.hasPrefix(appIDPrefix), id != appListID else { return nil }
        let rest = String(id.dropFirst(appIDPrefix.count))
        return rest.isEmpty ? nil : rest
    }

    static func reminder(_ item: MuseAppReminder) -> Reminder {
        Reminder(
            id: appIDPrefix + item.id, title: item.title, due: item.due, dueHasTime: false, list: appListName,
            listID: appListID, completed: item.done)
    }

    static let appNoNotes = MuseTools.error(
        "Reminders in the Pebble Audio list have no notes. Leave notes out. Nothing was changed.")

    static let noMoveAcrossHomes = MuseTools.error(
        "Moving a reminder between the Pebble Audio list and an Apple Reminders list isn't supported. Nothing was changed.")

    static let noAppleAccess = "Pebble Audio has no access to Apple Reminders, so only its own Pebble Audio list is here."

    /// A list's name as compared: lowercase words without punctuation, "my"/"the" and a final
    /// "list" dropped, each word singular, run together.
    static func key(_ name: String) -> String {
        var words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count > 1, ["my", "the", "our"].contains(words[0]) { words.removeFirst() }
        if words.count > 1, ["list", "lists"].contains(words[words.count - 1]) { words.removeLast() }
        return words.map(singular).joined()
    }

    static func singular(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, ["ches", "shes", "sses", "xes"].contains(where: { word.hasSuffix($0) }) {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    // MARK: - What Muse is told when a list or reminder isn't there

    /// A named list that isn't there. The lists' names are said only when Muse may read the
    /// person's reminders now; otherwise Muse is told how to ask for them, which asks first.
    static func noSuchList(_ name: String, _ lists: [ReminderList], namesAllowed: Bool) -> MuseJSON {
        guard namesAllowed, !lists.isEmpty else {
            return MuseTools.error(
                "There is no reminders list called \"\(name)\". Call reminders with action lists to see the person's lists, then use one of those names.")
        }
        return [
            "ok": false,
            "error": .string(
                "There is no reminders list called \"\(name)\". The lists are \(quotedList(lists.map(\.name))). "
                    + "Use one of these names, or ask the person which list they mean. Nothing was changed."),
            "lists": .array(lists.map { .string($0.name) }),
        ]
    }

    static func ambiguousList(_ name: String, _ candidates: [ReminderList], namesAllowed: Bool) -> MuseJSON {
        guard namesAllowed else {
            return MuseTools.error(
                "More than one reminders list matches \"\(name)\". Call reminders with action lists to see the exact names.")
        }
        return [
            "ok": false,
            "error": .string(
                "More than one reminders list matches \"\(name)\": \(quotedList(candidates.map(\.name))). "
                    + "Use the list id from lists, or ask the person which account they mean. Nothing was changed."),
            "lists": .array(candidates.map { .string($0.name) }),
        ]
    }

    static let noSuchReminder = MuseTools.error(
        "There is no reminder with that id; it may have been deleted. Call reminders with action read to get current ids. Nothing was changed.")

    static func listCannotChange(_ name: String) -> MuseJSON {
        MuseTools.error("The list \"\(name)\" is shared read only, so it can't be changed. Nothing was changed.")
    }

    /// "A", "A" and "B", "A", "B", and "C".
    static func quotedList(_ names: [String]) -> String {
        let quoted = names.map { "\"\($0)\"" }
        switch quoted.count {
        case 0: return ""
        case 1: return quoted[0]
        case 2: return "\(quoted[0]) and \(quoted[1])"
        default: return quoted.dropLast().joined(separator: ", ") + ", and " + quoted[quoted.count - 1]
        }
    }

    // MARK: - What goes back

    static func json(_ reminder: Reminder) -> MuseJSON {
        var entry: [String: MuseJSON] = [
            "id": .string(reminder.id),
            "title": .string(reminder.title),
            "list": .string(reminder.list),
            "completed": .bool(reminder.completed), "list_id": .string(reminder.listID),
            "priority": .number(Double(reminder.priority)), "recurrence": .array(reminder.recurrence.map(\.json)),
        ]
        if let due = reminder.due {
            entry["due"] = .string(reminder.dueHasTime ? MuseTools.isoFormatter.string(from: due) : MuseTools.dayFormatter.string(from: due))
        }
        if let notes = reminder.notes, !notes.isEmpty { entry["notes"] = .string(notes) }
        return .object(entry)
    }

    static func json(_ list: ReminderList) -> MuseJSON {
        var entry: [String: MuseJSON] = ["name": .string(list.name), "id": .string(list.id), "account": .string(list.account)]
        if list.isDefault { entry["default"] = true }
        if !list.canChange { entry["read_only"] = true }
        return .object(entry)
    }

    /// What an edit changed, compared field by field, so Muse says only what really happened.
    static func changedFields(from before: Reminder, to after: Reminder) -> [String] {
        var fields: [String] = []
        if before.title != after.title { fields.append("title") }
        if before.due != after.due || before.dueHasTime != after.dueHasTime { fields.append("due") }
        if (before.notes ?? "") != (after.notes ?? "") { fields.append("notes") }
        if before.listID != after.listID { fields.append("list") }
        if before.completed != after.completed { fields.append("completed") }
        if before.priority != after.priority { fields.append("priority") }
        if before.recurrence != after.recurrence { fields.append("recurrence") }
        return fields
    }

    /// Not done first, soonest due first (none last); then done.
    static func ordered(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            switch (a.due, b.due) {
            case (let x?, let y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let comparison = a.title.localizedStandardCompare(b.title)
                return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
            }
        }
    }
}
