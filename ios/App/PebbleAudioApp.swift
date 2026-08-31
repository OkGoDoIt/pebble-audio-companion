import CoreSpotlight
import SwiftUI

@main
struct PebbleAudioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var settings = AppSettings()
    /// Widget/Control Center/Siri/Spotlight/notification plumbing (plan 6.8).
    @State private var nativeSurfaces: NativeSurfaceCoordinator

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _nativeSurfaces = State(initialValue: NativeSurfaceCoordinator(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Onboarding gate: the flow covers the app until the user finishes
                // connect → confirm-on-watch → transcripts (Q14). Dismissal happens only
                // by `onboardingComplete` flipping true inside the flow.
                .fullScreenCover(
                    isPresented: Binding(
                        get: { !settings.onboardingComplete },
                        set: { _ in }
                    )
                ) {
                    OnboardingFlow()
                        .environment(settings)
                        .tint(Tokens.tint)
                }
                .environment(router)
                .environment(settings)
                .tint(Tokens.tint)
                .onOpenURL { url in
                    if let route = Route.parse(url) { router.navigate(to: route) }
                }
                // Widget taps, the Q9 loss notification, Siri, and Spotlight results all end
                // up here — one navigation path, no per-surface special cases.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    nativeSurfaces.handle(userActivity: activity)
                }
                .task {
                    nativeSurfaces.start { route in router.navigate(to: route) }
                    await nativeSurfaces.handleForeground()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await nativeSurfaces.handleForeground() }
                    case .background: nativeSurfaces.handleBackground()
                    default: break
                    }
                }
                #if DEBUG
                // Simulator-automation staging: "-route settings/watch" behaves exactly
                // like an incoming companion:// URL (same parse + navigate path). Router
                // logic itself is untouched. DEBUG builds only.
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "-route"), index + 1 < args.count,
                        let url = URL(string: "companion://\(args[index + 1])"),
                        let route = Route.parse(url) {
                        router.navigate(to: route)
                    }
                }
                #endif
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
    /// Tag filter carried by `companion://library?tag=` — consumed by LibraryScreen on appear.
    var pendingLibraryTag: String?

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
            askSheet = route
        case .settings(let page):
            selectedTab = .settings
            settingsPath = page.map { [Route.settings($0)] } ?? []
        }
    }
}
