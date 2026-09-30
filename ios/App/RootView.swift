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
    /// Bumped when the History tab is tapped while already selected (DEBUG `-history` only).
    @State private var historyReselect = 0

    var body: some View {
        @Bindable var router = router
        TabView(selection: tabSelection) {
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
                        HistoryScreen(
                            initialDay: HistoryLaunch.dayKey, initialLevel: HistoryLaunch.level,
                            reselectToken: historyReselect)
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

    /// The tab selection. Without `-history` it is exactly `$router.selectedTab`. With it, a tap
    /// on the History tab while it is already selected — the setter fires with the current
    /// value (spike) — is passed to History: the system pops a pushed stack by itself, and at
    /// the root History scrolls to the top or goes back to today (plan 5.1). Every other tab,
    /// and every other tap, behaves as before.
    private var tabSelection: Binding<AppRouter.Tab> {
        Binding(
            get: { router.selectedTab },
            set: { tab in
                if HistoryLaunch.isEnabled, tab == .library {
                    if router.selectedTab == .library {
                        // Read now: the system's own pop of a pushed stack lands ~30 ms after
                        // this setter (spike), and a pushed stack is the system's to handle.
                        if router.libraryPath.isEmpty { historyReselect += 1 }
                    } else {
                        HistoryPerformance.markShown()
                    }
                }
                router.selectedTab = tab
            })
    }
}
