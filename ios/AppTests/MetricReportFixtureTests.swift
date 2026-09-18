import Foundation
import MetricKit
import Testing

// The fixture is the JSON contract between the collector (which writes what MetricKit's own
// Codable produces) and the cost report's parser on the Mac (which reads it). Decoding it through
// the SDK proves the hand-written shape IS the SDK's shape; the summary mapping is then checked
// against the numbers in it. iOS 27 only — the report types do not exist below it, so on the
// iOS 26 simulator these tests are skipped rather than failed.
struct MetricReportFixtureTests {
    static var hasMetricKit27: Bool {
        if #available(iOS 27, *) { return true } else { return false }
    }

    static let fixtureURL = SwiftSource.iosRoot
        .appending(path: "AppTests/Fixtures/MetricKitSampleReport.json")

    @Test("the fixture decodes through MetricKit's own Codable", .enabled(if: hasMetricKit27))
    func fixtureDecodes() throws {
        guard #available(iOS 27, *) else { return }
        let data = try Data(contentsOf: Self.fixtureURL)
        let report = try MetricReportsCollector.decoder.decode(MetricReport.self, from: data)
        #expect(report.stateEntries.count == 4)
        #expect(report.intervalEntries.count == 1)
        #expect(report.environment?.bundleIdentifier == "dev.audiocompanion.app")
        #expect(report.timeRange.duration == 86_400)
    }

