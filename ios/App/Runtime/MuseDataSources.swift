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
        await conversationPage(from: from, to: to, query: query, offset: 0, limit: 20, characters: characters)?.items ?? []
    }

    func conversationPage(from: Date, to: Date, query: String?, offset: Int, limit: Int, characters: Int) async -> MuseConversationPage? {
        let library = composition.runtime.library
        let window = Self.ms(from)..<Self.ms(to)
        guard !window.isEmpty else { return MuseConversationPage(items: [], nextOffset: nil) }
        let hidden = await library.pendingDeleteConversationIds()
        guard let allRows = try? await library.conversationRows(overlappingMs: window) else { return nil }
        var rows = allRows.filter { !hidden.contains($0.id) && $0.hasSpeech }
        if let query, !query.isEmpty {
            guard let hits = try? await composition.index.searchOffMain(
                query, limit: max(1, rows.count), kinds: [.conversation], within: Set(rows.map(\.id)), mode: .any) else { return nil }
            let order = Dictionary(hits.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            rows = rows.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        }
        let page = rows.dropFirst(offset).prefix(limit)
        var out: [MuseConversationText] = []
        let perItem = max(1, characters / max(1, page.count))
        for row in page {
            guard var item = await conversationText(id: row.id, query: query, window: window) else { continue }
            item.truncated = item.text.count > perItem
            item = Self.portion(item, offset: 0, characters: perItem, isSearch: query != nil)
            out.append(item)
        }
        let next = offset + page.count
        return MuseConversationPage(items: out, nextOffset: next < rows.count ? next : nil)
    }

    func conversation(id: String, textOffset: Int, characters: Int) async -> MuseConversationText? {
        guard let item = await conversationText(id: id, query: nil, window: nil) else { return nil }
        return Self.portion(item, offset: textOffset, characters: characters, isSearch: false)
    }

    private func conversationText(id: String, query: String?, window: Range<Int64>?) async -> MuseConversationText? {
        let library = composition.runtime.library
        guard !(await library.pendingDeleteConversationIds()).contains(id),
              let detail = try? await library.conversation(id: id),
              let identity = try? await SpeakerCorrectionStore(db: composition.database)
                .snapshot(segmentIds: detail.pieces.map(\.segmentId)) else { return nil }
        let assignments = (try? await composition.people.assignments(forConversation: id)) ?? []
        let transcript = await transcriptLines(detail.pieces, assignments: assignments, identity: identity, window: window)
        var text = transcript.text
        if let query, !query.isEmpty { text = Self.passages(text, matching: query) }
        var item = MuseConversationText(start: Self.date(detail.row.startMs), end: Self.date(detail.row.endMs),
            title: detail.row.title, text: text)
        item.id = id; item.processingState = detail.row.lifecycle.rawValue; item.isLive = detail.row.isLive
        item.link = Route.conversation(id: id, atMs: nil).url.absoluteString
        item.textScope = window == nil ? "conversation" : query == nil ? "turns_starting_in_range" : "matching_passages_in_range"
        item.timingIncomplete = transcript.timingIncomplete
        return item
    }

    private static func portion(_ item: MuseConversationText, offset: Int, characters: Int, isSearch: Bool) -> MuseConversationText {
        let text = String(item.text.dropFirst(offset).prefix(characters))
        var result = MuseConversationText(start: item.start, end: item.end, title: item.title, text: text)
        result.id = item.id; result.link = item.link; result.textScope = item.textScope
        result.processingState = item.processingState; result.isLive = item.isLive
        result.timingIncomplete = item.timingIncomplete
        result.textOffset = offset
        result.truncated = offset + text.count < item.text.count
        // Search snippets are not offsets into a full transcript. Get starts at zero.
        result.nextTextOffset = !isSearch && result.truncated ? offset + text.count : nil
        return result
    }

    /// One line per turn, "Name: words", the way the conversation screen reads.
    private func transcriptLines(
        _ members: [ConversationMember], assignments: [SpeakerAssignment], identity: SpeakerIdentitySnapshot,
        window: Range<Int64>?
    ) async -> (text: String, timingIncomplete: Bool) {
        var lines: [String] = [], timingIncomplete = false
        for member in members {
            guard var piece = ConversationText.piece(member, of: composition.transcripts.load(member.segmentId)) else { continue }
            if let window {
                guard let meta = await composition.store.readMeta(member.segmentId) else {
                    timingIncomplete = true; continue
                }
                let clipped = Self.transcriptInWindow(piece, member: member, meta: meta, window: window)
                piece = clipped.transcript; timingIncomplete = timingIncomplete || clipped.timingIncomplete
            }
            if piece.segments.isEmpty {
                if !piece.text.isEmpty { lines.append(piece.text) }
            } else {
                lines.append(SpeakerAttribution.promptText(transcript: piece, identity: identity,
                                                          legacyAssignments: assignments))
            }
        }
        return (lines.joined(separator: "\n"), timingIncomplete)
    }

    /// Apply the requested wall-time window after conversation ownership, using the segment's
    /// gap-aware clock. Untimed text is included only when its entire piece is inside the range.
    static func transcriptInWindow(_ piece: SegmentTranscript, member: ConversationMember,
                                   meta: SegmentMeta, window: Range<Int64>) -> (transcript: SegmentTranscript, timingIncomplete: Bool) {
        let clock = SegmentMediaClock(meta)
        var copy = piece
        if piece.segments.isEmpty {
            let range = member.mediaRange(mediaSpanMs: clock.mediaSpanMs)
            let start = clock.startWallMs + clock.wallOffset(ofMedia: range.lowerBound)
            let end = clock.startWallMs + clock.wallOffset(ofMedia: range.upperBound)
            if start >= window.lowerBound && end <= window.upperBound { return (copy, false) }
            copy.text = ""; copy.words = []
            return (copy, !piece.text.isEmpty)
        }
        copy.segments = piece.segments.filter { window.contains(clock.startWallMs + clock.wallOffset(ofMedia: $0.startMs)) }
        copy.words = piece.words.filter { window.contains(clock.startWallMs + clock.wallOffset(ofMedia: $0.startMs)) }
        copy.text = copy.segments.map(\.text).joined(separator: " ")
        return (copy, !clock.isExact)
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
        await followUpPage(scope: "review", offset: 0, limit: limit) ?? []
    }

    func followUpPage(scope: String, offset: Int, limit: Int) async -> [MuseFollowUp]? {
        guard let all = try? await composition.followUps.list(scope: scope == "review" ? .suggested : .all) else { return nil }
        let filtered = all.filter { row in
            row.origin == .ai && !row.isArchived && (scope == "review" ? row.stage == .suggested :
                scope == "skipped" ? row.stage == .skipped : row.stage != .suggested)
        }.sorted {
            let a = $0.sourceWall?.startMs ?? $0.createdAtMs, b = $1.sourceWall?.startMs ?? $1.createdAtMs
            return a == b ? $0.id < $1.id : a < b
        }
        let rows = Array(filtered.dropFirst(offset).prefix(limit))
        let titles = (try? await ArchiveReadTitles.load(
            Array(Set(rows.compactMap(\.sourceConversationId))), in: composition.database)) ?? [:]
        return rows.map { row in
            var item = MuseFollowUp(id: row.id, text: row.text, due: row.dueAtMs.map(Self.date),
                saidAt: Self.date(row.sourceWall?.startMs ?? row.createdAtMs),
                conversation: row.sourceConversationId.flatMap { titles[$0] }, quote: row.quote, why: row.why)
            item.stage = row.stage.rawValue; item.priority = row.priority.rawValue
            return item
        }
    }

    func decideFollowUp(id: String, remind: Bool) async -> MuseFollowUpDecision? {
        await changeFollowUp(id: id, action: remind ? "remind" : "skip", edit: MuseFollowUpEdit())
    }

    func changeFollowUp(id: String, action: String, edit: MuseFollowUpEdit) async -> MuseFollowUpDecision? {
        let store = composition.followUps
        let (home, defaultList, lists, sync) = await MainActor.run {
            (RemindersComposition.preferences.current.value.home,
             RemindersComposition.preferences.current.value.appleListId,
             RemindersComposition.home?.lists() ?? [], RemindersComposition.home)
        }
        if let selected = edit.listID {
            guard action == "remind", home == .apple, lists.contains(where: { $0.id == selected }) else { return nil }
        }
        let target: FollowUpStage = action == "remind" ? .reminder : action == "skip" ? .skipped : .suggested
        let dueMs: Int64?
        switch edit.due {
        case .set(let date, _)?: dueMs = Self.startOfDayMs(date)
        default: dueMs = nil
        }
        do {
            guard try await store.reviewFromAssistant(id: id, stage: target, title: edit.title,
                dueAtMs: dueMs, setDue: edit.due != nil, priority: edit.priority.flatMap(FollowUpPriority.init),
                appleListId: action == "remind" && home == .apple ? edit.listID ?? defaultList : nil,
                reopen: action == "reopen", nowMs: Self.ms(Date())) else { return nil }
        } catch { return nil }
        // Wait for a real sync pass, then read the durable mapping. An offline or already
        // running pass remains pending; it is never reported as a delivered Apple reminder.
        await sync?.sync()
        guard let row = try? await store.load(id: id) else { return nil }
        let delivered = row.appleId != nil && row.stage == .reminder
        var result = MuseFollowUpDecision(id: id, title: row.text, keptInApple: delivered,
            list: delivered ? lists.first { $0.id == row.appleListId }?.title ?? RemindersHome.newListTitle : RemindersHome.newListTitle,
            reminderID: row.stage == .reminder ? (row.appleId ?? (home == .app ? "pa:\(id)" : nil)) : nil)
        result.stage = row.stage.rawValue; result.due = row.dueAtMs.map(Self.date)
        result.deliveryPending = row.stage == .reminder ? home == .apple && !delivered : row.appleId != nil
        return result
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
        let canPause = await MainActor.run {
            let settings = composition.settings
            guard settings.captureIntent != .off else { return false }
            let nowMs = Self.ms(Date())
            settings.captureIntent = .paused
            settings.capturePause = minutes > 0
                ? CapturePauseSchedule(resumeAtMs: nowMs + Int64(minutes) * 60_000, remindAtMs: 0) : .none
            CaptureController.reloadWidgetSurfaces()
            return true
        }
        guard canPause else { return false }
        await composition.runtime.applyExternalCaptureIntent(.paused, source: .intent)
        return true
    }

    func resumeRecording() async -> Bool {
        await MainActor.run {
            composition.settings.captureIntent = .active
            composition.settings.capturePause = .none
            CaptureController.reloadWidgetSurfaces()
        }
        await composition.runtime.applyExternalCaptureIntent(.active, source: .intent)
        return true
    }

    func recordingStatus() async -> MuseRecordingSnapshot? {
        let now = Date(), nowMs = Self.ms(Date())
        let receiver = composition.receiver
        let state = receiver.state.value
        let evidence = receiver.streamEvidence.value
        let connected: Bool
        let connection: String
        switch state {
        case .disconnected: connected = false; connection = "disconnected"
        case .connecting: connected = false; connection = "connecting"
        case .connectionFailed: connected = false; connection = "connection_failed"
        case .authorizing: connected = true; connection = "authorizing"
        case .pendingConsent: connected = true; connection = "watch_consent_needed"
        case .pendingEnable: connected = true; connection = "watch_enable_needed"
        case .denied: connected = true; connection = "authorization_denied"
        case .authorized: connected = true; connection = "authorized"
        case .streaming: connected = true; connection = "authorized"
        case .revoked: connected = false; connection = "authorization_revoked"
        }
        let verdict = evidence.verdict(nowMs: nowMs)
        let reportIsFresh = evidence.lastWatchReportAtMs.map {
            nowMs >= $0 && nowMs - $0 <= StreamEvidence.reportMaxAgeMs
        } ?? false
        let recording: Bool? = !connected ? nil :
            reportIsFresh ? evidence.lastWatchReportRaw.map { $0 == 3 } :
            state.isStreaming && verdict.supportsRecording ? true : nil
        let (intent, resumeAt) = await MainActor.run {
            (composition.settings.captureIntent, composition.settings.capturePause.resumeAtMs)
        }
        let names = ["disabled", "idle", "authorized_idle", "streaming", "microphone_busy",
                     "paused_by_policy", "low_battery", "error", "power_save"]
        let watchState = evidence.lastWatchReportRaw.flatMap { names.indices.contains($0) ? names[$0] : nil }
        return MuseRecordingSnapshot(intent: intent == .active ? "active" : intent == .paused ? "paused" : "off",
            connection: connection, recording: recording, watchState: watchState,
            pausedUntil: intent == .paused && resumeAt > 0 ? Self.date(resumeAt) : nil,
            lastAudioAt: evidence.lastAudioAtMs.map(Self.date),
            lastWatchReportAt: evidence.lastWatchReportAtMs.map(Self.date), observedAt: now)
    }

    func markMoment(_ label: String?) async -> Bool { await saveMoment(label) != nil }

    func saveMoment(_ note: String?) async -> MuseMoment? {
        let nowMs = Self.ms(Date())
        let status = await recordingStatus()
        let item = Moment(id: "muse-" + UUID().uuidString.lowercased(), wallMs: nowMs,
            onAudioClock: false, origin: .muse, createdAtMs: nowMs,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", wasRecording: status?.recording)
        guard (try? await MomentStore(db: composition.database).add(item)) == true else { return nil }
        return Self.momentSnapshot(item)
    }

    func moments(offset: Int, limit: Int) async -> [MuseMoment]? {
        guard let rows = try? await MomentStore(db: composition.database).page(offset: offset, limit: limit) else { return nil }
        return rows.map(Self.momentSnapshot)
    }

    func moment(id: String, includeContext: Bool) async -> MuseMoment? {
        guard let row = try? await MomentStore(db: composition.database).load(id: id) else { return nil }
        var result = Self.momentSnapshot(row)
        if includeContext, let context = try? await LiveMoments(composition: composition).context(for: row) {
            result.contextStatus = context.status
            result.quote = context.quote.isEmpty ? nil : context.quote
            if let target = context.target {
                result.link = Route.conversation(id: target.conversationId, atMs: row.wallMs, focus: target.focus).url.absoluteString
            }
        }
        return result
    }

    func editMoment(id: String, note: String) async -> MuseMoment? {
        let store = MomentStore(db: composition.database)
        guard (try? await store.load(id: id)) != nil else { return nil }
        do { try await store.setNote(id: id, note: note) } catch { return nil }
        return await moment(id: id, includeContext: false)
    }

    func deleteMoment(id: String) async -> Bool {
        let store = MomentStore(db: composition.database)
        guard (try? await store.load(id: id)) != nil else { return false }
        do {
            try await store.delete(id: id)
            return try await store.load(id: id) == nil
        } catch { return false }
    }

    private static func momentSnapshot(_ item: Moment) -> MuseMoment {
        MuseMoment(id: item.id, at: Self.date(item.wallMs), note: item.note, wasRecording: item.wasRecording)
    }
}
