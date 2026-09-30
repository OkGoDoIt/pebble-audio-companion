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
///
/// The undo snackbar (`UndoCenter`) is the other piece, placed the same way for the same reason
/// — and shown only by the selected tab, so it is on screen exactly once. It used to live on the
/// Library screen alone, so a conversation deleted from Today popped back to a screen with no
/// Undo on it.
struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(Copy.Tabs.today, systemImage: "waveform", value: AppRouter.Tab.today) {
                NavigationStack(path: $router.todayPath) {
                    TodayScreen()
                }
                .undoSnackbarHost(isShowing: router.selectedTab == .today)
                .noteJobDock()
            }
            Tab(Copy.Tabs.library, systemImage: "rectangle.stack", value: AppRouter.Tab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryScreen()
                }
                .undoSnackbarHost(isShowing: router.selectedTab == .library)
                .noteJobDock()
            }
            Tab(Copy.Tabs.followUps, systemImage: "checklist", value: AppRouter.Tab.followUps) {
                NavigationStack(path: $router.followUpsPath) {
                    FollowUpsScreen()
                }
                .undoSnackbarHost(isShowing: router.selectedTab == .followUps)
                .noteJobDock()
            }
            Tab(Copy.Tabs.ask, systemImage: "sparkles", value: AppRouter.Tab.ask) {
                NavigationStack(path: $router.askPath) {
                    AskScreen()
                }
                .undoSnackbarHost(isShowing: router.selectedTab == .ask)
                .noteJobDock()
            }
            Tab(Copy.Tabs.settings, systemImage: "gearshape", value: AppRouter.Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsScreen()
                }
                .undoSnackbarHost(isShowing: router.selectedTab == .settings)
                .noteJobDock()
            }
        }
    }
}

extension View {
    /// Hosts `UndoCenter.shared.snackbar` over this tab.
    ///
    /// A `ZStack` sibling of the tab's navigation stack, like the note-job dock and for the same
    /// reason: laid out inside the safe area, so it sits above the tab bar rather than on it.
    /// Applied inside `noteJobDock()` so it reads the dock's height and stacks above a note card
    /// instead of under it.
    ///
    /// Every tab carries one, and only the selected tab's shows: the snackbar belongs to the app,
    /// not to a tab, so it follows the person to whichever tab they are looking at — and five
    /// hosts rendering it at once would be five clocks behind one message.
    func undoSnackbarHost(isShowing: Bool) -> some View {
        modifier(UndoSnackbarHost(isShowing: isShowing))
    }
}

private struct UndoSnackbarHost: ViewModifier {
    let isShowing: Bool
    @State private var undo = UndoCenter.shared
    @Environment(\.noteJobDockInset) private var dockInset

    func body(content: Content) -> some View {
        @Bindable var undo = undo
        ZStack(alignment: .bottom) {
            content
            if isShowing {
                SnackbarSlot(item: $undo.snackbar)
                    .padding(.bottom, dockInset)
            }
        }
    }
}
