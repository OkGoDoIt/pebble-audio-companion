import Foundation

// Per-source control over what "About You" imports from the phone (AY).
//
// Before this file each import was a single tap with no state behind it: Contacts enumerated
// EVERY contact on the device, Calendar read every event in a hard-coded three-week window,
// neither was ever re-run, and the only way to undo either was the screen's nuclear "Clear
// Imported Context" — which removed both at once along with anything else in the context.
// Worse, the calendar import did `orgs = Set(orgs + titles).sorted()`, so titles accreted
// forever: every event the user had ever imported stayed in the AI grounding block and in the
// transcription bias list even after it was months in the past.
//
// So the two facts that were missing are both here: WHAT the user chose to import from each
// source, and WHAT that source last contributed — the second being what makes removing one
// source's data possible without touching the other's.
//
// Everything in this file is pure: no Contacts, no EventKit, no clock. The framework work
// lives in `LiveAboutYouSource`, which is not testable in a unit target at all (it needs a
// real permission grant), so every decision that can be made without a framework is made
// here instead, where a test can pin it.

/// One of the two phone sources About You can import from.
public enum ContextImportKind: String, Codable, CaseIterable, Sendable {
    case contacts
    case calendar

    /// The provenance kind recorded in `PersonalContext.sources`, which is a separate (KMP)
    /// vocabulary that also has `manual` and `derived`.
    public var sourceKind: ContextSourceKind {
        switch self {
        case .contacts: return .contacts
        case .calendar: return .calendar
        }
    }
}

/// Which groups / calendars inside a source are imported.
///
/// `all` is not the same as an `only` list that happens to hold everything: `all` keeps
/// following the source, so a calendar subscribed to next month is included without the user
/// having to come back, while `only` is their explicit list and never grows behind their back.
///
/// And `only([])` means "nothing" — the empty selection is precisely the case a
/// nil-means-everything encoding gets silently wrong, turning "I unticked all of them" into
/// "import my entire address book". That is why this is an enum and not an optional array.
public enum ContextImportSelection: Equatable, Sendable {
    case all
    case only(Set<String>)
}

extension ContextImportSelection {
    /// True only for the deliberate empty selection — `all` is never empty.
    public var selectsNothing: Bool {
        if case .only(let ids) = self { return ids.isEmpty }
        return false
    }

    public func includes(_ id: String) -> Bool {
        switch self {
        case .all: return true
        case .only(let ids): return ids.contains(id)
        }
    }

    /// The ids to actually fetch, in the order the source offered them.
    ///
    /// Ids that no longer exist (a group deleted in Contacts, an unsubscribed calendar) simply
    /// drop out: fetching them would fail, and carrying them into the count would report an
    /// import bigger than the one that happened.
    public func resolved(against available: [String]) -> [String] {
        switch self {
        case .all: return available
        case .only(let ids): return available.filter(ids.contains)
        }
    }

    /// Drops ids the source no longer has. Called after a successful enumeration, which is the
    /// only moment we know the full list is real rather than an empty list from a denied store.
    public func pruned(against available: [String]) -> ContextImportSelection {
        switch self {
        case .all: return .all
        case .only(let ids): return .only(ids.intersection(available))
        }
    }

    /// The picker's tap. Ticking the last unticked entry collapses back to `all`, so the "All"
    /// row is checked when everything is checked and the selection keeps following the source
    /// instead of freezing today's list.
    public func toggling(_ id: String, available: [String]) -> ContextImportSelection {
        let all = Set(available)
        var ids: Set<String>
        switch self {
        case .all: ids = all
        case .only(let existing): ids = existing.intersection(all)
        }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        return ids == all && !all.isEmpty ? .all : .only(ids)
    }
}

extension ContextImportSelection: Codable {
    // Two explicit fields rather than "null means everything": a JSON null decoded into a
    // non-optional property is exactly the sort of thing that behaves differently between
    // encoders, and this file is the one place where getting it wrong sends an address book
    // somewhere it was not meant to go.
    private enum CodingKeys: String, CodingKey { case includesAll, ids }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .includesAll) ?? true {
            self = .all
        } else {
            self = .only(Set(try c.decodeIfPresent([String].self, forKey: .ids) ?? []))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode(true, forKey: .includesAll)
        case .only(let ids):
            try c.encode(false, forKey: .includesAll)
            try c.encode(ids.sorted(), forKey: .ids)
        }
    }
}

/// Why the last import attempt did not finish. A stable reason, never a framework error
/// string: B20 — provider and system prose is not something this app puts on screen.
public enum ContextImportFailure: String, Codable, Sendable {
    /// Access was refused, or was revoked in iOS Settings after having been granted.
    case permissionDenied
    /// The store was reachable but the read failed.
    case unreadable
    /// The read worked and writing the result to the personal context did not. Distinct
    /// because the data is unchanged rather than stale, and because it is the one failure that
    /// is about this app rather than about the source.
    case notSaved
}

