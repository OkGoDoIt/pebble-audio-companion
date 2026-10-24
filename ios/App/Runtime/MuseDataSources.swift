import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import Receiver
import SearchKit
import SegmentStore
import Transcription

/// What Muse can reach in the app while answering a question from the watch (docs/privacy-model.md
/// D7a, D7b, D7d, D7e). Every call is one Muse made during a question the wearer asked, after
/// `MuseTools` has checked the source is allowed; nothing here decides permission.
final class AppMuseData: MuseDataProvider, @unchecked Sendable {
    private let composition: AppComposition

    init(composition: AppComposition) {
        self.composition = composition
    }

    // MARK: - Conversations

    func conversations(from: Date, to: Date, query: String?, characters: Int) async -> [MuseConversationText] {
        let library = composition.runtime.library
        let window = Int64(from.timeIntervalSince1970 * 1000)..<Int64(to.timeIntervalSince1970 * 1000)
        guard !window.isEmpty else { return [] }
        let hidden = await library.pendingDeleteConversationIds()
        var rows = ((try? await library.conversationRows(overlappingMs: window)) ?? [])
            .filter { !hidden.contains($0.id) && $0.hasSpeech }
        if let query, !query.isEmpty {
            let hits = (try? await composition.index.searchOffMain(
                query, limit: 40, kinds: [.conversation], within: Set(rows.map(\.id)), mode: .any)) ?? []
            let order = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1.id, $0) })
            rows = rows.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        }
        var budget = characters
        var out: [MuseConversationText] = []
        for row in rows where budget > 200 {
            guard let detail = try? await library.conversation(id: row.id) else { continue }
            let names = Dictionary(
                ((try? await composition.people.assignments(forConversation: row.id)) ?? []).map { ($0.label, $0.personName) },
                uniquingKeysWith: { first, _ in first })
            var text = transcriptLines(detail.pieces, names: names)
            if let query, !query.isEmpty { text = Self.passages(text, matching: query) }
            guard !text.isEmpty else { continue }
            if text.count > budget { text = String(text.prefix(budget)) + "…" }
            budget -= text.count
            out.append(MuseConversationText(
                start: Date(timeIntervalSince1970: Double(row.startMs) / 1000),
                end: Date(timeIntervalSince1970: Double(row.endMs) / 1000),
                title: row.title, text: text))
        }
        return out
    }

    /// One line per turn, "Name: words", the way the conversation screen reads.
    private func transcriptLines(_ members: [ConversationMember], names: [String: String]) -> String {
        members.compactMap { member -> String? in
            guard let piece = ConversationText.piece(member, of: composition.transcripts.loadWithoutWords(member.segmentId))
            else { return nil }
            if piece.segments.isEmpty { return piece.text.isEmpty ? nil : piece.text }
            return piece.segments.map { turn in
                guard let speaker = turn.speaker, !speaker.isEmpty else { return turn.text }
                let label = speakerLabel(speaker)
                return "\(names[label] ?? label): \(turn.text)"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The lines that mention any of the query's words, with one line either side.
    static func passages(_ text: String, matching query: String) -> String {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return text }
        let lines = text.components(separatedBy: "\n")
        var keep = Set<Int>()
        for (index, line) in lines.enumerated() where words.contains(where: { line.lowercased().contains($0) }) {
            keep.formUnion(max(0, index - 1)...min(lines.count - 1, index + 1))
        }
        guard !keep.isEmpty else { return "" }
        var out: [String] = []
        var last = -2
        for index in keep.sorted() {
            if index != last + 1, !out.isEmpty { out.append("…") }
            out.append(lines[index])
            last = index
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Ask

    func answerFromRecordings(_ question: String) async -> String? {
        do {
            let answer = try await Self.askOnMain(question).trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        } catch {
            AppRuntimeLog.shared.record("muse  ask from recordings failed: \(error)")
            return nil
        }
    }

    @MainActor
    private static func askOnMain(_ question: String) async throws -> String {
        try await AskLibraryDataSources.current.ask.ask(question: question, thread: nil, scope: .everything).answerText
    }

    // MARK: - Recaps

    func recap(day: Date, week: Bool) async -> String? {
        let dateKey = LogicalDay.dateKey(forMs: Int64(day.timeIntervalSince1970 * 1000), timeZoneID: TimeZone.current.identifier)
        if week {
            let first = HistoryCalendar.week(containing: dateKey, firstWeekday: Calendar.current.firstWeekday).lowerBound
            let key = PeriodBriefKey.week(firstDateKey: first)
            let briefs = (try? await PeriodBriefStore(db: composition.database).load(keys: [key])) ?? [:]
            return briefs[key]?.text
        }
        guard let recap = try? await composition.recapStore.load(dateKey: dateKey) else { return nil }
        let text = RecapCondenser.condensation(of: recap) ?? recap.text
        return text.isEmpty ? nil : text
    }

    // MARK: - Reminders kept in the app (`docs/reminders.md`)

    func reminderHome() async -> ReminderHome {
        await MainActor.run { RemindersComposition.preferences.current.value.home }
    }

    func appReminders(completedSince: Date?) async -> [MuseAppReminder] {
        let store = composition.followUps
        var rows = (try? await store.list(scope: .open)) ?? []
        if let completedSince {
            let since = Self.ms(completedSince)
            rows += ((try? await store.list(scope: .completed)) ?? []).filter { ($0.completedAtMs ?? 0) >= since }
        }
        return rows.map(Self.reminder)
    }

    func appReminder(id: String) async -> MuseAppReminder? {
        guard let row = try? await composition.followUps.load(id: id), row.stage == .reminder, !row.isArchived else {
            return nil
        }
        return Self.reminder(row)
    }

    /// Asked of an assistant: a reminder at once, never a suggestion.
    func addAppReminder(title: String, due: Date?) async -> MuseAppReminder? {
        let nowMs = Self.ms(Date())
        let item = FollowUp(
            id: UUID().uuidString.lowercased(), text: title, done: false, sourceConversationId: nil,
            sourceSegmentId: nil, createdAtMs: nowMs, dueAtMs: due.map(Self.startOfDayMs), origin: .assistant)
        guard (try? await composition.followUps.insertFromAssistant(item)) == true else { return nil }
        try? await composition.donator.donateFollowUp(id: item.id, text: item.text, createdAtMs: nowMs)
        return await appReminder(id: item.id)
    }

    func updateAppReminder(id: String, _ change: MuseEventKitSource.ReminderChange) async -> MuseAppReminder? {
        let store = composition.followUps
        guard await appReminder(id: id) != nil else { return nil }
        let nowMs = Self.ms(Date())
        do {
            if let title = change.title { try await store.setText(id: id, title, nowMs: nowMs) }
            switch change.due {
            case .set(let date, _)?: try await store.setDue(id: id, Self.startOfDayMs(date), nowMs: nowMs)
            case .clear?: try await store.setDue(id: id, nil, nowMs: nowMs)
            case nil: break
            }
            if let done = change.completed { try await store.setDone(id: id, done, nowMs: nowMs) }
        } catch {
            return nil
        }
        guard let row = try? await store.load(id: id) else { return nil }
        return Self.reminder(row)
    }

    /// Off the list, kept and findable: the app never erases what someone may have acted on.
    func fileAwayAppReminder(id: String) async -> MuseAppReminder? {
        guard let before = await appReminder(id: id) else { return nil }
        guard (try? await composition.followUps.setArchived(id: id, true, nowMs: Self.ms(Date()))) != nil else { return nil }
        return before
    }

    // MARK: - Follow-ups waiting for review

    func followUpsToReview(limit: Int) async -> [MuseFollowUp] {
        let rows = Array(((try? await composition.followUps.list(scope: .suggested)) ?? []).prefix(limit))
        let titles = (try? await ArchiveReadTitles.load(
            Array(Set(rows.compactMap(\.sourceConversationId))), in: composition.database)) ?? [:]
        return rows.map { row in
            MuseFollowUp(
                id: row.id, text: row.text, due: row.dueAtMs.map(Self.date),
                saidAt: Self.date(row.sourceWall?.startMs ?? row.createdAtMs),
                conversation: row.sourceConversationId.flatMap { titles[$0] },
                quote: row.quote, why: row.why)
        }
    }

    func decideFollowUp(id: String, remind: Bool) async -> MuseFollowUpDecision? {
        let store = composition.followUps
        guard let row = try? await store.load(id: id), row.stage == .suggested, !row.isArchived else { return nil }
        guard (try? await store.setStage(id: id, remind ? .reminder : .skipped, nowMs: Self.ms(Date()))) != nil else {
            return nil
        }
        let (home, listId, lists) = await MainActor.run {
            (
                RemindersComposition.preferences.current.value.home,
                RemindersComposition.preferences.current.value.appleListId,
                RemindersComposition.home?.lists() ?? []
            )
        }
        let apple = home == .apple
        let list = apple ? lists.first { $0.id == listId }?.title ?? RemindersHome.newListTitle : RemindersHome.newListTitle
        return MuseFollowUpDecision(
            id: id, title: row.text, keptInApple: apple, list: list, reminderID: !apple && remind ? "pa:\(id)" : nil)
    }

    private static func reminder(_ row: FollowUp) -> MuseAppReminder {
        MuseAppReminder(id: row.id, title: row.text, due: row.dueAtMs.map(date), done: row.done)
    }

    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    /// Reminders in the app are kept by the day, at its start.
    private static func startOfDayMs(_ date: Date) -> Int64 { ms(Calendar.current.startOfDay(for: date)) }

    // MARK: - Recording

    func pauseRecording(minutes: Int) async -> Bool {
        await MainActor.run {
            let settings = composition.settings
            guard settings.captureIntent == .active else { return false }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            settings.captureIntent = .paused
            settings.capturePause = minutes > 0
                ? CapturePauseSchedule(resumeAtMs: nowMs + Int64(minutes) * 60_000, remindAtMs: 0)
                : .none
            let runtime = composition.runtime
            Task { await runtime.applyExternalCaptureIntent(.paused, source: .intent) }
            CaptureController.reloadWidgetSurfaces()
            return true
        }
    }

    func resumeRecording() async -> Bool {
        await MainActor.run {
            let settings = composition.settings
            settings.captureIntent = .active
            settings.capturePause = .none
            let runtime = composition.runtime
            Task { await runtime.applyExternalCaptureIntent(.active, source: .intent) }
            CaptureController.reloadWidgetSurfaces()
            return true
        }
    }

    /// The same saved moment as the watch action. A label is a note, not a reminder request.
    func markMoment(_ label: String?) async -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (try? await MomentStore(db: composition.database).add(
            Moment(id: "muse-\(nowMs)", wallMs: nowMs, onAudioClock: false, origin: .muse,
                   createdAtMs: nowMs, note: String(trimmed.prefix(2_000))))) == true
    }
}
