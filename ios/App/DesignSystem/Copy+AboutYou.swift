import Foundation
import Intelligence
import StatusUI

// About You's rebuilt strings (AY): the inline editor, the two per-source screens, and the
// freshness/health line.
//
// Written under two constraints that pull the same way:
//
// - **Say it once, in a few words.** The screen already carries one explainer at the top; a
//   second sentence on every row is what made Settings feel like documentation. Where a state
//   can be said in one word ("Off"), it is.
// - **Never state a promise the pipeline is not keeping.** The line about where imported names
//   go is DERIVED from `AppSettings.cloudDestinations`, the same input
//   `Copy.Settings.AboutYou.explainer` and `Copy.Privacy` read — so turning cloud AI off
//   changes this sentence too, and it cannot drift into a comforting lie.

extension Copy.Settings.AboutYou {

    // ─── The editor ──────────────────────────────────────────────────────────

    /// Placeholder for an empty bio. It has to teach the whole feature in one line, because
    /// there is nothing else on an empty screen to explain what to type.
    static let bioPlaceholder = "Names you say often, projects, places, jargon…"

    /// Spoken label for the editor — sighted users have the placeholder, VoiceOver does not.
    static let bioAccessibilityLabel = "About you"

    // ─── The source rows ─────────────────────────────────────────────────────

    static let sourcesSection = "Sources"

    /// A source the user has not turned on. Deliberately the same word the rest of Settings
    /// uses for a switch that is off.
    static let sourceOff = "Off"
    /// e.g. "142 names".
    static func namesImported(_ count: Int) -> String { "\(count) names" }
    /// e.g. "38 events".
    static func eventsImported(_ count: Int) -> String { "\(count) events" }
    /// On, with an empty selection: honest, because "0 names" reads like a failure.
    static let nothingSelected = "Nothing selected"
    /// On, but iOS is no longer letting us read it.
    static let noAccess = "No access"
    /// On, but the last attempt failed for some other reason.
    static let notUpdating = "Not updating"

    // ─── Freshness, in one line ──────────────────────────────────────────────
    //
    // The user asked to be able to trust that imports keep themselves current. That is worth
    // exactly one line: when it last worked, or what is wrong. Normal operation is not narrated
    // beyond that, and when nothing is turned on there is no line at all.

    /// e.g. "Updated 5 min ago." `ago` comes from `Formatting.duration`, as everywhere else.
    static func updatedAgo(_ ago: String) -> String { "Updated \(ago) ago." }
    static let updatedJustNow = "Updated just now."
    static let neverUpdated = "Nothing imported yet."
    /// e.g. "Contacts can't update — allow access in iOS Settings."
    static func cannotAccess(_ source: String) -> String {
        "\(source) can't update — allow access in iOS Settings."
    }
    /// e.g. "Calendar didn't update last time."
    static func updateFailed(_ source: String) -> String {
        "\(source) didn't update last time."
    }

    // ─── The per-source screens ──────────────────────────────────────────────

    /// The switch that is also the permission prompt — the ONLY place either framework is
    /// asked for access.
    static func importFrom(_ source: String) -> String { "Import from \(source)" }

    static let allContacts = "All Contacts"
    static let allCalendars = "All Calendars"
    static let accountsSection = "Accounts"
    static let groupsSection = "Groups"
    static let calendarsSection = "Calendars"
    static let rangeSection = "Events"
    static let pastRow = "Past"
    static let aheadRow = "Ahead"

    /// e.g. "30 days", and the two ends of the range.
    static func days(_ count: Int) -> String {
        switch count {
        case 0: return "None"
        case 1: return "1 day"
        case 7: return "1 week"
        case 365: return "1 year"
        default: return "\(count) days"
        }
    }

    static let updateNow = "Update Now"
    static let openIosSettings = "Open iOS Settings"
    /// e.g. "Remove Imported Contacts…" — per source, so one can go without the other.
    static func removeImported(_ source: String) -> String { "Remove Imported \(source)…" }
    static func removeImportedConfirm(_ source: String) -> String { "Remove \(source) Data" }