/// One source's settings and the record of its last import.
public struct ContextSourceSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var selection: ContextImportSelection
    /// Calendar only: how far back and forward events are read. Unused for Contacts.
    public var pastDays: Int
    public var futureDays: Int
    /// When the last SUCCESSFUL import finished; nil until one has. This is the only input to
    /// the "Updated …" line, so a failed attempt never makes the data look fresher than it is.
    public var lastImportedAtMs: Int64?
    /// Set when the last attempt failed, cleared when one succeeds.
    public var lastFailure: ContextImportFailure?
    /// How many items the last import contributed — the number the row shows.
    public var importedCount: Int
    /// Exactly what this source last added to `PersonalContext.orgs`, so the next import (or
    /// switching the source off) removes its own contribution and nothing else. The absence of
    /// this record is what let calendar titles pile up forever.
    public var contributedTerms: [String]

    public init(
        isEnabled: Bool = false,
        selection: ContextImportSelection = .all,
        pastDays: Int = 0,
        futureDays: Int = 0,
        lastImportedAtMs: Int64? = nil,
        lastFailure: ContextImportFailure? = nil,
        importedCount: Int = 0,
        contributedTerms: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.selection = selection
        self.pastDays = pastDays
        self.futureDays = futureDays
        self.lastImportedAtMs = lastImportedAtMs
        self.lastFailure = lastFailure
        self.importedCount = importedCount
        self.contributedTerms = contributedTerms
    }

    /// Contacts has no time window.
    public static let contactsDefault = ContextSourceSettings()

    /// The calendar default. It reaches BACKWARDS as well as forwards, which the old
    /// hard-coded "next 3 weeks" did not: what was discussed last month is at least as useful
    /// for getting a name right as what is scheduled next month.
    public static let calendarDefault = ContextSourceSettings(pastDays: 30, futureDays: 21)

    /// Whether an automatic — not user-initiated — refresh is due.
    ///
    /// A disabled source is never refreshed, which is also what keeps a revoked permission from
    /// being re-asked: nothing here can reach a framework, and the caller only ever runs an
    /// automatic refresh for a source that is on and already authorized.
    public func isDueForAutoRefresh(nowMs: Int64, staleAfterMs: Int64) -> Bool {
        guard isEnabled else { return false }
        guard let last = lastImportedAtMs else { return true }
        return nowMs - last >= staleAfterMs
    }

    /// The calendar window in absolute milliseconds around `nowMs`. Negative spans are clamped
    /// to zero rather than inverted, so a bad value reads nothing instead of reading everything.
    public func calendarWindow(nowMs: Int64) -> ContextImportWindow {
        let day: Int64 = 24 * 60 * 60 * 1000
        let past = Int64(max(0, pastDays)) * day
        let future = Int64(max(0, futureDays)) * day
        return ContextImportWindow(startMs: nowMs - past, endMs: nowMs + future)
    }
}

extension ContextSourceSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, selection, pastDays, futureDays, lastImportedAtMs, lastFailure
        case importedCount, contributedTerms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        selection =
            try c.decodeIfPresent(ContextImportSelection.self, forKey: .selection) ?? .all
        pastDays = try c.decodeIfPresent(Int.self, forKey: .pastDays) ?? 0
        futureDays = try c.decodeIfPresent(Int.self, forKey: .futureDays) ?? 0
        lastImportedAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastImportedAtMs)
        lastFailure = try c.decodeIfPresent(ContextImportFailure.self, forKey: .lastFailure)
        importedCount = try c.decodeIfPresent(Int.self, forKey: .importedCount) ?? 0
        contributedTerms = try c.decodeIfPresent([String].self, forKey: .contributedTerms) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(selection, forKey: .selection)
        try c.encode(pastDays, forKey: .pastDays)
        try c.encode(futureDays, forKey: .futureDays)
        try c.encodeIfPresent(lastImportedAtMs, forKey: .lastImportedAtMs)
        try c.encodeIfPresent(lastFailure, forKey: .lastFailure)
        try c.encode(importedCount, forKey: .importedCount)
        if !contributedTerms.isEmpty { try c.encode(contributedTerms, forKey: .contributedTerms) }
    }
}

/// An absolute time range, so the window arithmetic can be tested without EventKit.
public struct ContextImportWindow: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    public var end: Date { Date(timeIntervalSince1970: Double(endMs) / 1000) }
}

/// Both sources' settings — the whole of `ai/context_imports.json`.
public struct ContextImportSettings: Equatable, Sendable {
    public var contacts: ContextSourceSettings
    public var calendar: ContextSourceSettings

    public init(
        contacts: ContextSourceSettings = .contactsDefault,
        calendar: ContextSourceSettings = .calendarDefault
    ) {
        self.contacts = contacts
        self.calendar = calendar
    }

    public subscript(kind: ContextImportKind) -> ContextSourceSettings {
        get {
            switch kind {
            case .contacts: return contacts
            case .calendar: return calendar
            }
        }
        set {
            switch kind {
            case .contacts: contacts = newValue
            case .calendar: calendar = newValue
            }
        }
    }

