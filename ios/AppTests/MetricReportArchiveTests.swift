import Foundation
import Testing

// The archive is what the cost report pulls off the phone; its naming, rotation and the two log
// lines are OS-agnostic and pinned here on every simulator.
struct MetricReportArchiveTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metric-archive-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("file names sort as time and never carry a colon")
    func fileNames() {
        let date = Date(timeIntervalSince1970: 1_789_616_100)  // 2026-09-17T03:35:00Z
        let name = MetricReportArchive.fileName(for: date, kind: .metrics)
        #expect(name == "20260917T033500Z-metrics.json")
        #expect(!name.contains(":"))
        #expect(MetricReportArchive.fileName(for: date, kind: .diagnostic, suffix: 2) == "20260917T033500Z-diagnostic-2.json")
        let later = MetricReportArchive.fileName(for: date.addingTimeInterval(1), kind: .metrics)
        #expect(later > name)
    }

    @Test("write creates the directory, and a same-second report gets a distinct name")
    func writeAndCollide() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = MetricReportArchive(directory: dir)
        let date = Date(timeIntervalSince1970: 1_789_616_100)
        let first = try archive.write(Data("{\"a\":1}".utf8), kind: .metrics, at: date)
        let second = try archive.write(Data("{\"a\":2}".utf8), kind: .metrics, at: date)
        #expect(first.lastPathComponent == "20260917T033500Z-metrics.json")
        #expect(second.lastPathComponent == "20260917T033500Z-metrics-1.json")
        #expect(try String(contentsOf: first, encoding: .utf8) == "{\"a\":1}")
        #expect(try String(contentsOf: second, encoding: .utf8) == "{\"a\":2}")
        #expect(archive.files().count == 2)
    }

    @Test("the newest `keep` files survive a prune, oldest go first, across both kinds")
    func rotation() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = MetricReportArchive(directory: dir, keep: 3)
        let base = Date(timeIntervalSince1970: 1_789_615_200)
        for i in 0..<5 {
            let kind: MetricReportArchive.Kind = i % 2 == 0 ? .metrics : .diagnostic
            try archive.write(Data("\(i)".utf8), kind: kind, at: base.addingTimeInterval(Double(i) * 60))
        }
        let names = archive.files().map(\.lastPathComponent)
        #expect(names.count == 3)
        // Newest first.
        #expect(names == [
            "20260917T032400Z-metrics.json",
            "20260917T032300Z-diagnostic.json",
            "20260917T032200Z-metrics.json",
        ])
    }

    @Test("the default cap is fourteen")
    func defaultKeep() {
        #expect(MetricReportArchive(directory: temporaryDirectory()).keep == 14)
    }

    @Test("files() ignores anything that is not a report")
    func ignoresStrangers() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let archive = MetricReportArchive(directory: dir)
        #expect(archive.files().isEmpty)
        try archive.write(Data("{}".utf8), kind: .metrics)
        #expect(archive.files().count == 1)
    }

    @Test("a missing directory lists nothing and prunes nothing")
    func missingDirectory() {
        let archive = MetricReportArchive(directory: temporaryDirectory())
        #expect(archive.files().isEmpty)
        archive.prune()
    }
}

// The one line per report the flight log carries. Its shape is what a person greps for, so the
// format is pinned exactly.
struct MetricReportSummaryTests {
    @Test("the metrics line: day, whole-day cpu, cpu-seconds/minutes per state, terminations")
    func metricsLine() {
        let summary = MetricReportSummary(
            day: "2026-09-17",
            totalCpuSeconds: 402.75,
            perState: [
                .init(label: "capturing-bg", cpuSeconds: 312.5, minutes: 720),
                .init(label: "idle-fg", cpuSeconds: 40.25, minutes: 30),
                .init(label: "pipeline-bg", cpuSeconds: 50, minutes: 90.4),
            ],
            terminations: 3,
            crashes: 1)
        #expect(
            summary.logLine
                == "metrickit day=2026-09-17 cpu_s=402.8 per-state: capturing-bg=312.5/720 idle-fg=40.2/30 pipeline-bg=50.0/90 terminations=3 crash=1")
    }

    @Test("a state the report split no CPU for prints `?`, never a figure")
    func noCpuSplit() {
        // What the phone's own reports look like (iOS 27.0.1): minutes per state, CPU only on
        // the full-day line. Six days of "capturing-bg=0.0/1407" once read as a free day.
        let summary = MetricReportSummary(
            day: "2026-10-10",
            totalCpuSeconds: 1224,
            perState: [
                .init(label: "capturing-bg", cpuSeconds: nil, minutes: 1406.8),
                .init(label: "idle-bg", cpuSeconds: 0, minutes: 4.8),
            ],
            terminations: 0,
            crashes: 0)
        #expect(
            summary.logLine
                == "metrickit day=2026-10-10 cpu_s=1224.0 per-state: capturing-bg=?/1407 idle-bg=0.0/5 terminations=0 crash=0")
    }

    @Test("no states of ours in the report reads `none`, not an empty tail")
    func noStates() {
        let summary = MetricReportSummary(day: "2026-09-17", totalCpuSeconds: 0, perState: [], terminations: 0, crashes: 0)
        #expect(summary.logLine == "metrickit day=2026-09-17 cpu_s=0.0 per-state: none terminations=0 crash=0")
    }

    @Test("a report past MetricKit's state cap says so on the line")
    func stateLimit() {
        var summary = MetricReportSummary(day: "2026-09-17", totalCpuSeconds: 1, perState: [], terminations: 0, crashes: 0)
        summary.exceededStateLimit = true
        #expect(summary.logLine.hasSuffix(" state-limit-exceeded"))
    }

    @Test("the diagnostic line: kind, detail when there is one, our states, the time")
    func diagnosticLine() {
        let at = Date(timeIntervalSince1970: 1_789_616_100)
        let crash = MetricDiagnosticSummary(kind: "crash", detail: "watchdog", states: ["capturing-bg"], at: at)
        #expect(crash.logLine == "metrickit diagnostic kind=crash detail=watchdog states=capturing-bg at=2026-09-17T03:35:00Z")
        let hang = MetricDiagnosticSummary(kind: "hang", detail: nil, states: [], at: at)
        #expect(hang.logLine == "metrickit diagnostic kind=hang states=none at=2026-09-17T03:35:00Z")
        let launch = MetricDiagnosticSummary(kind: "app-launch", detail: "", states: ["idle-fg", "playback"], at: at)
        #expect(launch.logLine == "metrickit diagnostic kind=app-launch states=idle-fg,playback at=2026-09-17T03:35:00Z")
    }
}
