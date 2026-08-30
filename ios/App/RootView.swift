import SwiftUI

/// The three-tab shell (Q2). Screens are filled in at M4/M6/M7; until then each tab hosts a
/// placeholder plus the M0 token gallery for verification.
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Today", systemImage: "waveform", value: AppRouter.Tab.today) {
                NavigationStack(path: $router.todayPath) {
                    PlaceholderScreen(title: "Today")
                }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    PlaceholderScreen(title: "Library")
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    PlaceholderScreen(title: "Settings")
                }
            }
        }
    }
}

private struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        List {
            NavigationLink("Design token gallery") { TokenGallery() }
        }
        .navigationTitle(title)
        .background(Tokens.ground)
    }
}
