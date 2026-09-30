import AppDB
import Foundation

// DEBUG: a demo day built from a file of real conversation units, for judging the day's density
// on real shapes (`-historyUnitsTSV <file or folder>`). Nothing from such a file is committed;
// the file is read at launch from wherever the argument points.
//
// Columns (tab-separated, with a header): id, startMs, endMs, startLocal, endLocal,
// durationMin, reason, hasSpeech, wordCount, title, noConversation. The day key comes from the
// file name (`units-2026-09-22.tsv`).
//
// Rules, as the day builder draws them: a unit with no speech is quiet (the silent leading
// pieces of a run); a unit with speech but no conversation is a "No conversation" gap when it
// is 15 minutes or longer, and quiet when shorter; every other unit is a card. Time between
// units is quiet; neighbouring quiets merge; quiet at either end of the day becomes the edge.
//
// The files carry no titles yet (enrichment has not run). Cards are given PLACEHOLDER titles,
// summaries and tags, cycled by index, so the titled look can be judged; `-historyUnitsUntitled`
// draws them untitled instead, with a placeholder first-words quote.

#if DEBUG
extension MockHistory {
    struct UnitRow {
        var startMs: Int64
        var endMs: Int64
        var startLocal: String
        var hasSpeech: Bool
        var title: String
        var noConversation: Bool
    }

    static let unitDays: [String: HistoryDayPage] = loadUnitDays()

    private static func loadUnitDays() -> [String: HistoryDayPage] {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-historyUnitsTSV"), i + 1 < args.count else { return [:] }
        let path = (args[i + 1] as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [:] }
        let files: [URL]
        if isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            files = names.filter { $0.hasPrefix("units-") && $0.hasSuffix(".tsv") }
                .map { URL(fileURLWithPath: path).appending(path: $0) }
        } else {
            files = [URL(fileURLWithPath: path)]
        }
        let untitled = args.contains("-historyUnitsUntitled")
        var days: [String: HistoryDayPage] = [:]
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let key = String(name.dropFirst("units-".count))
            guard key.count == 10, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rows = parseUnits(text)
            guard !rows.isEmpty else { continue }
            days[key] = unitDay(key, rows: rows, untitled: untitled)
        }
        return days
    }

    static func parseUnits(_ text: String) -> [UnitRow] {
        var rows: [UnitRow] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where n > 0 {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 11, let start = Int64(c[1]), let end = Int64(c[2]) else { continue }
            rows.append(UnitRow(
                startMs: start, endMs: max(start, end), startLocal: c[3], hasSpeech: c[7] == "true",
                title: c[9], noConversation: c[10] == "true"))
        }
        return rows.sorted { $0.startMs < $1.startMs }
    }

    /// The zone the file's local times were written in, from the first row's offset.
    private static func zone(of row: UnitRow) -> String {
        let parts = row.startLocal.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return TimeZone.current.identifier }
        let utcMinutes = Int((row.startMs / 60_000) % 1440)
        var offset = (parts[0] * 60 + parts[1] - utcMinutes) % 1440
        if offset > 720 { offset -= 1440 }
        if offset < -720 { offset += 1440 }
        return TimeZone(secondsFromGMT: offset * 60)?.identifier ?? TimeZone.current.identifier
    }

    static func unitDay(_ key: String, rows: [UnitRow], untitled: Bool) -> HistoryDayPage {
        let zoneID = zone(of: rows[0])
        enum Piece { case quiet, noConversation, card(Int) }
        var pieces: [(Piece, Int64, Int64)] = []
        var cursor = rows[0].startMs
        for (index, row) in rows.enumerated() {
            let start = max(row.startMs, cursor)
            let end = row.endMs
            if start > cursor { pieces.append((.quiet, cursor, start)) }
            guard end > start else { continue }
            let minutes = Double(end - start) / 60_000
            if !row.hasSpeech {
                pieces.append((.quiet, start, end))
            } else if row.noConversation {
                pieces.append((minutes >= 15 ? .noConversation : .quiet, start, end))
            } else {
                pieces.append((.card(index), start, end))
            }
            cursor = end
        }
        // Neighbouring quiets merge; quiet at either end is the edge.
        var merged: [(Piece, Int64, Int64)] = []
        for piece in pieces {
            if case .quiet = piece.0, let last = merged.last, case .quiet = last.0 {
                merged[merged.count - 1].2 = piece.2
            } else {
                merged.append(piece)
            }
        }
        while let first = merged.first, case .quiet = first.0 { merged.removeFirst() }
        while let last = merged.last, case .quiet = last.0 { merged.removeLast() }

        var items: [HistoryItem] = []
        var serial = 0
        for (piece, start, end) in merged {
            serial += 1
            switch piece {
            case .quiet:
                items.append(.gap(HistoryGap(id: "u\(serial)", kind: .quiet, startMs: start, endMs: end, zoneID: zoneID)))
            case .noConversation:
                items.append(.gap(HistoryGap(
                    id: "u\(serial)", kind: .noConversation, startMs: start, endMs: end, zoneID: zoneID,
                    isOpenable: true)))
            case .card(let index):
                let title = rows[index].title.isEmpty ? Placeholder.titles[index % Placeholder.titles.count] : rows[index].title
                items.append(.chapter(HistoryChapterBlock(
                    id: "u\(serial)", startMs: start, endMs: end, zoneID: zoneID, source: untitled ? .conversation : .chapter,
                    title: untitled ? nil : title,
                    summary: untitled ? nil : Placeholder.summaries[index % Placeholder.summaries.count],
                    snippet: untitled ? Placeholder.quotes[index % Placeholder.quotes.count] : nil,
                    tags: untitled ? [] : Placeholder.tags[index % Placeholder.tags.count])))
            }
        }
        let day = HistoryDay(
            dateKey: key, zoneID: zoneID, isToday: false, hasRecordings: true,
            leadingEdge: items.first.map { HistoryEdge(atMs: $0.startMs, kind: .quiet) },
            items: items,
            trailingEdge: items.last.map { HistoryEdge(atMs: $0.endMs, kind: .quiet) })
        let cards = items.filter { if case .chapter = $0 { return true } else { return false } }.count
        return HistoryDayPage(
            day: day,
            brief: HistoryBrief(
                text: "Real conversation units (\(rows.count) in the file, \(cards) drawn as cards). Titles, summaries and tags are placeholders.",
                updatedAtMs: 0),
            followUpTotal: 0, followUpOpen: 0, topics: .ready)
    }

    /// Placeholder words for real units that have none yet. Not real content.
    enum Placeholder {
        static let titles = [
            "Coffee order and the morning plan", "Checking the deploy logs", "Rent and the second listing",
            "A call about the bank transfer", "Lunch options nearby", "Reviewing the battery numbers",
            "Plans for the weekend trip", "The landlord's reply", "Fixing the crash on older dates",
            "Groceries and dinner", "Board game rules", "Catching up with Simon",
        ]
        static let summaries = [
            "Going back and forth on what to do first, then settling on the order and who handles which part.",
            "Walking through what the numbers show and what still looks wrong, with a plan to check again later.",
            "Comparing the options, the costs of each, and what is still waiting on someone else.",
        ]
        static let quotes = [
            "Okay, let me just check this before we go.", "Did you see what they said about the price?",
            "Can you pass me the other one?", "I think it finished, let me look at the logs.",
            "We should leave in ten minutes if we want to make it.", "That's the one I was talking about.",
        ]
        static let tags = [["work"], ["apartment", "banking"], ["dining"], ["travel", "family"], ["work", "phone"], []]
    }
}
#endif
