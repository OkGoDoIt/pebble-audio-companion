import AppDB
import CompanionRuntime
import CryptoKit
import Foundation
import SystemConfiguration

public struct ImportOptions: Sendable {
    public var backup: URL
    public var server: String?
    public var code: String?
    /// Nil: the sharing scope stored on the server when it has one, else everything.
    public var scope: ImportScope?
    public var dryRun: Bool
    public var limit: Int?

    public init(
        backup: URL, server: String?, code: String?, scope: ImportScope?, dryRun: Bool, limit: Int?
    ) {
        self.backup = backup
        self.server = server
        self.code = code
        self.scope = scope
        self.dryRun = dryRun
        self.limit = limit
    }
}

/// One run: open the backup, enumerate what the phone would send, keep what the scope allows,
/// build each payload with the phone's builder, check it, and send it in the phone's batches (or,
/// in a dry run, only count and check them).
public struct ImportRun {
    public enum Stop: Error, CustomStringConvertible {
        case message(String)
        public var description: String {
            switch self { case .message(let text): return text }
        }
    }

    let options: ImportOptions
    let tokens = TokenStore()
    let nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init(options: ImportOptions) { self.options = options }

    /// The exit status: 0 when every item was held by the server (or passed the check), 1 when
    /// any was rejected or failed the check.
    public func run() async throws -> Int32 {
        let started = Date()
        let library = try await BackupLibrary.open(options.backup, nowMs: nowMs)
        defer { library.close() }
        Output.line(
            "Backup   \(options.backup.lastPathComponent), last written \(Output.localTime(library.snapshotMs))")

        let rows = try await library.everything()
        let byKind = Dictionary(grouping: rows, by: \.kind).mapValues(\.count)
        Output.line("Library  \(Output.librarySummary(byKind))")

        // Linking first: the scope the person chose may be stored on the server.
        var endpoint: ArchiveEndpoint?
        var client: ImportClient?
        var scope = options.scope ?? .all
        var scopeNote = ""
        if !options.dryRun {
            let (linked, linkedClient, linkedNow) = try await link()
            endpoint = linked
            client = linkedClient
            // One request that also proves the link still works.
            let stored: ImportScope?
            do {
                stored = try await linkedClient.storedScope(linked)
            } catch ImportClient.Failure.unauthorized {
                if !linkedNow { tokens.remove(origin: linked.origin.absoluteString) }
                throw ImportClient.Failure.unauthorized
            }
            let how =
                !linkedNow ? "the link saved in the Keychain"
                : TokenStore.isUsable ? "linked just now, saved in the Keychain"
                : "linked just now, for this run only"
            Output.line("Server   \(linked.origin.absoluteString) as “\(Self.deviceName)” (\(how))")
            if options.scope == nil, let stored {
                scope = stored
                scopeNote = " (the sharing scope set on the phone)"
            }
        }
        let cutoff = scope.cutoffMs(nowMs: nowMs())
        let dates = try await ScopeDates.load(library.database, zoneID: library.zoneID)
        var tally = Tally()
        var selected: [ArchiveOutboxRow] = []
        for row in rows {
            if dates.contains(row.kind, id: row.entityId, cutoffMs: cutoff) {
                selected.append(row)
            } else {
                tally[row.kind].outOfScope += 1
            }
        }
        if let limit = options.limit, selected.count > limit {
            tally.overLimit = selected.count - limit
            selected = Array(selected.prefix(limit))
        }
        let limitNote = options.limit.map { " (at most \($0) items)" } ?? ""
        Output.line("Scope    \(scope.summary)\(scopeNote)\(limitNote): \(selected.count.formatted()) items")
        if options.dryRun { Output.line("Dry run  nothing is sent; every payload is built and checked.") }
        Output.line("")

        var sender = Sender(client: client, endpoint: endpoint, nowMs: nowMs)
        var assembler = BatchAssembler()
        var digest = SHA256()
        var bytes = 0
        let buildStarted = Date()
        for row in selected {
            let key = ArchiveItemKey(kind: row.kind, entityId: row.entityId, version: row.version)
            let built: ArchiveBuilt
            do {
                built = try await library.builder.build(row)
            } catch {
                tally[row.kind].notBuilt.append((row.entityId, "\(error)"))
                continue
            }
            let item: ArchiveBatchItem
            switch built {
            case .payload(let data, let hash, let pieceKey):
                item = ArchiveBatchItem(
                    key: key, op: .upsert, changedAtMs: row.changedAtMs, payload: data, hash: hash,
                    pieceKey: pieceKey)
            case .unchanged:
                // Only an outbox row with a sent hash is unchanged; the import's rows have none.
                tally[row.kind].unchanged += 1
                continue
            case .gone:
                // The phone would turn this into a delete. An import never deletes what the
                // server holds: it only adds what the backup has.
                tally[row.kind].gone += 1
                continue
            }
            let encoded = try item.encoded()
            digest.update(data: encoded)
            if let reason = ContractCheck.check(item: encoded) {
                tally[row.kind].failedCheck.append((row.entityId, reason))
                tally.noteFailed(key)
                if tally.firstFailure == nil {
                    tally.firstFailure = (row.kind, row.entityId, reason, encoded)
                }
            }
            let prepared = PreparedItem(key: key, encoded: encoded)
            guard assembler.fitsAlone(prepared) else {
                tally[row.kind].tooLarge.append(row.entityId)
                continue
            }
            bytes += encoded.count
            if let full = assembler.add(prepared) {
                try await sender.flush(full, dryRun: options.dryRun, tally: &tally)
                assembler.maxItems = sender.maxItems
            }
        }
        if let last = assembler.drain() {
            try await sender.flush(last, dryRun: options.dryRun, tally: &tally)
        }
        let digestText = digest.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)