    /// What to start from on a phone that imported under the old one-shot code.
    ///
    /// Without this, upgrading would show both sources as "Off" while their names and event
    /// titles were still in every prompt — the screen stating the opposite of what the app is
    /// doing, which is the one thing this product does not do. So an existing import is adopted
    /// as an enabled source, keeping the timestamp the old code recorded.
    public static func adopting(_ context: PersonalContext) -> ContextImportSettings {
        var settings = ContextImportSettings()
        if let record = context.sources.first(where: { $0.kind == .contacts }) {
            settings.contacts.isEnabled = true
            settings.contacts.lastImportedAtMs = record.importedAtMs
            settings.contacts.importedCount = context.people.count
        } else if !context.people.isEmpty {
            // People with no provenance record: the old code only wrote `people` from the
            // Contacts import, so this is still an import — just one whose record was lost.
            settings.contacts.isEnabled = true
            settings.contacts.importedCount = context.people.count
        }
        if let record = context.sources.first(where: { $0.kind == .calendar }) {
            settings.calendar.isEnabled = true
            settings.calendar.lastImportedAtMs = record.importedAtMs
            settings.calendar.importedCount = context.orgs.count
            // The old import left no record of which entries were its own, so adopt every
            // `orgs` entry as calendar-contributed: nothing else in the app has ever written
            // that field, and claiming them is what lets the next refresh replace rather than
            // pile on top.
            settings.calendar.contributedTerms = context.orgs
        }
        return settings
    }
}

extension ContextImportSettings: Codable {
    private enum CodingKeys: String, CodingKey { case contacts, calendar }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contacts =
            try c.decodeIfPresent(ContextSourceSettings.self, forKey: .contacts) ?? .contactsDefault
        calendar =
            try c.decodeIfPresent(ContextSourceSettings.self, forKey: .calendar) ?? .calendarDefault
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contacts, forKey: .contacts)
        try c.encode(calendar, forKey: .calendar)
    }
}

// MARK: - Merging an import into the personal context

/// How an import's result is folded into `PersonalContext` — the half that has to be exact,
/// because getting it wrong either loses the other source's data or never lets go of its own.
public enum ContextImportMerge {
    /// The most terms one source may contribute. `PersonalContextFormatting` prints at most 40
    /// organizations and 40 transcription terms, so a heavier cap would only bloat the file and
    /// push the user's own words out of the budget.
    public static let termLimit = 60

    /// Trimmed, de-duplicated (case-insensitively), order preserved, capped.
    public static func cleanTerms(_ raw: [String], limit: Int = termLimit) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in raw {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count == limit { break }
        }
        return out
    }

    /// Swaps one source's previous contribution for its new one inside a shared list.
    ///
    /// Entries that were not this source's survive, and an entry the user (or the other source)
    /// also has is not removed just because this source is letting go of it.
    public static func replacing(
        _ previous: [String], with new: [String], in existing: [String]
    ) -> [String] {
        let dropping = Set(previous.map { $0.lowercased() })
        let keeping = existing.filter { !dropping.contains($0.lowercased()) }
        var seen = Set(keeping.map { $0.lowercased() })
        var out = keeping
        for term in new where seen.insert(term.lowercased()).inserted {
            out.append(term)
        }
        return out
    }

    /// Adds or removes the provenance record the About You screen and the migration importer
    /// both read. Keeps at most one record per source.
    public static func setRecord(
        _ kind: ContextSourceKind, present: Bool, atMs: Int64, in context: inout PersonalContext
    ) {
        context.sources.removeAll { $0.kind == kind }
        guard present else { return }
        context.sources.append(
            ContextSource(
                id: kind.rawValue.lowercased(), kind: kind, label: kind.rawValue,
                importedAtMs: atMs
            ))
    }
}

// MARK: - Store

/// Durable store for `ContextImportSettings` at `<root>/ai/context_imports.json`, written the
/// same way `FilePersonalContextStore` writes its file (temp + atomic rename).
///
/// Deliberately a SEPARATE file from `personal_context.json`: that one is a KMP-compatible
/// document the migration importer and the old app can both read, and adding fields to it would
/// break that contract for settings only this app has ever had.
public final class FileContextImportSettingsStore: @unchecked Sendable {
    public static let fileName = "context_imports.json"

    private let aiDir: URL
    private let path: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.aiDir = root.appendingPathComponent("ai", isDirectory: true)
        self.path = aiDir.appendingPathComponent(Self.fileName)
    }

    /// Nil when nothing has been written yet — the caller needs that distinction to know
    /// whether to adopt an existing pre-per-source import.
    public func load() -> ContextImportSettings? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(ContextImportSettings.self, from: data)
    }

    @discardableResult
    public func save(_ settings: ContextImportSettings) throws -> ContextImportSettings {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        let tmp = aiDir.appendingPathComponent("\(Self.fileName).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: tmp)
        if rename(tmp.path, path.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: path.path])
        }
        return settings
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        for url in [path, aiDir.appendingPathComponent("\(Self.fileName).tmp")]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
