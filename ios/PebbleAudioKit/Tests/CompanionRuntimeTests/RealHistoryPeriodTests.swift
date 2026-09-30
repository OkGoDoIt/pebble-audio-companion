import AppDB
import Foundation
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

// History's live read side (`HistoryReader`) over a real backup: every day built the way the app
// builds it (checked against the honesty invariants), then every week and every month, printed.
//
// Gated: set PEBBLE_HISTORY_BACKUP to a backup root (the folder holding `segments/`,
// `transcription/` and `db/`). The backup is only read: its database is copied to a temporary
// folder and opened there. Nothing from it is asserted beyond the invariants, and nothing from
// it is committed. PEBBLE_HISTORY_ZONE overrides the zone unstamped recordings are dated in
// (default Asia/Jakarta, where the stamped ones were made).

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_HISTORY_BACKUP"]

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

@Suite(
    "History weeks and months over a real backup",
    .enabled(if: backupAvailable, "set PEBBLE_HISTORY_BACKUP to a backup root")
)
struct RealHistoryPeriodTests {
    @Test("every day, week and month of the backup builds through the live reader")
    func everyPeriodBuilds() async throws {
        let root = URL(fileURLWithPath: backupRoot!)
        let zone = ProcessInfo.processInfo.environment["PEBBLE_HISTORY_ZONE"] ?? "Asia/Jakarta"
        let files = SegmentFileReader(root: root)
        let metas = files.listSegments()
        try #require(!metas.isEmpty)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-periods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in ["", "-wal", "-shm"] {
            let source = root.appendingPathComponent("db/companion.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("companion.sqlite\(suffix)"))
            }
        }
        let database = try AppDatabase.open(at: folder.appendingPathComponent("companion.sqlite"))
        // What the app does at launch for rows written before wall times were stored.
        let filled = try await FollowUpWallTimeFill(db: database).run { files.readMeta($0) }

        let transcripts = FileTranscriptStore(root: root, nowMs: { 0 })
        let reader = HistoryReader(
            sources: HistoryReader.Sources(
                database: database, recaps: DailyRecapStore(db: database),
                audioContent: AudioContentStore(db: database),
                speechRuns: HistorySpeechRunCache(transcripts: transcripts), transcripts: transcripts,
                segments: { metas }, currentZoneID: { zone }))
        let library = await reader.library()
        // "Now" is the end of the newest recording: the moment the backup was taken.
        let nowMs = library.extents.values.map(\.upperBound).max()!
        let bounds = await reader.bounds(library, nowMs: nowMs)
        let firstDay = try #require(bounds.firstDateKey)
        print("real-periods: \(metas.count) recordings, days \(firstDay)…\(bounds.todayDateKey), "
            + "\(bounds.recordedDays.count) recorded; follow-up wall times filled \(filled.filled); zone \(zone)")

        // Every day, through the reader: the same honesty the builder's own real-data run checks.
        let clock = ContinuousClock()
        var violations = 0
        var slowest: (String, Duration) = ("", .zero)
        for day in HistoryCalendar.days(in: firstDay...bounds.todayDateKey) {
            var built: HistoryReader.DayBuild!
            var input: HistoryDayBuilder.Input!
            let isToday = day == bounds.todayDateKey
            // The first build reads every transcript of the day; a rebuild finds them memoised.
            let cold = try await clock.measure {
                built = try await reader.day(day, library, nowMs: nowMs, isToday: isToday, isLive: false)
            }
            let elapsed = try await clock.measure {
                built = try await reader.day(day, library, nowMs: nowMs, isToday: isToday, isLive: false)
            }
            let inputs = try await reader.dayInput(day, library, nowMs: nowMs, isToday: isToday, isLive: false)
            input = inputs.builder
            let builderOnly = clock.measure { _ = HistoryDayBuilder.build(input) }
            if elapsed > slowest.1 { slowest = (day, elapsed) }
            let problems = HistoryDayBuilder.honestyViolations(of: built.day, input: input)
            violations += problems.count
            #expect(problems.isEmpty, "\(day): \(problems.joined(separator: "; "))")
            let cards = built.day.items.filter { if case .chapter = $0 { return true } else { return false } }.count
            print("real-periods: day \(day) \(built.day.items.count) items, \(cards) cards, "
                + "follow-ups \(built.followUpTotal)/\(built.followUpOpen) open, brief \(built.brief == nil ? "none" : "yes"), "
                + "\(inputs.turns.count) turns, built cold \(format(cold)), warm \(format(elapsed)) (the pure builder alone \(format(builderOnly)))")
        }
        print("real-periods: slowest day \(slowest.0) \(format(slowest.1)); \(violations) violations")

