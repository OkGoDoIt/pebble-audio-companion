import AppDB
import CompanionRuntime
import Foundation
import GRDB

/// Which conversations the server may hold (`sync-protocol.md` §5, the sharing scope): all of
/// them, those from a moment on, or a rolling window of days.
public enum ImportScope: Equatable, Sendable {
    case all
    case since(ms: Int64)
    case lastDays(Int)

    /// `all`, `since:<YYYY-MM-DD or RFC 3339 time>`, or `last:<days>`. A bare date is the start
    /// of that day as the app counts days (`LogicalDay`, from 5 AM) in `timeZone`.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> ImportScope? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "all" { return .all }
        if value.hasPrefix("last:") {
            guard let days = Int(value.dropFirst("last:".count)), days > 0 else { return nil }
            return .lastDays(days)
        }
        if value.hasPrefix("since:") {
            let date = String(value.dropFirst("since:".count))
            if let ms = ArchiveTime.ms(date), date.contains("T") { return .since(ms: ms) }
            guard JSONType.isDay(date),
                let bounds = LogicalDay.bounds(ofDateKey: date, timeZoneID: timeZone.identifier)
            else { return nil }
            return .since(ms: bounds.startMs)
        }
        return nil
    }

    /// The `scope` object `GET /sync/preferences` carries, when the server has one.
    public static func fromServer(_ value: ArchiveJSONValue?) -> ImportScope? {
        guard let value, let kind = value["kind"]?.string else { return nil }
        switch kind {
        case "all": return .all
        case "since":
            return ArchiveTime.ms(value["since"]?.string).map { .since(ms: $0) }
        case "lastDays":
            guard let days = value["days"]?.int64, days > 0 else { return nil }
            return .lastDays(Int(days))
        default: return nil
        }
    }

    /// Nothing dated before this is sent; nil for `all`.
    public func cutoffMs(nowMs: Int64) -> Int64? {
        switch self {
        case .all: return nil
        case .since(let ms): return ms
        case .lastDays(let days): return nowMs - Int64(days) * 86_400_000
        }
    }

    public var summary: String {
        switch self {
        case .all: return "everything"
        case .since(let ms): return "from \(Output.localTime(ms)) on"
        case .lastDays(let days): return days == 1 ? "the last day" : "the last \(days) days"
        }
    }
}

/// `--before`: send only what is dated before a moment, because the phone holds what comes after
/// (by default the start of the phone's own archive on the server), or `all` to send everything.
public enum ImportBoundary: Equatable, Sendable {
    case before(ms: Int64)
    case everything

    /// `all`, a `YYYY-MM-DD` (the start of that app day in `timeZone`), or an RFC 3339 time.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> ImportBoundary? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "all" { return .everything }
        guard case .since(let ms)? = ImportScope.parse("since:\(value)", timeZone: timeZone) else { return nil }
        return .before(ms: ms)
    }
}

/// What each item is dated by, as §5 defines it: a conversation (and its transcript) by when it
/// started, a note by its conversation, a follow-up by when it was said (else when it was
/// written), a recap and a day's coverage by their day, a brief by its last day. People are not
/// dated and always go.
///
/// A day-keyed item is in scope when its day is the one the cutoff falls in or later (the logical
/// day, 5 AM to 5 AM, in the backup's zone): a recap of the day the window opens on describes
/// conversations inside it.
public struct ScopeDates: Sendable {
    public var conversationStartMs: [String: Int64]
    public var noteConversation: [String: String]
    /// When each note was written, for one without a conversation.
    public var noteCreatedMs: [String: Int64]
    public var followUpMs: [String: Int64]
    public var zoneID: String

    public init(
        conversationStartMs: [String: Int64], noteConversation: [String: String],
        noteCreatedMs: [String: Int64] = [:], followUpMs: [String: Int64], zoneID: String
    ) {
        self.conversationStartMs = conversationStartMs
        self.noteConversation = noteConversation
        self.noteCreatedMs = noteCreatedMs
        self.followUpMs = followUpMs
        self.zoneID = zoneID
    }

