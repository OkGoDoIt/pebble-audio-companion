import AppDB
import SwiftUI

/// The History tab's root (plan 5.1, 7.12) — for now, one `DayPage` for one date.
///
/// What is deliberately missing, and where it goes: the level control, the pager, the toolbar
/// (Today, jump to date, search) and the routes all belong to the shell (plan steps 12 and 14),
/// which replaces `body`'s single page with the pager and passes real `HistoryActions`. The
/// seams it needs are here: the data source holder, `HistoryActions`, `HistoryPageTitle`, and
/// `setVisible` on appear and disappear.
struct HistoryScreen: View {
    /// The day to show; nil is today.
    var dateKey: String?
    var source: any HistoryDataSource = HistoryDataSources.current.history
    var actions = HistoryActions()

    @State private var bounds: HistoryBounds?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let bounds {
                if bounds.firstDateKey == nil {
                    emptyArchive
                } else {
                    DayPage(
                        dateKey: dateKey ?? bounds.todayDateKey, todayKey: bounds.todayDateKey,
                        source: source, actions: actions)
                }
            } else {
                Tokens.ground.ignoresSafeArea()
            }
        }
        .background(Tokens.ground)
        // Kept for the back label on pushed screens, removed from the bar: the title is drawn
        // in the page, under the level control the shell adds (plan 7.12 "Chrome").
        .navigationTitle(Copy.History.tab)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task { bounds = await source.bounds() }
        .onAppear { source.setVisible(true) }
        .onDisappear { source.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in source.setVisible(phase == .active) }
    }

    /// Nothing has ever been recorded (plan 5.8): one centred message, no paging.
    private var emptyArchive: some View {
        VStack(spacing: 8) {
            Text(Copy.History.nothingRecordedYet)
                .font(AppFont.headline)
                .foregroundStyle(Tokens.label)
            Text(Copy.History.nothingRecordedYetLine)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.ground)
    }
}

/// The DEBUG launch arguments that put History in the Library tab's place while it is built
/// (plan phase 2): `-history` shows it, `-historyDay 2026-09-22` picks the day. Release builds
/// never see it, and without `-history` nothing about the app changes.
enum HistoryLaunch {
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-history")
        #else
        return false
        #endif
    }

    static var dayKey: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-historyDay"), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }
}
