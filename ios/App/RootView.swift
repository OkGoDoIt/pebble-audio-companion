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
///
/// `.noteJobDock()` on every stack is the one piece of app-wide furniture: an AI note being
/// written is the only thing in this app that the user starts on one screen and collects on
/// another, so the report on it cannot belong to any single screen. It goes inside each tab
/// rather than around the `TabView` so it docks above that tab's bar rather than on top of it —
/// see `NoteJobDock`.
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(Copy.Tabs.today, systemImage: "waveform", value: AppRouter.Tab.today) {
                NavigationStack(path: $router.todayPath) {
                    TodayScreen()
                }
                .noteJobDock()
            }
            Tab(
                HistoryLaunch.isEnabled ? Copy.History.tab : Copy.Tabs.library,
                systemImage: HistoryLaunch.isEnabled ? "clock.arrow.circlepath" : "rectangle.stack",
                value: AppRouter.Tab.library
            ) {
                NavigationStack(path: $router.libraryPath) {
                    // DEBUG `-history`: the History tab being built takes the Library's place
                    // (plan phase 2). Without the argument this is the Library, unchanged.
                    if HistoryLaunch.isEnabled {
                        HistoryScreen(dateKey: HistoryLaunch.dayKey)
                    } else {
                        LibraryScreen()
                    }
                }
                .noteJobDock()
            }
            Tab(Copy.Tabs.followUps, systemImage: "checklist", value: AppRouter.Tab.followUps) {
                NavigationStack(path: $router.followUpsPath) {
                    FollowUpsScreen()
                }
                .noteJobDock()
            }
            Tab(Copy.Tabs.ask, systemImage: "sparkles", value: AppRouter.Tab.ask) {
                NavigationStack(path: $router.askPath) {
                    AskScreen()
                }
                .noteJobDock()
            }
            Tab(Copy.Tabs.settings, systemImage: "gearshape", value: AppRouter.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsScreen()
                }
                .noteJobDock()
            }
        }
    }
}
