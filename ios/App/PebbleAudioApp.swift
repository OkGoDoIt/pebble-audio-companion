import SwiftUI

@main
struct PebbleAudioApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .tint(Tokens.tint)
                .onOpenURL { url in
                    if let route = Route.parse(url) { router.navigate(to: route) }
                }
        }
    }
}

/// Central navigation coordinator. Tabs + per-tab paths + sheet presentation, driven by
/// `Route` values so every screen stays deep-linkable (Part 6.8).
@Observable
final class AppRouter {
    enum Tab: Hashable { case today, library, settings }

    var selectedTab: Tab = .today
    var todayPath: [Route] = []
    var libraryPath: [Route] = []
    var settingsPath: [Route] = []
    var askSheet: Route?
    var pendingSearchQuery: String?

    func navigate(to route: Route) {
        switch route {
        case .today, .live:
            selectedTab = .today
            todayPath = route == .live ? [.live] : []
        case .conversation, .note:
            selectedTab = .library
            libraryPath = [route]
        case .library:
            selectedTab = .library
            libraryPath = []
        case .search(let q):
            selectedTab = .library
            libraryPath = []
            pendingSearchQuery = q ?? ""
        case .ask:
            askSheet = route
        case .settings(let page):
            selectedTab = .settings
            settingsPath = page.map { [Route.settings($0)] } ?? []
        }
    }
}