        Output.line("")
        let verb = options.dryRun ? "Built and checked" : "Sent"
        Output.line(
            "\(verb) \(tally.itemsSent.formatted()) items in \(sender.batches.formatted()) "
                + "\(sender.batches == 1 ? "batch" : "batches") (\(Output.bytes(bytes))) in "
                + "\(Output.duration(Date().timeIntervalSince(started))); building took "
                + "\(Output.duration(sender.buildTime(since: buildStarted))). "
                + "Payload digest \(digestText).")
        Output.line("")
        tally.printTable(dryRun: options.dryRun)
        return tally.isClean ? 0 : 1
    }

    // MARK: - Linking

    static var deviceName: String {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return "Backup import on \(computer ?? ProcessInfo.processInfo.hostName)"
    }

    /// The endpoint to send to: linked now with `--code` (true), or the link saved by an earlier
    /// run (false).
    func link() async throws -> (ArchiveEndpoint, ImportClient, Bool) {
        guard let serverText = options.server else {
            throw Stop.message("Name the server with --server (for example --server \(ArchiveSyncProtocol.defaultOrigin)).")
        }
        guard let origin = ArchiveEndpoint.acceptableOrigin(serverText) else {
            throw Stop.message("The server must be an https address, or http to this Mac for a local server.")
        }
        let client = ImportClient(origin: origin)
        let key = origin.absoluteString
        if let code = options.code {
            let linked = try await client.link(code: code, deviceName: Self.deviceName)
            if TokenStore.isUsable {
                try tokens.save(
                    SavedLink(deviceId: linked.deviceId, deviceToken: linked.deviceToken), origin: key)
            }
            return (
                ArchiveEndpoint(origin: origin, deviceId: linked.deviceId, token: linked.deviceToken),
                client, true
            )
        }
        guard TokenStore.isUsable else {
            throw Stop.message(
                "Without a terminal the saved link is not read (the Keychain would ask on screen). "
                    + "Pass a new code with --code, or run it in Terminal.")
        }
        guard let saved = tokens.load(origin: key) else {
            throw Stop.message(
                "This Mac has no link to \(key) yet. Show a code on the server's admin page "
                    + "(Phones › Show a code) and pass it with --code.")
        }
        return (
            ArchiveEndpoint(origin: origin, deviceId: saved.deviceId, token: saved.deviceToken),
            client, false
        )
    }
}

// MARK: - Sending

/// Sends batches the phone's way and applies its answers: a 413 halves the batch, a transient
/// failure is tried again after a pause, anything else stops the run (a second run continues it;
/// the server ignores what it already holds).
struct Sender {
    let client: ImportClient?
    let endpoint: ArchiveEndpoint?
    let nowMs: @Sendable () -> Int64
    var maxItems = ArchiveSyncProtocol.maxItemsPerBatch
    var batches = 0
    private var networkTime: TimeInterval = 0
    private var lastLine = Date()

    init(client: ImportClient?, endpoint: ArchiveEndpoint?, nowMs: @escaping @Sendable () -> Int64) {
        self.client = client
        self.endpoint = endpoint
        self.nowMs = nowMs
    }

    func buildTime(since start: Date) -> TimeInterval {
        max(0, Date().timeIntervalSince(start) - networkTime)
    }

