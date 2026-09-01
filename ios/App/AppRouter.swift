import Observation

/// Central navigation coordinator. Tabs + per-tab paths + sheet presentation, driven by
/// `Route` values so every screen stays deep-linkable (Part 6.8).
///
/// Lives in its own file rather than beside `@main`: `PebbleAudioApp.swift` cannot be compiled
/// into the `AppTests` bundle (a test bundle has no entry point), and the router is exactly the
/// kind of logic that has to be tested.
@Observable
final class AppRouter {
    enum Tab: Hashable { case today, library, followUps, ask, settings }

    var selectedTab: Tab = .today
    var todayPath: [Route] = []
    var libraryPath: [Route] = []
    var followUpsPath: [Route] = []
    var askPath: [Route] = []
    var settingsPath: [Route] = []
    var pendingSearchQuery: String?
    /// Tag filter carried by `companion://library?tag=` — read exactly once, by
    /// `consumePendingLibraryTag()`. It used to be written here and read by nothing, so
    /// `companion://library?tag=travel` opened the unfiltered Library and dropped the filter
    /// with no sign anywhere that it had been asked for.
    var pendingLibraryTag: String?
    /// An `.ask(scope:query:)` waiting for the Ask screen to pick it up.
    ///
    /// Ask is a tab now rather than a sheet, so its view model outlives any one link. Without
    /// somewhere to leave the request, the second "Ask about this conversation" of a session
    /// would open a screen still scoped to the first — the tab was already on screen, so
    /// nothing would re-read the route. Read exactly once, by `consumePendingAsk()`.
    var pendingAsk: Route?
    /// Which slice `companion://followups?scope=` asked for, read once by the list.
    var pendingFollowUpScope: String?

    /// Pushes onto the stack of the tab the user is actually in, so a screen reached from
    /// Today keeps pushing inside Today (hard-coding `libraryPath` pushed a note nobody could
    /// see, and quietly rewrote the Library stack behind the user's back).
    func push(_ route: Route) {
        switch selectedTab {
        case .today: todayPath.append(route)
        case .library: libraryPath.append(route)
        case .followUps: followUpsPath.append(route)
        case .ask: askPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func navigate(to route: Route) {
        switch route {
        case .today, .live:
            selectedTab = .today
            todayPath = route == .live ? [.live] : []
        case .conversation, .note:
            selectedTab = .library
            libraryPath = [route]
        case .library(let tag):
            selectedTab = .library
            libraryPath = []
            pendingLibraryTag = tag
        case .search(let q):
            selectedTab = .library
            libraryPath = []
            pendingSearchQuery = q ?? ""
        case .ask:
            selectedTab = .ask
            askPath = []
            pendingAsk = route
        case .followUps(let scope):
            selectedTab = .followUps
            followUpsPath = []
            pendingFollowUpScope = scope
        case .followUp:
            selectedTab = .followUps
            followUpsPath = [route]
        case .settings(let page):
            selectedTab = .settings
            settingsPath = page.map { [Route.settings($0)] } ?? []
        }
    }

    /// Takes the pending tag and clears it, so returning to Library later does not silently
    /// re-apply a filter the user has since cleared by tapping the chip off. A bare
    /// `companion://library` carries no tag and therefore leaves the current filter alone.
    func consumePendingLibraryTag() -> String? {
        defer { pendingLibraryTag = nil }
        return pendingLibraryTag
    }

    /// Takes the pending Ask request and clears it, so returning to the tab later does not
    /// silently re-ask the last question.
    func consumePendingAsk() -> Route? {
        defer { pendingAsk = nil }
        return pendingAsk
    }

    func consumePendingFollowUpScope() -> String? {
        defer { pendingFollowUpScope = nil }
        return pendingFollowUpScope
    }
}
