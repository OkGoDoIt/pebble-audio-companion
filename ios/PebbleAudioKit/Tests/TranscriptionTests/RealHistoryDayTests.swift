import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing

@testable import Transcription

// History's day builder over a real backup: every logical day in it, built from the real
// sidecars, pause journal, conversations and transcripts, checked against the honesty
// invariants, with a per-day summary printed (and whole timelines for `PEBBLE_HISTORY_DAYS`).
//
// Gated: set PEBBLE_HISTORY_BACKUP to a backup root (the folder holding `segments/`,
// `transcription/` and `db/`). The backup is only read: the database is copied to a temporary
// folder before it is opened. Nothing a transcript says is asserted or committed; titles are
// printed only when a day's timeline is asked for.
//
// PEBBLE_HISTORY_ZONE overrides the zone unstamped recordings are dated in. The default is the
// zone of the backup's newest stamped recording, read from the backup: where the phone was when
// it was taken, which is what the app dates unstamped recordings in (`ZoneTimeline`). A fixed
// city here dated them in a zone the stamped ones never name, and `ZoneTimeline` makes a change
// point of every differing identifier, so the days grew zone changes the phone never had.

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_HISTORY_BACKUP"]

/// The zone of the newest recording that carries a valid stamp; the Mac's own when none does.
func backupCurrentZoneID(_ metas: [SegmentMeta]) -> String {
    metas
        .filter { $0.recordedTimeZone.flatMap(TimeZone.init(identifier:)) != nil }
        .max { $0.startWallMs < $1.startWallMs }?
        .recordedTimeZone ?? TimeZone.current.identifier
}

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

@Suite(
    "History days over a real backup",
    .enabled(if: backupAvailable, "set PEBBLE_HISTORY_BACKUP to a backup root")
)
struct RealHistoryDayTests {
    @Test("every day of the backup builds, keeps every promise, and reads sanely")
    func everyDayIsHonest() throws {
        let root = URL(fileURLWithPath: backupRoot!)
        let env = ProcessInfo.processInfo.environment
        let printDays = Set((env["PEBBLE_HISTORY_DAYS"] ?? "2026-09-22,2026-09-23,2026-09-24").split(separator: ",").map(String.init))

        let metas = SegmentFileReader(root: root).listSegments()
        try #require(!metas.isEmpty)
        let zone = env["PEBBLE_HISTORY_ZONE"] ?? backupCurrentZoneID(metas)
        let store = try BackupDatabase(root: root)
        defer { store.remove() }
        let tasks = try store.tasks()
        let pauses = try store.pauses()
        let conversations = try store.conversations()

        // Speech runs: exactly the grouper's evidence (`EnrichmentService.speechEvidence`) placed
        // by `spokenRuns`.
        let transcripts = FileTranscriptStore(root: root, nowMs: { 0 })
        var runs: [HistorySpeechRun] = []
        var previews: [HistoryTurnPreview] = []  // turn texts: printed, never committed
        var states: [HistorySegmentState] = []
        var withoutFile = 0
        for meta in metas {
            let task = tasks[meta.segmentId]
            var state = task?.state ?? meta.transcriptionState
            let timings = state == .complete ? transcripts.loadSpeechTimings(meta.segmentId) : nil
            if state == .complete, timings == nil {
                // "Complete" with no transcript file is a bookkeeping fault, not silence: there
                // are no words anyone can read, so it is drawn as waiting for them.
                state = .pending
                withoutFile += 1
            }
            if let entry = HistorySegmentState(meta: meta, state: state, failureReason: task?.lastError) {
                states.append(entry)
            }
            guard let timings else { continue }
            var evidenceMeta = meta
            evidenceMeta.transcriptionState = state
            let evidence = SegmentSpeechEvidence.of(
                evidenceMeta,
                transcriptSpeech: timings.map { SpeechSpan(startMs: $0.startMs, endMs: $0.endMs) })
            let placed = ConversationBoundaryDetector.spokenRuns(evidenceMeta, evidence)
            runs += placed.map {
                HistorySpeechRun(segmentId: meta.segmentId, startMs: $0.startMs, endMs: $0.endMs)
            }
            // One run per transcript turn, in order: the turn's text rides on its placement.
            previews += zip(placed, timings).map {
                HistoryTurnPreview(startMs: $0.0.startMs, text: String($0.1.text.prefix(160)))
            }
        }
        print("real-history: \(metas.count) recordings, \(runs.count) speech runs, \(conversations.count) conversations, "
            + "\(pauses.count) pauses, \(withoutFile) complete without a transcript file; zone \(zone)")

        let timeline = ZoneTimeline(segments: metas, currentZoneID: zone)
        let inputs = metas.map { SegmentCoverageInput(meta: $0) }
        let dayKeys = Set(metas.map { timeline.dayKey(forMs: $0.startWallMs) }).sorted()
        var failures = 0
        // Every day under the default rules, and again under the strict loss form.
        let variants: [(name: String, rules: HistoryDayRules)] = [
            ("default", .default), ("strict", HistoryDayRules(carryShortLoss: false)),
        ]
        for dateKey in dayKeys {
            for variant in variants {
                let input = HistoryDayBuilder.Input(
                    dateKey: dateKey, windows: HistoryDayWindow.from(timeline.windows(of: dateKey)),
                    segments: inputs, pauses: pauses, speechRuns: runs, segmentStates: states,
                    conversations: conversations, turnPreviews: previews, rules: variant.rules)
                let clock = ContinuousClock()
                var day: HistoryDay!
                let elapsed = clock.measure { day = HistoryDayBuilder.build(input) }
                let problems = HistoryDayBuilder.honestyViolations(of: day, input: input)
                failures += problems.count
                for problem in problems { print("real-history: \(dateKey) \(variant.name) VIOLATION \(problem)") }
                #expect(problems.isEmpty, "\(dateKey) \(variant.name): \(problems.joined(separator: "; "))")

                print("real-history: \(dateKey) [\(variant.name)] \(summary(day)) built in \(format(elapsed))")
                if variant.name == "default" { print(cardDistribution(day)) }
                if printDays.contains(dateKey), variant.name == "default" {
                    print(render(day, zone: zone, variant: variant.name))
                }
            }
        }
        print("real-history: \(dayKeys.count) days, \(failures) violations")
    }
}