    @Test("the summary reads our states only, converts units, and counts terminations", .enabled(if: hasMetricKit27))
    func summary() throws {
        guard #available(iOS 27, *) else { return }
        let data = try Data(contentsOf: Self.fixtureURL)
        let report = try MetricReportsCollector.decoder.decode(MetricReport.self, from: data)
        let summary = MetricReportSummary(report: report, domain: AppStateReporter.domain)
        #expect(summary.day == "2026-09-17")
        #expect(summary.totalCpuSeconds == 402.75)
        // The foreign domain's 999 s is not ours; minutes and ms are converted.
        #expect(summary.perState == [
            .init(label: "capturing-bg", cpuSeconds: 312.5, minutes: 720),
            .init(label: "idle-fg", cpuSeconds: 40.25, minutes: 30),
            .init(label: "pipeline-bg", cpuSeconds: 50, minutes: 90),
        ])
        // bg: 1 abnormal (crash) + 2 memory-limit; fg: 2 normal exits, not counted.
        #expect(summary.terminations == 3)
        #expect(summary.crashes == 1)
        #expect(summary.exceededStateLimit == false)
        #expect(
            summary.logLine
                == "metrickit day=2026-09-17 cpu_s=402.8 per-state: capturing-bg=312.5/720 idle-fg=40.2/30 pipeline-bg=50.0/90 terminations=3 crash=1")
    }

    @Test("what the collector writes decodes back to the same summary", .enabled(if: hasMetricKit27))
    func roundTrip() throws {
        guard #available(iOS 27, *) else { return }
        let data = try Data(contentsOf: Self.fixtureURL)
        let report = try MetricReportsCollector.decoder.decode(MetricReport.self, from: data)
        let written = try MetricReportsCollector.encoder.encode(report)
        let again = try MetricReportsCollector.decoder.decode(MetricReport.self, from: written)
        #expect(
            MetricReportSummary(report: again, domain: AppStateReporter.domain)
                == MetricReportSummary(report: report, domain: AppStateReporter.domain))
        // The keys the Mac-side parser walks. If MetricKit ever renames them this is the test
        // that says so before a phone does.
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any] ?? [:]
        let entries = object["stateEntries"] as? [[String: Any]] ?? []
        #expect(entries.count == 4)
        let state = entries.first?["state"] as? [String: Any] ?? [:]
        #expect(state["label"] as? String == "capturing-bg")
        #expect(state["domain"] as? String == AppStateReporter.domain)
        let duration = state["duration"] as? [String: Any] ?? [:]
        #expect(duration["unit"] as? String == "s")
        let values = entries.first?["values"] as? [[String: Any]] ?? []
        let cpu = values.first?["cpuTimeMetric"] as? [String: Any] ?? [:]
        let cpuValue = cpu["value"] as? [String: Any] ?? [:]
        #expect(cpuValue["value"] as? Double == 312.5)
    }

    @Test("a report with no interval entries and no states still summarises", .enabled(if: hasMetricKit27))
    func emptyReport() throws {
        guard #available(iOS 27, *) else { return }
        let json = """
            {"timeRange": {"begin": "2026-09-17T00:00:00Z", "end": "2026-09-18T00:00:00Z"},
             "stateEntries": [], "intervalEntries": []}
            """
        let report = try MetricReportsCollector.decoder.decode(MetricReport.self, from: Data(json.utf8))
        let summary = MetricReportSummary(report: report, domain: AppStateReporter.domain)
        #expect(summary.logLine == "metrickit day=2026-09-17 cpu_s=0.0 per-state: none terminations=0 crash=0")
    }

    @Test("without a full-day line the total is the sum of our states and their terminations", .enabled(if: hasMetricKit27))
    func noFullDay() throws {
        guard #available(iOS 27, *) else { return }
        let json = """
            {"timeRange": {"begin": "2026-09-17T00:00:00Z", "end": "2026-09-18T00:00:00Z"},
             "intervalEntries": [],
             "stateEntries": [
               {"state": {"domain": "dev.audiocompanion.app.activity", "label": "idle-bg",
                          "duration": {"value": 3600, "unit": "s"}, "stableMetadata": {}},
                "values": [{"cpuTimeMetric": {"value": {"value": 1.5, "unit": "s"}}},
                           {"backgroundTerminationMetric": {"normalTerminationCount": 1,
                             "memoryLimitTerminationCount": 0, "highCPUTerminationCount": 1,
                             "systemPressureTerminationCount": 0, "badAccessTerminationCount": 0,
                             "abnormalTerminationCount": 0, "illegalInstructionTerminationCount": 0,
                             "watchdogTerminationCount": 1, "fileLockTerminationCount": 0,
                             "taskTimeoutTerminationCount": 0}}]},
               {"state": {"domain": "dev.audiocompanion.app.activity", "label": "capturing-bg",
                          "duration": {"value": 2, "unit": "hr"}, "stableMetadata": {}},
                "values": [{"cpuTimeMetric": {"value": {"value": 4, "unit": "s"}}}]}
             ]}
            """
        let report = try MetricReportsCollector.decoder.decode(MetricReport.self, from: Data(json.utf8))
        let summary = MetricReportSummary(report: report, domain: AppStateReporter.domain)
        #expect(summary.totalCpuSeconds == 5.5)
        #expect(summary.perState.map(\.minutes) == [60, 120])
        #expect(summary.terminations == 2)  // high CPU + watchdog; the normal exit is not a fault
        #expect(summary.crashes == 1)  // the watchdog
    }

    @Test("a diagnostic report becomes one line naming the kind and our active states", .enabled(if: hasMetricKit27))
    func diagnostic() throws {
        guard #available(iOS 27, *) else { return }
        let json = """
            {"timeRange": {"begin": "2026-09-17T03:14:00Z", "end": "2026-09-17T03:15:00Z"},
             "environment": {"regionFormat": "US",
                             "osVersion": {"platform": "iOS", "number": "27.0", "buildNumber": "25A5300"},
                             "deviceType": "iPhone18,3", "platformArchitecture": "arm64e",
                             "lowPowerModeEnabled": false, "isTestFlightApp": false,
                             "applicationVersion": "2.0.0", "applicationBuildVersion": "1",
                             "bundleIdentifier": "dev.audiocompanion.app", "signpostData": [],
                             "states": [
                               {"domain": "dev.audiocompanion.app.activity", "label": "capturing-bg",
                                "duration": {"value": 600, "unit": "s"}, "stableMetadata": {}},
                               {"domain": "com.example.other", "label": "x",
                                "duration": {"value": 600, "unit": "s"}, "stableMetadata": {}}]},
             "crashDiagnostic": {
                "callStackTree": {"callStackThreads": [], "callStackPerThread": true, "binaryInfo": []},
                "terminationCategory": "watchdog"}}
            """
        // Note the shape: the diagnostic case (`crashDiagnostic`, `hangDiagnostic`, …) sits at the
        // report's root beside `timeRange`, not under a `result` key — MetricKit flattens it.
        let report = try MetricReportsCollector.decoder.decode(DiagnosticReport.self, from: Data(json.utf8))
        let summary = MetricDiagnosticSummary(report: report, domain: AppStateReporter.domain)
        #expect(summary.logLine == "metrickit diagnostic kind=crash detail=watchdog states=capturing-bg at=2026-09-17T03:15:00Z")
    }
}
