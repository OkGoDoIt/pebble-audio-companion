import Foundation
import MuseLink
import WireProtocol

/// Muse's reminders tool, the parts that decide without the phone: which list a name means, what
/// a call asks for, what the watch asks before a change, and what goes back to Muse.
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
        var request = Request(action: action)
        request.id = text("id").flatMap { $0.isEmpty ? nil : $0 }
        request.list = text("list").flatMap { $0.isEmpty ? nil : $0 }
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
                || request.completed != nil
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
        if let number = value?.number { return number != 0 }
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
        if let pick = pick(exact) { return .found(pick) }
        let wantedKey = key(wanted)
        guard !wantedKey.isEmpty else { return .notFound }
        let same = lists.filter { key($0.name) == wantedKey }
        if let pick = pick(same) { return .found(pick) }
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

    /// Lists with the very same name (in two accounts) can't be told apart by name: the default
    /// one, else one that can be changed, else the first.
    private static func pick(_ lists: [ReminderList]) -> ReminderList? {
        lists.first(where: \.isDefault) ?? lists.first(where: \.canChange) ?? lists.first
    }

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
                    + "Use the exact name, or ask the person which one. Nothing was changed."),
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

    // MARK: - What the watch asks

    /// What a change does, for the question on the watch.
    enum Change: Equatable {
        case add
        case delete
        case complete
        case reopen
        case move(to: String)
        case rename(to: String)
        /// Its due date or notes, or several things at once.
        case change
    }

    /// What `request` does to `existing` (edit and delete), moving it to `target` when it names a
    /// list.
    static func change(_ request: Request, existing: Reminder?, target: ReminderList?) -> Change {
        switch request.action {
        case .add: return .add
        case .delete: return .delete
        default: break
        }
        let moving = target.map { $0.id != existing?.listID } ?? (request.list != nil)
        let asked = [request.title != nil, request.due != nil, request.notes != nil, moving, request.completed != nil]
        guard asked.filter({ $0 }).count == 1 else { return .change }
        if let completed = request.completed { return completed ? .complete : .reopen }
        if moving, let name = target?.name ?? request.list { return .move(to: name) }
        if let title = request.title { return .rename(to: title) }
        return .change
    }

    /// The question the watch asks before a change, under Ask first: the action and the item,
    /// like `Let Muse delete "Small spatula" from Groceries?` (docs/privacy-model.md, section 4).
    /// `title` and `list` are nil when they aren't known yet (iOS hasn't given access).
    static func question(_ change: Change, title: String?, list: String?) -> String {
        let list = list.map { cut($0, 30) }
        func make(_ limit: Int) -> String {
            let item = title.map { "\u{201C}\(cut($0, limit))\u{201D}" }
            switch change {
            case .add:
                return "Let Muse add \(item ?? "a reminder") to \(list ?? "your reminders")?"
            case .delete:
                guard let item else { return "Let Muse delete one of your reminders?" }
                return list.map { "Let Muse delete \(item) from \($0)?" } ?? "Let Muse delete \(item)?"
            case .complete:
                return "Let Muse mark \(item ?? "one of your reminders") as done?"
            case .reopen:
                return "Let Muse mark \(item ?? "one of your reminders") as not done?"
            case .move(let to):
                return "Let Muse move \(item ?? "one of your reminders") to \(cut(to, 30))?"
            case .rename(let to):
                guard let item else { return "Let Muse rename one of your reminders?" }
                return "Let Muse rename \(item) to \u{201C}\(cut(to, limit))\u{201D}?"
            case .change:
                guard let item else { return "Let Muse change one of your reminders?" }
                return list.map { "Let Muse change \(item) in \($0)?" } ?? "Let Muse change \(item)?"
            }
        }
        // The watch shows up to 120 bytes: long titles are shortened to fit.
        var limit = max(title?.count ?? 0, 1)
        var text = make(limit)
        while text.utf8.count > ProtocolConstants.watchActionQuestionMaxBytes, limit > 4 {
            limit -= 1
            text = make(limit)
        }
        return text
    }

    /// `text`, at most `limit` characters, ending in "…" when shortened.
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - What goes back

    static func json(_ reminder: Reminder) -> MuseJSON {
        var entry: [String: MuseJSON] = [
            "id": .string(reminder.id),
            "title": .string(reminder.title),
            "list": .string(reminder.list),
            "completed": .bool(reminder.completed),
        ]
        if let due = reminder.due {
            entry["due"] = .string(reminder.dueHasTime ? MuseTools.isoFormatter.string(from: due) : MuseTools.dayFormatter.string(from: due))
        }
        if let notes = reminder.notes, !notes.isEmpty { entry["notes"] = .string(notes) }
        return .object(entry)
    }

    static func json(_ list: ReminderList) -> MuseJSON {
        var entry: [String: MuseJSON] = ["name": .string(list.name)]
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
        return fields
    }

    /// Not done first, soonest due first (none last); then done.
    static func ordered(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            switch (a.due, b.due) {
            case (let x?, let y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }
}