// MARK: - Reading the backup

private struct BackupDatabase {
    let folder: URL
    let queue: DatabaseQueue

    init(root: URL) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = root.appendingPathComponent("db/companion.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("companion.sqlite\(suffix)"))
            }
        }
        queue = try DatabaseQueue(path: folder.appendingPathComponent("companion.sqlite").path)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func tasks() throws -> [String: (state: TranscriptionState, lastError: String?)] {
        try queue.read { db in
            var out: [String: (TranscriptionState, String?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT segmentId, state, lastError FROM transcription_tasks") {
                guard let state = TranscriptionState(rawValue: row["state"]) else { continue }
                out[row["segmentId"]] = (state, row["lastError"])
            }
            return out
        }
    }

    func pauses() throws -> [PauseInterval] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT startMs, endMs, source FROM pause_intervals").map {
                PauseInterval(startMs: $0["startMs"], endMs: $0["endMs"], source: $0["source"])
            }
        }
    }

    func conversations() throws -> [HistoryConversationInput] {
        try queue.read { db in
            var members: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT conversationId, segmentId FROM conversation_segments ORDER BY conversationId, ordinal")
            {
                members[row["conversationId"], default: []].append(row["segmentId"])
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.startMs, c.endMs, a.title FROM conversations c
                    LEFT JOIN annotations a ON a.conversationId = c.id ORDER BY c.startMs
                    """
            ).map { row in
                let id: String = row["id"]
                let start: Int64 = row["startMs"]
                return HistoryConversationInput(
                    id: id, startMs: start, endMs: row["endMs"] ?? start, title: row["title"],
                    segmentIds: members[id] ?? [])
            }
        }
    }
}

// MARK: - Printing

private func label(_ item: HistoryItem) -> String {
    switch item {
    case .chapter(let block):
        let missing = block.missingMs > 0 ? " · \(minutes(block.missingMs)) missing" : ""
        let words = block.snippet.map { snippet -> String in
            let flat = snippet.replacingOccurrences(of: "\n", with: " ")
            return " \u{201C}\(flat.prefix(60))\(flat.count > 60 ? "…" : "")\u{201D}"
        } ?? ""
        return "card\(block.title.map { " [\($0)]" } ?? "")\(missing)\(words)"
    case .gap(let gap):
        guard gap.missingMs > 0 else { return gapLabel(gap) }
        let causes = gap.lossCauses.map(\.rawValue).joined(separator: ", ")
        return gapLabel(gap) + " · \(minutes(gap.missingMs)) missing [\(causes)]"
    case .zoneChange(let change): return "zoneChange [\(change.zoneID)]"
    case .live: return "live"
    }
}

private func gapLabel(_ gap: HistoryGap) -> String {
    switch gap.kind {
    case .paused: return "paused [\(gap.pausedBy.map(\.rawValue) ?? "?")]"
    case .audioMissing:
        return "audioMissing [\(gap.lossCauses.map(\.rawValue).joined(separator: ", "))]"
    case .noConversation: return "noConversation" + (gap.descriptor.map { " [\($0)]" } ?? "")
    case .transcriptionFailed: return "transcriptionFailed [\(gap.failureReason.map { String($0.prefix(40)) } ?? "")]"
    case .deleted: return "deleted [\(gap.deletedBy.map(\.rawValue) ?? "?")]"
    default: return gap.kind.rawValue
    }
}

/// Cards on the day: how many, median / p90 / max length, over an hour, over two, under ten
/// minutes, and every card over an hour.
private func cardDistribution(_ day: HistoryDay) -> String {
    let cards = day.items.compactMap { item -> HistoryChapterBlock? in
        if case .chapter(let block) = item { return block } else { return nil }
    }
    let lengths = cards.map { $0.endMs - $0.startMs }.sorted()
    guard !lengths.isEmpty else { return "real-history: \(day.dateKey) cards: none" }
    func percentile(_ p: Double) -> Int64 { lengths[min(lengths.count - 1, Int((Double(lengths.count - 1) * p).rounded()))] }
    let long = cards.filter { $0.endMs - $0.startMs > 3_600_000 }
    let list = long.map { "\(clock($0.startMs, day.zoneID))–\(clock($0.endMs, day.zoneID)) \(minutes($0.endMs - $0.startMs))" }
    return "real-history: \(day.dateKey) cards \(cards.count): median \(minutes(percentile(0.5))), "
        + "p90 \(minutes(percentile(0.9))), max \(minutes(lengths.last!)); "
        + "> 60 min \(long.count), > 120 min \(lengths.filter { $0 > 7_200_000 }.count), "
        + "< 10 min \(lengths.filter { $0 < 600_000 }.count)"
        + (list.isEmpty ? "" : "; over an hour: " + list.joined(separator: ", "))
}

private func kindKey(_ item: HistoryItem) -> String {
    switch item {
    case .chapter: return "card"
    case .gap(let gap): return gap.kind.rawValue
    case .zoneChange: return "zoneChange"
    case .live: return "live"
    }
}

private func summary(_ day: HistoryDay) -> String {
    guard day.hasRecordings else { return "nothing recorded" }
    var counts: [String: Int] = [:]
    var totals: [String: Int64] = [:]
    for item in day.items {
        counts[kindKey(item), default: 0] += 1
        totals[kindKey(item), default: 0] += item.endMs - item.startMs
    }
    let missing = day.items.reduce(Int64(0)) {
        switch $1 {
        case .chapter(let block): return $0 + block.missingMs
        case .gap(let gap): return $0 + gap.missingMs
        default: return $0
        }
    }
    let kinds = counts.keys.sorted().map { "\($0) \(counts[$0]!)×\(minutes(totals[$0]!))" }.joined(separator: ", ")
    let cards = day.items.compactMap { item -> HistoryChapterBlock? in
        if case .chapter(let block) = item { return block } else { return nil }
    }
    let longest = cards.map { $0.endMs - $0.startMs }.max() ?? 0
    let short = cards.filter { $0.endMs - $0.startMs < HistoryDayRules.default.foldBelowMs }.count
    let lead = day.leadingEdge.map { "\($0.kind.rawValue) until \(clock($0.atMs, day.zoneID))" } ?? "-"
    let trail = day.trailingEdge.map { "\($0.kind.rawValue) after \(clock($0.atMs, day.zoneID))" } ?? "-"
    return "\(day.items.count) items, \(cards.count) cards (longest \(minutes(longest)), \(short) under 2 min) "
        + "(\(kinds)); carried missing \(minutes(missing)); edges \(lead) / \(trail);"
}

private func render(_ day: HistoryDay, zone: String, variant: String) -> String {
    var lines = ["---- \(day.dateKey) [\(variant)] (\(day.items.count) items)"]
    if let edge = day.leadingEdge { lines.append("   … \(edge.kind.rawValue) until \(clock(edge.atMs, zone))") }
    for item in day.items {
        let span = "\(clock(item.startMs, zone))–\(clock(item.endMs, zone))"
        lines.append("   \(span) \(label(item)) \(minutes(item.endMs - item.startMs))")
    }
    if let edge = day.trailingEdge { lines.append("   … \(edge.kind.rawValue) after \(clock(edge.atMs, zone))") }
    return lines.joined(separator: "\n")
}

private func clock(_ ms: Int64, _ zone: String) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

private func minutes(_ ms: Int64) -> String {
    if ms < 60_000 { return "\(ms / 1000)s" }
    let total = ms / 60_000
    return total >= 60 ? "\(total / 60)h\(String(format: "%02d", total % 60))m" : "\(total)m"
}

private func format(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.2f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
}