    mutating func flush(_ items: [PreparedItem], dryRun: Bool, tally: inout Tally) async throws {
        guard !dryRun, let client, let endpoint else {
            batches += 1
            let failed = items.filter { tally.failedKeys.contains($0.key) }.count
            for item in items { tally[item.key.kind].wouldSend += 1 }
            line(items, result: failed == 0 ? "passes the contract check" : "\(failed) fail the contract check")
            return
        }
        try await send(items, client: client, endpoint: endpoint, tally: &tally)
    }

    private mutating func send(
        _ items: [PreparedItem], client: ImportClient, endpoint: ArchiveEndpoint, tally: inout Tally
    ) async throws {
        let body = try ArchiveBatchBody.encode(
            deviceId: endpoint.deviceId, sentAtMs: nowMs(), items: items.map(\.encoded))
        var attempt = 0
        while true {
            let sentAt = Date()
            do {
                let answer = try await client.sendBatch(body, endpoint)
                networkTime += Date().timeIntervalSince(sentAt)
                switch answer {
                case .tooLarge:
                    guard items.count > 1 else {
                        tally[items[0].key.kind].rejected.append((items[0].key.entityId, "server: too large (413)"))
                        return
                    }
                    maxItems = max(1, min(maxItems, items.count) / 2)
                    Output.line("         the server asked for smaller batches; sending \(maxItems) at a time")
                    let half = items.count / 2
                    try await send(Array(items[..<half]), client: client, endpoint: endpoint, tally: &tally)
                    try await send(Array(items[half...]), client: client, endpoint: endpoint, tally: &tally)
                    return
                case .answered(let response):
                    batches += 1
                    tally.apply(response)
                    var parts = ["\(response.accepted.count) accepted"]
                    if !response.ignored.isEmpty { parts.append("\(response.ignored.count) already held") }
                    if !response.rejected.isEmpty { parts.append("\(response.rejected.count) rejected") }
                    line(items, result: parts.joined(separator: ", "))
                    return
                }
            } catch let failure as ImportClient.Failure where failure.isTransient && attempt < 3 {
                networkTime += Date().timeIntervalSince(sentAt)
                let pause = [2.0, 5.0, 15.0][attempt]
                attempt += 1
                Output.line("         \(failure) Trying again in \(Int(pause)) s.")
                try await Task.sleep(for: .seconds(pause))
            } catch let failure as ImportClient.Failure {
                throw ImportRun.Stop.message(
                    "Stopped at batch \(batches + 1). \(failure) What the server already holds is "
                        + "kept; run it again to continue.")
            }
        }
    }

    private mutating func line(_ items: [PreparedItem], result: String) {
        let size = items.reduce(0) { $0 + $1.encoded.count }
        let now = Date()
        let seconds = now.timeIntervalSince(lastLine)
        lastLine = now
        Output.line(
            "batch \(Output.pad("\(batches)", 4))  \(Output.pad("\(items.count) items", 9))  "
                + "\(Output.pad(Output.bytes(size), 8))  \(Output.padRight(result, 40)) "
                + String(format: "%.1f s", seconds))
    }
}

// MARK: - Counting

struct Tally {
    struct Kind {
        var outOfScope = 0
        var unchanged = 0
        var gone = 0
        var wouldSend = 0
        var accepted = 0
        var ignored: [String: Int] = [:]
        var rejected: [(String, String)] = []
        var failedCheck: [(String, String)] = []
        var notBuilt: [(String, String)] = []
        var tooLarge: [String] = []
    }

    private var kinds: [ArchiveEntityKind: Kind] = [:]
    /// In scope, but past `--limit`.
    var overLimit = 0
    var firstFailure: (ArchiveEntityKind, String, String, Data)?

    subscript(kind: ArchiveEntityKind) -> Kind {
        get { kinds[kind] ?? Kind() }
        set { kinds[kind] = newValue }
    }

    /// The items that failed the contract check, to say which batch holds them.
    private(set) var failedKeys: Set<ArchiveItemKey> = []

    var itemsSent: Int {
        kinds.values.reduce(0) { $0 + $1.wouldSend + $1.accepted + $1.ignored.values.reduce(0, +) + $1.rejected.count }
    }

    var isClean: Bool {
        kinds.values.allSatisfy {
            $0.rejected.isEmpty && $0.failedCheck.isEmpty && $0.notBuilt.isEmpty && $0.tooLarge.isEmpty
        }
    }

    mutating func noteFailed(_ key: ArchiveItemKey) { failedKeys.insert(key) }

