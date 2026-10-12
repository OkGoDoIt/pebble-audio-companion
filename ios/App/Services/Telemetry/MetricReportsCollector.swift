import Foundation
import MetricKit

/// Receives MetricKit's daily metrics and its diagnostics (iOS 27), keeps each as JSON beside the
/// flight log, and writes one line per report into the log itself.
///
/// The manager is constructed with our StateReporting domain enabled — that is the registration:
/// from then on the day's CPU, memory and terminations arrive already split by the labels
/// `AppStateReporter` emitted, and the cost report can print "capturing-bg cost 312 CPU-s over
/// 720 minutes" without inferring anything from heartbeats.
///
/// Two facts about delivery shape this class:
///
/// - Reports are delivered to a subscriber that exists; a report that arrives while nobody is
///   iterating the sequence is queued by the system only briefly. So the collector starts with
///   the composition, on every launch, headless ones included.
/// - The simulator never delivers a MetricKit report. What a simulator run can prove is that
///   subscribing and registering the domain does not crash and logs its `metrickit: subscribed`
///   line; the first real report needs a day on the phone.
///
/// The log line is deliberately the shape a person reads back with the heartbeat: the summary
/// is computed here, but its wording lives in `MetricReportSummary` where a test can pin it.
@available(iOS 27, *)
final class MetricReportsCollector: @unchecked Sendable {
    private let manager: MetricManager
    private let archive: MetricReportArchive
    private let domain: String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - directory: `<containerRoot>/diagnostics/metrics`.
    ///   - domain: the StateReporting domain to aggregate by — `AppStateReporter.domain`.
    init(directory: URL, domain: String, log: @escaping @Sendable (String) -> Void) {
        self.manager = MetricManager(enabledStateReportingDomains: [StateReportingDomain(rawValue: domain)])
        self.archive = MetricReportArchive(directory: directory)
        self.domain = domain
        self.log = log
    }

