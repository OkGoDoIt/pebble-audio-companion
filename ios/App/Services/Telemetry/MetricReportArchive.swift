import Foundation

/// Where MetricKit reports land on disk, and how many of them are kept.
///
/// `<containerRoot>/diagnostics/metrics/<stamp>-<kind>.json`, beside the flight recorder's
/// `companion.log`, so the one `devicectl copy from` the cost report already does for the log can
/// pull the reports the same way. Names sort as time: `20260917T031500Z-metrics.json`. Newest 14
/// kept across both kinds — MetricKit delivers a metrics report a day, so that is two weeks of
/// history for a few hundred kilobytes, and a diagnostics burst cannot grow the folder unbounded.
///
/// OS-agnostic on purpose: the writer and the rotation are exercised by tests on every OS, and
/// only the iOS 27 collector that feeds it knows what a `MetricReport` is.
struct MetricReportArchive: Sendable {
    enum Kind: String, Sendable {
        case metrics
        case diagnostic
    }

    let directory: URL
    let keep: Int

    init(directory: URL, keep: Int = 14) {
        self.directory = directory
        self.keep = keep
    }

    /// Writes one report and prunes the folder to the newest `keep` files. Returns the file
    /// written. A second report in the same second gets a distinct name rather than overwriting.
    @discardableResult
    func write(_ data: Data, kind: Kind, at date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(Self.fileName(for: date, kind: kind))
        var suffix = 1
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(Self.fileName(for: date, kind: kind, suffix: suffix))
            suffix += 1
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
        return url
    }

    /// Every report on disk, newest first.
    func files() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes everything but the newest `keep` reports.
    func prune() {
        let fm = FileManager.default
        for url in files().dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }

    /// `20260917T031500Z-metrics.json` — UTC, no colons (a share sheet and a shell both choke on
    /// them), lexically sortable.
    static func fileName(for date: Date, kind: Kind, suffix: Int? = nil) -> String {
        let stamp = stampFormatter.string(from: date)
        let tail = suffix.map { "-\($0)" } ?? ""
        return "\(stamp)-\(kind.rawValue)\(tail).json"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// What one daily MetricKit report says, reduced to the numbers the battery gate reads.
///
/// A plain value so the log line can be tested without MetricKit — the iOS 27 collector maps a
/// `MetricReport` into this; everything after that is OS-agnostic.
struct MetricReportSummary: Equatable, Sendable {
    struct StateCost: Equatable, Sendable {
        var label: String
        var cpuSeconds: Double
        var minutes: Double
    }

    /// The day the report covers (`yyyy-MM-dd`, from the start of its time range, UTC).
    var day: String
    /// Whole-day CPU seconds — the full-day interval entry, or the sum of the states when the
    /// report carries no full-day line.
    var totalCpuSeconds: Double
    /// Per-state cost for our domain, in the order the report listed them.
    var perState: [StateCost]
    /// Terminations that were not a normal exit: memory limit, CPU, pressure, watchdog, crashes.
    var terminations: Int
    /// The subset that is a crash proper: bad access, abnormal, illegal instruction, watchdog.
    var crashes: Int
    /// True when MetricKit hit its state-aggregation cap and folded some states into the full
    /// day — the per-state numbers are then a lower bound, and the line says so.
    var exceededStateLimit: Bool = false

    /// `metrickit day=2026-09-17 cpu_s=402.8 per-state: capturing-bg=312.5/720 idle-fg=40.3/30
    /// terminations=3 crash=1` — cpu-seconds per state over the minutes spent in it, so %/hour
    /// arithmetic is one division away.
    var logLine: String {
        var line = "metrickit day=\(day) cpu_s=\(Self.oneDecimal(totalCpuSeconds)) per-state:"
        if perState.isEmpty {
            line += " none"
        } else {
            for state in perState {
                line += " \(state.label)=\(Self.oneDecimal(state.cpuSeconds))/\(Int(state.minutes.rounded()))"
            }
        }
        line += " terminations=\(terminations) crash=\(crashes)"
        if exceededStateLimit { line += " state-limit-exceeded" }
        return line
    }

    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// One diagnostic (a crash, a hang, a CPU or disk-write exception, a launch) as a log line.
struct MetricDiagnosticSummary: Equatable, Sendable {
    /// `crash`, `hang`, `cpu-exception`, `disk-write-exception`, `app-launch`, `memory-exception`.
    var kind: String
    /// The report's own one-word detail: a crash's termination category, a hang's duration.
    var detail: String?
    /// Our activity labels that were active leading up to it.
    var states: [String]
    /// The end of the diagnostic's time range, for the log.
    var at: Date

    /// `metrickit diagnostic kind=crash detail=watchdog states=capturing-bg at=2026-09-17T03:15:00Z`
    var logLine: String {
        var line = "metrickit diagnostic kind=\(kind)"
        if let detail, !detail.isEmpty { line += " detail=\(detail)" }
        line += " states=\(states.isEmpty ? "none" : states.joined(separator: ","))"
        line += " at=\(at.formatted(.iso8601))"
        return line
    }
}