    /// What each source actually contributes. One clause, no second sentence.
    static func sourcePurpose(_ kind: ContextImportKind) -> String {
        switch kind {
        case .contacts: return "Names, so transcripts spell the people you talk about right."
        case .calendar: return "Event titles, for the names and jargon around them."
        }
    }

    /// Where the imported text goes, derived from the same modes as the privacy stance. Nil
    /// when nothing leaves the phone, in which case the screen says nothing rather than
    /// reassuring at length.
    static func sourceDestination(_ kind: ContextImportKind, destinations: String?) -> String? {
        guard let destinations else { return nil }
        switch kind {
        case .contacts: return "These names go to \(destinations) with your transcripts."
        case .calendar: return "These titles go to \(destinations) with your transcripts."
        }
    }

    /// iOS 18+ limited Contacts access: we see only the contacts the user picked in the system
    /// sheet, and groups are not meaningful under it. Saying so is better than showing a picker
    /// that cannot do anything.
    static let contactsLimited = "iOS is sharing only the contacts you picked."
    /// A source that is on and has nothing to pick from (no groups, no calendars).
    static let nothingToPick = "Nothing to choose from."
    /// The empty selection, said where the choice is made.
    static let nothingSelectedNote = "Nothing selected, so nothing is imported."

    static func sourceName(_ kind: ContextImportKind) -> String {
        switch kind {
        case .contacts: return Copy.Settings.AboutYou.contacts
        case .calendar: return Copy.Settings.AboutYou.calendar
        }
    }
}

// ─── Deriving the one status line ────────────────────────────────────────────

extension Copy.Settings.AboutYou {
    /// The row's trailing value: on/off first, then anything wrong, then the count. Pure, so
    /// the wording is a function of the state rather than of where it is called from.
    static func rowValue(_ state: ImportSourceState) -> String? {
        guard state.isEnabled else { return sourceOff }
        switch state.access {
        case .denied: return noAccess
        case .notDetermined, .granted, .limited: break
        }
        if state.lastFailure != nil { return notUpdating }
        if state.selection.selectsNothing { return nothingSelected }
        guard state.lastImportedAtMs != nil else { return nil }
        switch state.kind {
        case .contacts: return namesImported(state.importedCount)
        case .calendar: return eventsImported(state.importedCount)
        }
    }

    /// The single freshness/health footnote for the About You screen, or nil when there is
    /// nothing worth saying. A problem always wins over a timestamp, and the oldest enabled
    /// source is the one that speaks — a line that reported the freshest would be flattering
    /// rather than honest.
    static func freshnessLine(_ states: [ImportSourceState], nowMs: Int64) -> String? {
        let enabled = states.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        if let broken = enabled.first(where: { $0.access == .denied }) {
            return cannotAccess(sourceName(broken.kind))
        }
        if let failed = enabled.first(where: { $0.lastFailure != nil }) {
            return updateFailed(sourceName(failed.kind))
        }
        let stamps = enabled.compactMap(\.lastImportedAtMs)
        guard stamps.count == enabled.count, let oldest = stamps.min() else { return neverUpdated }
        return updatedLine(sinceMs: max(0, nowMs - oldest))
    }

    /// "Updated 5 min ago." — under a minute is "just now", because "Updated 12 sec ago" is a
    /// stopwatch, not a status.
    static func updatedLine(sinceMs: Int64) -> String {
        sinceMs < 60_000 ? updatedJustNow : updatedAgo(Formatting.duration(sinceMs))
    }

    /// The same one line, on the source's own screen, where it can name the source it is about
    /// without repeating it.
    static func sourceStatusLine(_ state: ImportSourceState, nowMs: Int64) -> String? {
        guard state.isEnabled else { return nil }
        if state.access == .denied { return cannotAccess(sourceName(state.kind)) }
        if state.lastFailure != nil { return updateFailed(sourceName(state.kind)) }
        if state.selection.selectsNothing { return nothingSelectedNote }
        guard let last = state.lastImportedAtMs else { return neverUpdated }
        return updatedLine(sinceMs: max(0, nowMs - last))
    }
}