    /// Subscribes to both sequences. Idempotent.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard tasks.isEmpty else { return }
        let manager = self.manager
        let enabled = manager.enabledStateReportingDomains.map(\.rawValue).sorted().joined(separator: ",")
        log("metrickit: subscribed domains=\(enabled) dir=\(archive.directory.lastPathComponent) keep=\(archive.keep)")
        tasks.append(Task.detached(priority: .utility) { [weak self] in
            for await report in manager.metricReports {
                guard let self else { return }
                self.handle(report)
            }
        })
        tasks.append(Task.detached(priority: .utility) { [weak self] in
            for await report in manager.diagnosticReports {
                guard let self else { return }
                self.handle(report)
            }
        })
    }

    func stop() {
        lock.withLock {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    // MARK: - Reports

    private func handle(_ report: MetricReport) {
        let summary = MetricReportSummary(report: report, domain: domain)
        log(summary.logLine)
        persist(report, kind: .metrics, at: report.timeRange.end)
    }

    private func handle(_ report: DiagnosticReport) {
        let summary = MetricDiagnosticSummary(report: report, domain: domain)
        log(summary.logLine)
        persist(report, kind: .diagnostic, at: report.timeRange.end)
    }

    /// The whole report as JSON, exactly as the framework encodes it (ISO 8601 dates for a
    /// human, sorted keys for a stable diff). A write failure is one log line, never a throw
    /// into the delivery loop.
    private func persist<Report: Encodable>(_ report: Report, kind: MetricReportArchive.Kind, at date: Date) {
        do {
            let data = try Self.encoder.encode(report)
            let url = try archive.write(data, kind: kind, at: date)
            log("metrickit: wrote \(url.lastPathComponent) bytes=\(data.count) kept=\(archive.files().count)")
        } catch {
            log("metrickit: could not write \(kind.rawValue) report: \(error)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    /// The matching decoder — for tests that round-trip a fixture, and for anything on the
    /// phone that wants to read an archived report back.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - MetricKit → summaries

@available(iOS 27, *)
extension MetricReportSummary {
    /// Reduces a report to the numbers the battery gate reads. `domain` selects our own states;
    /// a report can carry other domains' states and they are not ours to attribute.
    init(report: MetricReport, domain: String) {
        let ours = report.stateEntries.filter { $0.state.domain == domain }
        let perState = ours.map { entry in
            StateCost(
                label: entry.state.label,
                cpuSeconds: Self.cpuSeconds(in: entry.values),
                minutes: entry.state.duration.converted(to: .minutes).value)
        }
        // The full-day line: the interval entry spanning the most time. Chosen by duration rather
        // than `fullDayEntry` so an empty `intervalEntries` is a nil, not a trap.
        let fullDay = report.intervalEntries.max { $0.duration.converted(to: .seconds).value < $1.duration.converted(to: .seconds).value }
        let totalCpu = fullDay.flatMap { Self.cpuSeconds(in: $0.values) }
            ?? perState.reduce(0) { $0 + ($1.cpuSeconds ?? 0) }
        // Terminations come from the full-day line when there is one; otherwise every state's
        // own counts are summed (a state entry only ever counts what ended inside that state, so
        // the sum does not double-count).
        let terminationValues = fullDay.map { [$0.values] } ?? report.stateEntries.map(\.values)
        var terminations = 0
        var crashes = 0
        for values in terminationValues {
            let counts = Self.terminations(in: values)
            terminations += counts.total
            crashes += counts.crashes
        }
        self.init(
            day: Self.dayFormatter.string(from: report.timeRange.start),
            totalCpuSeconds: totalCpu,
            perState: perState,
            terminations: terminations,
            crashes: crashes,
            exceededStateLimit: report.environment?.hasExceededStateLimit ?? false)
    }

    static func cpuSeconds(in values: [MetricResult]) -> Double? {
        for value in values {
            if case .cpuTime(let metric) = value {
                return metric.value.converted(to: .seconds).value
            }
        }
        return nil
    }

    /// Non-normal terminations, and the crash subset of them. A normal exit — the person swiping
    /// the app away, iOS shutting it down cleanly — is not a fault and is not counted.
    static func terminations(in values: [MetricResult]) -> (total: Int, crashes: Int) {
        var total = 0
        var crashes = 0
        for value in values {
            switch value {
            case .foregroundTermination(let m):
                let crash = m.badAccessTerminationCount + m.abnormalTerminationCount
                    + m.illegalInstructionTerminationCount + m.watchdogTerminationCount
                crashes += crash
                total += crash + m.memoryLimitTerminationCount
            case .backgroundTermination(let m):
                let crash = m.badAccessTerminationCount + m.abnormalTerminationCount
                    + m.illegalInstructionTerminationCount + m.watchdogTerminationCount
                crashes += crash
                total += crash + m.memoryLimitTerminationCount + m.highCPUTerminationCount
                    + m.systemPressureTerminationCount + m.fileLockTerminationCount
                    + m.taskTimeoutTerminationCount
            default:
                break
            }
        }
        return (total, crashes)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@available(iOS 27, *)
extension MetricDiagnosticSummary {
    init(report: DiagnosticReport, domain: String) {
        let kind: String
        var detail: String?
        switch report.result {
        case .crash(let crash):
            kind = "crash"
            detail = crash.terminationCategory?.rawValue ?? crash.terminationReason?.rawValue
        case .hang(let hang):
            kind = "hang"
            detail = MetricReportSummary.oneDecimal(hang.hangDuration.converted(to: .seconds).value) + "s"
        case .cpuException(let cpu):
            kind = "cpu-exception"
            detail = MetricReportSummary.oneDecimal(cpu.totalCPUTime.converted(to: .seconds).value) + "s"
        case .diskWriteException(let disk):
            kind = "disk-write-exception"
            detail = "\(Int(disk.totalBytesWritten.converted(to: .megabytes).value.rounded()))MB"
        case .appLaunch(let launch):
            kind = "app-launch"
            detail = MetricReportSummary.oneDecimal(launch.launchDuration.converted(to: .seconds).value) + "s"
        case .memoryException:
            kind = "memory-exception"
        @unknown default:
            kind = "unknown"
        }
        self.init(
            kind: kind,
            detail: detail,
            states: report.environment.states.filter { $0.domain == domain }.map(\.label),
            at: report.timeRange.end)
    }
}
