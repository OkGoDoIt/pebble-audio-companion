import CompanionRuntime
import Receiver
import Foundation

/// Where reminders are kept, as Settings › Reminders and the Reminders tab see it
/// (`docs/reminders.md`). `LiveReminderHome` is `RemindersHome` itself; `DemoReminderHome` stands
/// in for previews and `-demo-data`, where asking iOS for Reminders access would be wrong.
@MainActor
protocol ReminderHomeSource: AnyObject {
    var preferences: ReminderPreferences { get }
    /// Emits the preferences now and after every change, whoever made it.
    func preferenceUpdates() -> AsyncStream<ReminderPreferences>
    func update(_ change: (inout ReminderPreferences) -> Void)

    var access: RemindersHome.AccessState { get }
    func requestAccess() async -> Bool
    /// The person's lists they can add to.
    func lists() -> [AppleReminderList]
    func openReminderCount() async -> Int
    func openCount(inList listId: String) async -> Int
    func switchToApple(_ choice: RemindersHome.ListChoice) async throws -> Int
    func switchToApp() async throws -> Int
    func changeList(_ choice: RemindersHome.ListChoice, moveOpen: Bool) async throws -> Int
    func askForAlertPermissionIfNeeded() async
}

@MainActor
enum ReminderHomeSources {
    /// Built at first use: the live one once the composition is installed, the demo one in
    /// previews and `-demo-data`.
    static var current: any ReminderHomeSource {
        if let made { return made }
        let source: any ReminderHomeSource
        if !AppComposition.usesDemoData, let home = RemindersComposition.home {
            source = LiveReminderHome(home: home)
        } else {
            source = DemoReminderHome()
        }
        made = source
        return source
    }

    private static var made: (any ReminderHomeSource)?
}

// MARK: - Live

@MainActor
final class LiveReminderHome: ReminderHomeSource {
    private let home: RemindersHome

    init(home: RemindersHome) { self.home = home }

    var preferences: ReminderPreferences { home.preferences.current.value }

    func preferenceUpdates() -> AsyncStream<ReminderPreferences> {
        let subject = home.preferences.current
        return AsyncStream { continuation in
            let task = Task {
                for await value in subject.stream() { continuation.yield(value) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func update(_ change: (inout ReminderPreferences) -> Void) { home.preferences.update(change) }

    var access: RemindersHome.AccessState { home.access }
    func requestAccess() async -> Bool { await home.requestAccess() }
    func lists() -> [AppleReminderList] { home.lists() }
    func openReminderCount() async -> Int { await home.openReminderCount() }
    func openCount(inList listId: String) async -> Int { await home.openCount(inList: listId) }

    func switchToApple(_ choice: RemindersHome.ListChoice) async throws -> Int {
        try await home.switchToApple(choice)
    }

    func switchToApp() async throws -> Int { try await home.switchToApp() }

    func changeList(_ choice: RemindersHome.ListChoice, moveOpen: Bool) async throws -> Int {
        try await home.changeList(choice, moveOpen: moveOpen)
    }

    func askForAlertPermissionIfNeeded() async { await home.askForAlertPermissionIfNeeded() }
}

// MARK: - Demo

/// Previews and `-demo-data`: a Reminders app with a few lists, access granted on asking, and
/// the review day's open reminders to move. `-remindersHome apple` starts it in Apple Reminders;
/// `-remindersAccess refused` has iOS say no.
@MainActor
final class DemoReminderHome: ReminderHomeSource {
    private(set) var preferences = ReminderPreferences()
    private var continuations: [UUID: AsyncStream<ReminderPreferences>.Continuation] = [:]
    private var demoLists = [
        AppleReminderList(
            id: "list-reminders", title: "Reminders", colorHex: "#007AFF", isDefault: true,
            writable: true),
        AppleReminderList(
            id: "list-groceries", title: "Groceries", colorHex: "#FF9500", isDefault: false,
            writable: true),
        AppleReminderList(
            id: "list-family", title: "Family", colorHex: "#34C759", isDefault: false,
            writable: true),
    ]
    private(set) var access: RemindersHome.AccessState = .notAsked

    init() {
        #if DEBUG
        if let flag = UserDefaults.standard.string(forKey: "remindersHome"), flag == "apple" {
            access = .allowed
            demoLists.insert(
                AppleReminderList(
                    id: "list-pebble", title: RemindersHome.newListTitle, colorHex: "#5B5BD6",
                    isDefault: false, writable: true), at: 0)
            preferences.home = .apple
            preferences.appleListId = "list-pebble"
        }
        #endif
    }

    func preferenceUpdates() -> AsyncStream<ReminderPreferences> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(preferences)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func update(_ change: (inout ReminderPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        for continuation in continuations.values { continuation.yield(next) }
    }

    func requestAccess() async -> Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "remindersAccess") == "refused" {
            access = .refused
            return false
        }
        #endif
        access = .allowed
        return true
    }

    func lists() -> [AppleReminderList] { access == .allowed ? demoLists : [] }

    private var open: Int {
        get async {
            (try? await AskLibraryDataSources.current.followUps.items(scope: .open).count) ?? 0
        }
    }

    func openReminderCount() async -> Int { await open }

    func openCount(inList listId: String) async -> Int {
        preferences.home == .apple && preferences.appleListId == listId ? await open : 0
    }

    func switchToApple(_ choice: RemindersHome.ListChoice) async throws -> Int {
        let id = resolve(choice)
        let moved = await open
        update {
            $0.home = .apple
            $0.appleListId = id
        }
        return moved
    }

    func switchToApp() async throws -> Int {
        let brought = await open
        update { $0.home = .app }
        return brought
    }

    func changeList(_ choice: RemindersHome.ListChoice, moveOpen: Bool) async throws -> Int {
        let id = resolve(choice)
        let moved = moveOpen ? await open : 0
        update { $0.appleListId = id }
        return moved
    }

    func askForAlertPermissionIfNeeded() async {}

    private func resolve(_ choice: RemindersHome.ListChoice) -> String {
        switch choice {
        case .existing(let id): return id
        case .newList:
            if let existing = demoLists.first(where: { $0.title == RemindersHome.newListTitle }) {
                return existing.id
            }
            let made = AppleReminderList(
                id: "list-pebble", title: RemindersHome.newListTitle, colorHex: "#5B5BD6",
                isDefault: false, writable: true)
            demoLists.insert(made, at: 0)
            return made.id
        }
    }
}