        // Every week (Sunday first, as the backup's phone had it) and every month.
        let firstWeekday = 1
        var week = HistoryCalendar.week(containing: firstDay, firstWeekday: firstWeekday)
        while week.lowerBound <= bounds.todayDateKey {
            var period: HistoryPeriod<HistoryWeekRow>!
            let elapsed = try await clock.measure {
                period = try await reader.week(
                    firstDateKey: week.lowerBound, lastDateKey: week.upperBound, library, nowMs: nowMs, isLive: false)
            }
            print(render(period, elapsed: elapsed))
            let next = HistoryCalendar.key(week.upperBound, addingDays: 1)
            week = HistoryCalendar.week(containing: next, firstWeekday: firstWeekday)
        }
        var month = HistoryCalendar.month(containing: firstDay)
        while month.lowerBound <= bounds.todayDateKey {
            var period: HistoryPeriod<HistoryMonthRow>!
            let first = month.lowerBound
            let elapsed = try await clock.measure {
                period = try await reader.month(
                    containing: first, firstWeekday: firstWeekday, library, nowMs: nowMs, isLive: false)
            }
            print(render(period, elapsed: elapsed))
            month = HistoryCalendar.month(containing: HistoryCalendar.key(month.upperBound, addingDays: 1))
        }

        // Snippets of the days asked for (PEBBLE_HISTORY_DAYS), and the results of the most used tag.
        let snippetDays = (ProcessInfo.processInfo.environment["PEBBLE_HISTORY_DAYS"] ?? "2026-09-22,2026-09-23")
            .split(separator: ",").map(String.init)
        for day in snippetDays {
            let built = try await reader.day(day, library, nowMs: nowMs, isToday: day == bounds.todayDateKey, isLive: false)
            for case .chapter(let card) in built.day.items {
                print("real-periods: snippet \(day) \(clip(card.title ?? card.snippet.map { "“\($0)”" }, 70))")
            }
        }
        let thisMonth = try await reader.month(
            containing: bounds.todayDateKey, firstWeekday: firstWeekday, library, nowMs: nowMs, isLive: false)
        if let tag = thisMonth.tagCounts.first?.name {
            var hits: [HistoryReader.TagHit] = []
            let elapsed = try await clock.measure { hits = try await reader.tagHits(tag: tag, library) }
            print("real-periods: tag “\(tag)”: \(hits.count) results on \(Set(hits.map(\.dateKey)).count) days in \(format(elapsed))")
            for hit in hits.prefix(8) { print("real-periods:    \(hit.dateKey) \(clip(hit.title, 60))") }
        }
    }
}

// MARK: - Printing

private func render(_ period: HistoryPeriod<HistoryWeekRow>, elapsed: Duration) -> String {
    var lines = [
        "---- week \(period.firstDateKey) … \(period.lastDateKey): follow-ups \(period.followUpTotal) "
            + "(\(period.followUpOpen) open), built in \(format(elapsed))"
    ]
    for row in period.rows {
        lines.append("   \(row.dateKey) \(state(row.state))")
        lines.append("      headline: \(row.headline ?? "—")")
        lines.append("      summary:  \(clip(row.summary))")
        lines.append("      tags:     \(row.tags.isEmpty ? "—" : row.tags.joined(separator: ", "))")
        let shown = row.followUps.map { "\($0.done ? "[x]" : "[ ]") \(clip($0.text, 40))" }
        lines.append("      follow-ups: \(shown.isEmpty ? "—" : shown.joined(separator: " | "))"
            + (row.moreFollowUps > 0 ? " + \(row.moreFollowUps) more" : ""))
    }
    return lines.joined(separator: "\n")
}

private func render(_ period: HistoryPeriod<HistoryMonthRow>, elapsed: Duration) -> String {
    let tags = period.tagCounts.prefix(8).map { "\($0.name) \($0.days)" }.joined(separator: ", ")
    var lines = [
        "==== month \(period.firstDateKey) … \(period.lastDateKey): follow-ups \(period.followUpTotal) "
            + "(\(period.followUpOpen) open), built in \(format(elapsed))",
        "   tag days: \(tags.isEmpty ? "—" : tags)",
    ]
    for row in period.rows {
        lines.append("   \(row.firstDateKey) … \(row.lastDateKey)\(row.isCurrentWeek ? " · this week" : "")"
            + "\(row.hasRecordings ? "" : " · nothing recorded")")
        lines.append("      headline: \(row.headline ?? "—")")
        lines.append("      summary:  \(clip(row.summary))")
        lines.append("      tags:     \(row.tags.isEmpty ? "—" : row.tags.joined(separator: ", "))")
        lines.append("      follow-ups: \(row.followUpTotal) · \(row.followUpOpen) open")
    }
    return lines.joined(separator: "\n")
}

private func state(_ state: HistoryDayState) -> String {
    switch state {
    case .nothingRecorded: return "nothing recorded"
    case .recorded: return "recorded"
    case .notTranscribedYet(let waiting): return "not transcribed yet (\(waiting / 60_000) min waiting)"
    case .today(let isLive): return "today\(isLive ? " (live)" : "")"
    }
}

private func clip(_ text: String?, _ limit: Int = 80) -> String {
    guard let text else { return "—" }
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

private func format(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
}
