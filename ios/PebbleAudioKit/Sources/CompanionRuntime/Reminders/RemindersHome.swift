import AppDB
import Foundation
import GRDB
import Receiver

// Where reminders are kept, and keeping them there (`docs/reminders.md`).
//
// In the app, a reminder is a row and nothing more, plus a local alert on its due date. In Apple
// Reminders, every open reminder is also an Apple reminder the app made, followed both ways by
// its `calendarItemIdentifier` whatever list the person has since put it in: a tick, a new
// title, a new date or a delete on either side reaches the other. Which side wins a disagreement
// is whichever changed last.
//
// Everything here is content-gated: a pass that finds both sides already agreeing writes
// nothing, on either side, so the change notifications its own writes cause come back as
// no-ops instead of a loop.

public actor RemindersHome {
    /// The list made for reminders when the person doesn't pick one of their own.
    public static let newListTitle = "Pebble Audio"
    /// The most due-date alerts kept scheduled in the app (iOS keeps 64 per app).
    static let maxDueAlerts = 50
    static let dueAlertPrefix = "reminder-due-"
    static let eveningPrefix = "reminder-evening-"

    /// Where reminders go when the home becomes Apple Reminders, or the list changes.
    public enum ListChoice: Equatable, Sendable {
        /// A new list called `newListTitle`.
        case newList
        case existing(id: String)
    }

    public enum AccessState: Equatable, Sendable {
        case notAsked
        case allowed
        /// Turned off in iOS; only Settings can change it.
        case refused
    }

    private let followUps: FollowUpStore
    private let apple: AppleRemindersAccess
    private let alerts: ReminderAlertScheduling
    public nonisolated let preferences: ReminderPreferencesStore
    private let nowMs: @Sendable () -> Int64
    private let log: (@Sendable (String) -> Void)?
    private var observers: [AnyObject] = []
    private var pending: Task<Void, Never>?

    public init(
        followUps: FollowUpStore, apple: AppleRemindersAccess, alerts: ReminderAlertScheduling,
        preferences: ReminderPreferencesStore,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.followUps = followUps
        self.apple = apple
        self.alerts = alerts
        self.preferences = preferences
        self.nowMs = nowMs
        self.log = log
    }

    // MARK: - What Settings › Reminders shows

    public nonisolated var access: AccessState {
        apple.authorized ? .allowed : apple.refused ? .refused : .notAsked
    }

    /// Asks iOS for Reminders access. Only when the person picked Apple Reminders.
    public func requestAccess() async -> Bool { await apple.requestAccess() }

    /// The person's lists, for the picker.
    public nonisolated func lists() -> [AppleReminderList] { apple.lists().filter(\.writable) }

    /// Open reminders, wherever they are kept: what a switch of home would move.
    public func openReminderCount() async -> Int {
        (try? await openReminders().count) ?? 0
    }

    /// Open reminders the app keeps in Apple list `listId`: what a change of list would move.
    /// Ones the person moved to another list themselves are theirs, and not counted.
    public func openCount(inList listId: String) async -> Int {
        (try? await openReminders().filter { $0.appleListId == listId }.count) ?? 0
    }

    // MARK: - Changing home

    /// Makes Apple Reminders the home, every open reminder moving to `choice`. Returns how many
    /// moved. Needs Reminders access first.
    @discardableResult
    public func switchToApple(_ choice: ListChoice) async throws -> Int {
        guard apple.authorized else { throw CocoaError(.userCancelled) }
        let listId = try resolve(choice)
        preferences.update {
            $0.home = .apple
            $0.appleListId = listId
        }
        let moved = try await pushMissing(listId: listId)
        await clearDueAlerts()
        log?("reminders: kept in Apple Reminders now; \(moved) moved")
        return moved
    }

    /// Makes the app the home again. Open reminders come back: the Apple ones the app made are
    /// removed from Apple Reminders. Returns how many.
    @discardableResult
    public func switchToApp() async throws -> Int {
        var brought = 0
        for item in try await openReminders() where item.appleId != nil {
            if let id = item.appleId { try? apple.delete(id: id) }
            try await followUps.setApple(id: item.id, appleId: nil, listId: nil)
            brought += 1
        }
        preferences.update { $0.home = .app }
        await sync()
        log?("reminders: kept in Pebble Audio now; \(brought) brought back")
        return brought
    }

    /// New reminders go to `choice` from now on; with `moveOpen`, the open ones in the old list
    /// go too. Returns how many moved.
    @discardableResult
    public func changeList(_ choice: ListChoice, moveOpen: Bool) async throws -> Int {
        let old = preferences.current.value.appleListId
        let listId = try resolve(choice)
        preferences.update { $0.appleListId = listId }
        guard moveOpen, let old, old != listId else { return 0 }
        var moved = 0
        for item in try await openReminders() where item.appleListId == old {
            guard let appleId = item.appleId, let now = try apple.move(id: appleId, toList: listId)
            else { continue }
            try await followUps.setApple(id: item.id, appleId: now.id, listId: now.listId)
            moved += 1
        }
        log?("reminders: \(moved) moved to another list")
        return moved
    }

    // MARK: - Keeping both sides in step

    /// Starts following the follow-ups table, Apple Reminders and the preferences.
    public func start(database: AppDatabase) {
        guard observers.isEmpty else { return }
        let home = self
        observers.append(
            apple.observeChanges { Task { await home.scheduleSync() } })
        // A cheap fingerprint of everything a reminder's sync depends on: it changes only when a
        // follow-up does, so the table's other writes (wall-time fills, model ids) wake nothing.
        let fingerprint = ValueObservation.tracking { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*), SUM(done), MAX(touchedAtMs), MAX(editedAtMs),
                           MAX(completedAtMs), MAX(decidedAtMs), MAX(archivedAtMs),
                           MAX(createdAtMs), SUM(stage = 'reminder'), SUM(dueAtMs)
                    FROM follow_ups
                    """)?.description ?? ""
        }.removeDuplicates()
        let task = Task {
            do {
                for try await _ in fingerprint.values(in: database.reader) {
                    await home.scheduleSync()
                }
            } catch {}
        }
        observers.append(TaskBox(task))
        let preferencesTask = Task {
            for await _ in preferences.current.stream() { await home.scheduleSync() }
        }
        observers.append(TaskBox(preferencesTask))
    }

    /// Coalesces a burst of changes into one pass.
    private func scheduleSync() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// One pass: Apple Reminders brought into step when it is the home, and the app's own
    /// alerts scheduled.
    public func sync() async {
        do {
            let prefs = preferences.current.value
            if prefs.home == .apple, apple.authorized {
                try await reconcileApple(prefs)
            } else {
                await scheduleDueAlerts(prefs)
            }
            await scheduleEveningReview(prefs)
        } catch {
            log?("reminders: sync failed: \(error)")
        }
    }

    /// Notifications may need iOS's permission: asked when the person did something that wants
    /// them (made a dated reminder, or turned on the evening review).
    public func askForAlertPermissionIfNeeded() async {
        _ = await alerts.requestPermission()
        await sync()
    }

    private func reconcileApple(_ prefs: ReminderPreferences) async throws {
        let listId = try prefs.appleListId.flatMap { id in
            apple.lists().contains { $0.id == id } ? id : nil
        } ?? resolve(.newList)
        if listId != prefs.appleListId { preferences.update { $0.appleListId = listId } }
        try await pushMissing(listId: listId)

        let rows = try await followUps.list(scope: .all).filter { $0.appleId != nil }
        let onApple = Dictionary(
            apple.reminders(ids: rows.compactMap(\.appleId)).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        let now = nowMs()
        for row in rows {
            guard let appleId = row.appleId else { continue }
            // Off the list in the app: skipped, filed away, or no longer a reminder.
            if row.stage != .reminder || row.archivedAtMs != nil {
                try? apple.delete(id: appleId)
                try await followUps.setApple(id: row.id, appleId: nil, listId: nil)
                continue
            }
            guard let theirs = onApple[appleId] else {
                // Deleted in Apple Reminders: it leaves the list here too, filed away, findable.
                try await followUps.setArchived(id: row.id, true, nowMs: now)
                try await followUps.setApple(id: row.id, appleId: nil, listId: nil)
                log?("reminders: one was deleted in Apple Reminders")
                continue
            }
            if theirs.listId != row.appleListId {
                try await followUps.setApple(id: row.id, appleId: appleId, listId: theirs.listId)
            }
            guard !Self.agree(row, theirs) else { continue }
            if Self.changedAt(row) > theirs.modifiedAtMs {
                _ = try apple.update(id: appleId, to: draft(row, prefs))
            } else {
                try await take(theirs, into: row, now: now)
            }
        }
    }

    /// Open reminders with no Apple reminder yet get one in `listId`. Returns how many.
    @discardableResult
    private func pushMissing(listId: String) async throws -> Int {
        let prefs = preferences.current.value
        var made = 0
        for item in try await openReminders() where item.appleId == nil {
            let created = try apple.create(draft(item, prefs), inList: listId)
            try await followUps.setApple(id: item.id, appleId: created.id, listId: created.listId)
            made += 1
        }
        return made
    }

    private func take(_ theirs: AppleReminder, into row: FollowUp, now: Int64) async throws {
        if theirs.done != row.done { try await followUps.setDone(id: row.id, theirs.done, nowMs: now) }
        let title = theirs.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != row.text {
            try await followUps.setText(id: row.id, title, nowMs: now)
        }
        if !Self.sameDay(theirs.dueAtMs, row.dueAtMs) {
            try await followUps.setDue(id: row.id, theirs.dueAtMs.map(Self.startOfDay), nowMs: now)
        }
    }

    private func resolve(_ choice: ListChoice) throws -> String {
        switch choice {
        case .existing(let id): return id
        case .newList:
            if let existing = apple.lists().first(where: { $0.title == Self.newListTitle }) {
                return existing.id
            }
            return try apple.makeList(title: Self.newListTitle)
        }
    }

    private func openReminders() async throws -> [FollowUp] {
        try await followUps.list(scope: .open, nowMs: nowMs())
    }

    private nonisolated func draft(_ item: FollowUp, _ prefs: ReminderPreferences) -> AppleReminderDraft {
        AppleReminderDraft(
            title: item.text,
            notes: item.quote.map { "“\($0)”" },
            url: URL(string: "companion://followup?id=\(item.id)"),
            dueAtMs: item.dueAtMs,
            alarmAtMs: prefs.dueAlerts ? item.dueAtMs.map { Self.alertTime($0, prefs) } : nil,
            done: item.done)
    }

    // MARK: - Alerts kept by the app

    private func scheduleDueAlerts(_ prefs: ReminderPreferences) async {
        guard prefs.home == .app, prefs.dueAlerts, await alerts.allowed() else {
            await clearDueAlerts()
            return
        }
        let now = nowMs()
        let items = (try? await openReminders()) ?? []
        var wanted: [String: (FollowUp, Int64)] = [:]
        for item in items {
            guard let due = item.dueAtMs, !item.isSnoozed(at: now) else { continue }
            let fire = Self.alertTime(due, prefs)
            guard fire > now else { continue }
            wanted["\(Self.dueAlertPrefix)\(item.id)-\(fire)-\(item.text.hashValue)"] = (item, fire)
        }
        let kept = wanted.sorted { $0.value.1 < $1.value.1 }.prefix(Self.maxDueAlerts)
        let keep = Set(kept.map(\.key))
        let have = await alerts.pending(prefix: Self.dueAlertPrefix)
        await alerts.remove(ids: Array(have.subtracting(keep)))
        for (id, (item, fire)) in kept where !have.contains(id) {
            await alerts.schedule(
                id: id, title: item.text, body: "Due today",
                at: Date(timeIntervalSince1970: Double(fire) / 1000), route: "reminders")
        }
    }

    private func clearDueAlerts() async {
        await alerts.remove(ids: Array(await alerts.pending(prefix: Self.dueAlertPrefix)))
    }

    /// One notification at the evening time, saying what there is: follow-ups to review, and
    /// reminders added today. None when there is neither.
    private func scheduleEveningReview(_ prefs: ReminderPreferences) async {
        let have = await alerts.pending(prefix: Self.eveningPrefix)
        guard prefs.eveningReview, await alerts.allowed() else {
            await alerts.remove(ids: Array(have))
            return
        }
        let now = nowMs()
        var fire = Self.startOfDay(now) + Int64(prefs.eveningReviewMinutes) * 60_000
        if fire <= now { fire += 86_400_000 }
        let toReview = (try? await followUps.suggestedCount()) ?? 0
        let added = (try? await followUps.decided(fromMs: Self.startOfDay(fire), toMs: fire)
            .filter { $0.stage == .reminder }.count) ?? 0
        guard let title = Self.eveningTitle(toReview: toReview, added: added) else {
            await alerts.remove(ids: Array(have))
            return
        }
        let body = Self.eveningBody(toReview: toReview, added: added)
        let id = "\(Self.eveningPrefix)\(fire)-\(toReview)-\(added)"
        guard !have.contains(id) else { return }
        await alerts.remove(ids: Array(have))
        await alerts.schedule(
            id: id, title: title, body: body, at: Date(timeIntervalSince1970: Double(fire) / 1000),
            route: toReview > 0 ? "review" : "reminders")
    }

    static func eveningTitle(toReview: Int, added: Int) -> String? {
        if toReview > 0 { return toReview == 1 ? "1 follow-up to review" : "\(toReview) follow-ups to review" }
        if added > 0 { return added == 1 ? "1 reminder added today" : "\(added) reminders added today" }
        return nil
    }

    static func eveningBody(toReview: Int, added: Int) -> String {
        guard toReview > 0, added > 0 else { return "From today's conversations." }
        return added == 1 ? "1 reminder added from today." : "\(added) reminders added from today."
    }

    // MARK: - Time

    static func alertTime(_ dueAtMs: Int64, _ prefs: ReminderPreferences) -> Int64 {
        startOfDay(dueAtMs) + Int64(prefs.dueAlertMinutes) * 60_000
    }

    static func startOfDay(_ ms: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }

    static func sameDay(_ a: Int64?, _ b: Int64?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return startOfDay(a) == startOfDay(b)
        default: return false
        }
    }

    static func agree(_ row: FollowUp, _ theirs: AppleReminder) -> Bool {
        row.done == theirs.done && row.text == theirs.title && sameDay(row.dueAtMs, theirs.dueAtMs)
    }

    /// The last time anything the sync carries changed on the app's side.
    static func changedAt(_ row: FollowUp) -> Int64 {
        [row.touchedAtMs, row.editedAtMs, row.completedAtMs, row.decidedAtMs, row.createdAtMs]
            .compactMap { $0 }.max() ?? 0
    }
}

/// Keeps a task alive as long as its owner, and cancels it after.
private final class TaskBox {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}
