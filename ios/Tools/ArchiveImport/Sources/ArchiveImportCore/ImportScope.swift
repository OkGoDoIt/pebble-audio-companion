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

    /// The same scope as the phone holds it, whose rules the import follows.
    public var sharing: ArchiveSharingScope {
        switch self {
        case .all: return .all
        case .since(let ms): return .since(ms: ms)
        case .lastDays(let days): return .lastDays(days)
        }
    }

    /// Nothing dated before this is sent; nil for `all`. The phone's own rule.
    public func cutoffMs(nowMs: Int64) -> Int64? { sharing.cutoffMs(nowMs: nowMs) }

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

/// What each item is dated by, and so whether it is inside a scope: the phone's own rule
/// (`ArchiveScopeGate`, §5), asked of the backup's database, so the import can never send what
/// the phone would hold back or hold back what it would send. It used to restate the rule here
/// and disagreed at the edge (a note whose conversation is gone).
///
/// Days are counted in the backup's zone (`BackupLibrary.zoneID`, the newest conversation's),
/// which is how the gate counts them on the phone (`ArchiveScopeGate.accountZone`).
public struct ScopeDates: Sendable {
    public let database: AppDatabase
    public let zoneID: String

    public init(database: AppDatabase, zoneID: String) {
        self.database = database
        self.zoneID = zoneID
    }

    public static func load(_ database: AppDatabase, zoneID: String) async throws -> ScopeDates {
        ScopeDates(database: database, zoneID: zoneID)
    }

    func gate(_ cutoffMs: Int64?) -> ArchiveScopeGate {
        ArchiveScopeGate(
            cutoffMs: cutoffMs,
            cutoffDay: cutoffMs.map { LogicalDay.dateKey(forMs: $0, timeZoneID: zoneID) })
    }

    /// Whether `(kind, id)` falls inside a scope whose cutoff is `cutoffMs`. Something whose date
    /// cannot be found (a transcript of a conversation that is gone) is left to the builder.
    public func contains(_ kind: ArchiveEntityKind, id: String, cutoffMs: Int64?) async throws -> Bool {
        try await gate(cutoffMs).contains(kind, id: id, in: database)
    }

    /// Whether `(kind, id)` is dated before `boundaryMs`, where the phone's own archive begins:
    /// what the phone no longer holds. A day-keyed item is before it when its day is before the
    /// day the boundary falls in. Something undated (a person) counts as before.
    public func isBefore(_ kind: ArchiveEntityKind, id: String, boundaryMs: Int64) async throws -> Bool {
        let date = try await ArchiveScopeGate.date(of: kind, id: id, in: database)
        return date == .undated || !gate(boundaryMs).holds(date)
    }
}