    public static func load(_ database: AppDatabase, zoneID: String) async throws -> ScopeDates {
        try await database.reader.read { d in
            var starts: [String: Int64] = [:]
            for row in try Row.fetchAll(d, sql: "SELECT id, startMs FROM conversations") {
                starts[row["id"]] = row["startMs"]
            }
            var notes: [String: String] = [:]
            var notesCreated: [String: Int64] = [:]
            for row in try Row.fetchAll(d, sql: "SELECT id, conversationId, createdAtMs FROM notes") {
                notes[row["id"]] = row["conversationId"]
                notesCreated[row["id"]] = row["createdAtMs"]
            }
            var followUps: [String: Int64] = [:]
            for row in try Row.fetchAll(
                d, sql: "SELECT id, COALESCE(sourceWallStartMs, createdAtMs) AS at FROM follow_ups")
            {
                followUps[row["id"]] = row["at"]
            }
            return ScopeDates(
                conversationStartMs: starts, noteConversation: notes, noteCreatedMs: notesCreated,
                followUpMs: followUps, zoneID: zoneID)
        }
    }

    /// Whether `(kind, id)` falls inside a scope whose cutoff is `cutoffMs`. Something whose date
    /// cannot be found here (a transcript of a conversation that is gone) is left to the builder.
    public func contains(_ kind: ArchiveEntityKind, id: String, cutoffMs: Int64?) -> Bool {
        guard let cutoffMs else { return true }
        switch dating(kind, id: id) {
        case .instant(let ms): return ms >= cutoffMs
        case .day(let day): return day >= LogicalDay.dateKey(forMs: cutoffMs, timeZoneID: zoneID)
        case .undated: return true
        }
    }

    /// Whether `(kind, id)` is dated before `boundaryMs`, where the phone's own archive begins: what
    /// the phone no longer holds. A day-keyed item is before it when its day is before the day the
    /// boundary falls in. Something undated here (a person) counts as before.
    public func isBefore(_ kind: ArchiveEntityKind, id: String, boundaryMs: Int64) -> Bool {
        switch dating(kind, id: id) {
        case .instant(let ms): return ms < boundaryMs
        case .day(let day): return day < LogicalDay.dateKey(forMs: boundaryMs, timeZoneID: zoneID)
        case .undated: return true
        }
    }

    enum Dating: Equatable {
        case instant(Int64)
        case day(String)
        /// A person, or something whose date cannot be found here (left to the builder).
        case undated
    }

    func dating(_ kind: ArchiveEntityKind, id: String) -> Dating {
        func at(_ ms: Int64?) -> Dating { ms.map { .instant($0) } ?? .undated }
        switch kind {
        case .conversation, .transcript:
            return at(conversationStartMs[id])
        case .note:
            if let conversation = noteConversation[id] { return at(conversationStartMs[conversation]) }
            return at(noteCreatedMs[id])
        case .followUp:
            return at(followUpMs[id])
        case .recap, .coverage:
            return .day(id)
        case .brief:
            return Self.lastDay(ofPeriod: id).map { .day($0) } ?? .undated
        case .person:
            return .undated
        }
    }

    /// `week:2026-10-11` ends six days after it starts; `month:2026-10` on its last day.
    static func lastDay(ofPeriod key: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func string(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        if key.hasPrefix("week:") {
            let parts = key.dropFirst("week:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                let start = calendar.date(
                    from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                let end = calendar.date(byAdding: .day, value: 6, to: start)
            else { return nil }
            return string(end)
        }
        if key.hasPrefix("month:") {
            let parts = key.dropFirst("month:".count).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2,
                let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
                let next = calendar.date(byAdding: .month, value: 1, to: start),
                let end = calendar.date(byAdding: .day, value: -1, to: next)
            else { return nil }
            return string(end)
        }
        return nil
    }
}
