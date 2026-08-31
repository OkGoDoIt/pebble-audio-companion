import SwiftUI

/// The three-tab shell (Q2). Tab bar shows on the three roots, Search, and Settings pushes;
/// hidden on onboarding, content details, and sheets (plan 2-C). Each tab root registers its
/// own `.navigationDestination(for: Route.self)`.
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Today", systemImage: "waveform", value: AppRouter.Tab.today) {
                NavigationStack(path: $router.todayPath) {
                    TodayScreen()
                }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryScreen()
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsScreen()
                }
            }
        }
        .sheet(item: $router.askSheet) { route in
            AskSheetView(route: route)
        }
    }
}