    mutating func apply(_ response: ArchiveBatchResponse) {
        for item in response.accepted {
            guard let kind = ArchiveEntityKind(rawValue: item.kind) else { continue }
            self[kind].accepted += 1
        }
        for item in response.ignored {
            guard let kind = ArchiveEntityKind(rawValue: item.kind) else { continue }
            self[kind].ignored[item.reason ?? "ignored", default: 0] += 1
        }
        for item in response.rejected {
            guard let kind = ArchiveEntityKind(rawValue: item.kind) else { continue }
            self[kind].rejected.append((item.id, item.reason ?? "rejected"))
        }
    }

    func printTable(dryRun: Bool) {
        let columns =
            dryRun
            ? ["checked", "failed", "out of scope", "skipped"]
            : ["accepted", "already held", "rejected", "out of scope", "skipped"]
        Output.line(Output.padRight("", 14) + columns.map { Output.pad($0, 13) }.joined())
        for kind in ArchiveEntityKind.allCases {
            let k = self[kind]
            let skipped = k.gone + k.unchanged + k.notBuilt.count + k.tooLarge.count
            let held = k.ignored.values.reduce(0, +)
            let values =
                dryRun
                ? [k.wouldSend, k.failedCheck.count, k.outOfScope, skipped]
                : [k.accepted, held, k.rejected.count, k.outOfScope, skipped]
            Output.line(Output.padRight(kind.rawValue, 14) + values.map { Output.pad($0.formatted(), 13) }.joined())
        }

        var ignored = kinds.values.reduce(into: [String: Int]()) { all, k in
            for (reason, count) in k.ignored { all[reason, default: 0] += count }
        }
        let outsideScope = ignored.removeValue(forKey: "outsideScope") ?? 0
        if !ignored.isEmpty {
            // §3: `duplicate` is the same version again, `stale` older than the server's copy,
            // `outsideScope` outside the account's sharing scope (not stored).
            let parts = ignored.sorted { $0.key < $1.key }.map { reason, count in
                switch reason {
                case "duplicate": return "\(count.formatted()) at the same version"
                case "stale": return "\(count.formatted()) at a newer version"
                default: return "\(count.formatted()) (\(reason))"
                }
            }
            Output.line("")
            Output.line("The server already had \(Output.list(parts)).")
        }
        if outsideScope > 0 {
            Output.line("")
            Output.line("The server skipped \(outsideScope.formatted()) items outside the account's sharing scope.")
        }
        if overLimit > 0 {
            Output.line("")
            Output.line("Left for a later run by --limit: \(overLimit.formatted()) items.")
        }

        var problems: [String] = []
        for kind in ArchiveEntityKind.allCases {
            let k = self[kind]
            problems += k.rejected.map { "rejected      \(kind.rawValue) \($0.0): \($0.1)" }
            problems += k.failedCheck.map { "failed check  \(kind.rawValue) \($0.0): \($0.1)" }
            problems += k.notBuilt.map { "not built     \(kind.rawValue) \($0.0): \($0.1)" }
            problems += k.tooLarge.map { "too large     \(kind.rawValue) \($0)" }
            if k.gone > 0 { problems.append("gone          \(k.gone) \(kind.rawValue) no longer in the backup's database") }
        }
        if !problems.isEmpty {
            Output.line("")
            for problem in problems.prefix(60) { Output.line(problem) }
            if problems.count > 60 { Output.line("… and \(problems.count - 60) more") }
        }
        if let (kind, id, reason, encoded) = firstFailure {
            Output.line("")
            Output.line("First item that fails the contract check: \(kind.rawValue) \(id)")
            Output.line("  \(reason)")
            let text = String(decoding: encoded.prefix(600), as: UTF8.self)
            Output.line("  \(text)\(encoded.count > 600 ? "…" : "")")
        }
    }
}

// MARK: - Output

enum Output {
    static func line(_ text: String) {
        print(text)
        fflush(stdout)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }

    static func localTime(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "a, b, and c": the Oxford comma, always.
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }

    static func librarySummary(_ counts: [ArchiveEntityKind: Int]) -> String {
        let names: [ArchiveEntityKind: (String, String)] = [
            .conversation: ("conversation", "conversations"),
            .transcript: ("transcript", "transcripts"),
            .recap: ("day recap", "day recaps"),
            .brief: ("brief", "briefs"),
            .followUp: ("follow-up", "follow-ups"),
            .note: ("note", "notes"),
            .person: ("person", "people"),
            .coverage: ("day of coverage", "days of coverage"),
        ]
        return list(
            ArchiveEntityKind.allCases.compactMap { kind in
                guard let count = counts[kind], count > 0, let name = names[kind] else { return nil }
                return "\(count.formatted()) \(count == 1 ? name.0 : name.1)"
            })
    }
}
