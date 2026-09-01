import SwiftUI

/// The tab shell. Tab bar shows on the five roots, Search, and Settings pushes; hidden on
/// onboarding, content details, and sheets (plan 2-C). Each tab root registers its own
/// `.navigationDestination(for: Route.self)`.
///
/// Follow-ups and Ask are tabs rather than things hung off Today. Both were: follow-ups as two
/// rows and a "See all" that expanded in place, Ask as a sheet behind a title-bar pill. Neither
/// had anywhere to go — no list, no detail, no history you could return to — so both stayed as
/// big as the corner of Today they were allowed. They are the two things you come back to
/// between recordings, which is what a tab is for.
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(Copy.Tabs.today, systemImage: "waveform", value: AppRouter.Tab.today) {
                NavigationStack(path: $router.todayPath) {
                    TodayScreen()
                }
            }
            Tab(Copy.Tabs.library, systemImage: "rectangle.stack", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryScreen()
                }
            }
            Tab(Copy.Tabs.followUps, systemImage: "checklist", value: AppRouter.Tab.followUps) {
                NavigationStack(path: $router.followUpsPath) {
                    FollowUpsScreen()
                }
            }
            Tab(Copy.Tabs.ask, systemImage: "sparkles", value: AppRouter.Tab.ask) {
                NavigationStack(path: $router.askPath) {
                    AskScreen()
                }
            }
            Tab(Copy.Tabs.settings, systemImage: "gearshape", value: AppRouter.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsScreen()
                }
            }
        }
    }
}
