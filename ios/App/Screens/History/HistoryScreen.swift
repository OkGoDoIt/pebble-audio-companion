import AppDB
import SwiftUI

/// The History tab's root (plan 5.1, 7.12): Day, Week and Month as states of one screen, each a
/// horizontal pager of pages, under a level control that is always visible.
///
/// Built from the Phase 0 spike (`docs/redesign/history-sketches/Screen.swift`), whose findings
/// are load-bearing here:
/// - the page to open on is set as the pager's bound id BEFORE its first layout
///   (`HistoryModel.visiblePage`); `defaultScrollAnchor` never won;
/// - the level control sits in `.safeAreaBar(edge: .top)`, so pages slide under it and the
///   scroll edge effect (the outer pager's) reaches it;
/// - the navigation bar stays (the design has toolbar buttons); its title is kept for the back
///   button's menu on pushed screens and removed from the bar;
/// - toolbar items are plain `Button(_, systemImage:)`: the system draws the glass.
struct HistoryScreen: View {
    /// The day to open on; nil is today.
    var initialDay: String?
    var initialLevel: HistoryLevel = .day
    var source: any HistoryDataSource = HistoryDataSources.current.history
    /// Bumped by the tab bar when the History tab is tapped while already selected.
    var reselectToken: Int = 0
    /// Opens the conversation at a wall-clock moment (a chapter's start, a no-conversation
    /// stretch, a recording not transcribed yet). Nil resolves it with `Route.moment(atWallMs:)`
    /// (plan 7.9); a test or preview can pass its own.
    var openMoment: ((Int64) -> Void)?

    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: HistoryModel?
    @State private var isEmptyArchive = false
    @State private var titleFocusToken = 0
    @State private var services: HistoryPageServices?
    @State private var showsCalendar = false
    @State private var searchActive = false
    @State private var searchModel = SearchViewModel()
    /// The topic whose results are pushed (plan 5.7).
    @State private var openTag: HistoryTagSelection?

    var body: some View {
        ZStack {
            // The pager stays alive under search, invisible and out of VoiceOver's way, so
            // Cancel returns to the very page it left (plan 5.7).
            content
                .opacity(searchActive ? 0 : 1)
                .allowsHitTesting(!searchActive)
                .accessibilityHidden(searchActive)
            if searchActive {
                SearchStateView(
                    model: searchModel,
                    onCancel: { exitSearch() },
                    onSelectTag: { tag in
                        // The same list a topic pill opens (plan 5.7). Search stays open
                        // underneath, so Back returns to the results the tag was chosen from.
                        openTag = HistoryTagSelection(tag: tag)
                    }
                )
                .background(Tokens.ground)
            }
        }
        .background(Tokens.ground)
        .navigationTitle(searchActive ? Copy.History.search : Copy.History.tab)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar(searchActive ? .hidden : .automatic, for: .navigationBar)
        .toolbar { toolbar }
        .navigationDestination(for: Route.self) { route in destination(for: route) }
        .navigationDestination(item: $openTag) { selection in
            TagResultsScreen(
                tag: selection.tag, source: source,
                todayKey: model?.todayDateKey ?? MockHistory.todayKey,
                openMoment: momentOpener)
        }
        .onChange(of: router.pendingSearchQuery) { consumePendingSearch() }
        .task {
            #if DEBUG
            HistoryPerformance.startHitchLogIfAsked()
            #endif
            HistoryPerformance.markShown()
            await refreshBounds()
        }
        .onAppear {
            source.setVisible(true)
            consumePendingSearch()
        }
        .onDisappear { source.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            source.setVisible(phase == .active)
            if phase == .active { Task { await refreshBounds() } }
        }
        .onChange(of: reselectToken) { reselected() }
        .sheet(isPresented: $showsCalendar) {
            if let model {
                JumpCalendarSheet(
                    firstDateKey: model.firstDateKey, todayDateKey: model.todayDateKey,
                    recordedDays: model.recordedDays, level: model.level,
                    selectedDateKey: model.focusDateKey
                ) { key in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        _ = model.show(model.level, containing: key)
                    }
                }
            }
        }
        .onChange(of: model?.visiblePage) { prefetchNeighbours() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let model, let services {
            HistoryPager(model: model, services: services, titleFocusToken: titleFocusToken)
                .safeAreaBar(edge: .top) { levelControl(model) }
                .task(id: model.todayDateKey) { await waitForRollover(after: model.todayDateKey) }
        } else if isEmptyArchive {
            emptyArchive
        } else {
            // The frame before the bounds arrive: never a spinner (plan 5.8).
            Tokens.ground.ignoresSafeArea()
        }
    }

    private func levelControl(_ model: HistoryModel) -> some View {
        Picker(Copy.History.levelControl, selection: Binding(
            get: { model.level },
            set: { level in change(model, to: level) }
        )) {
            ForEach(HistoryLevel.allCases, id: \.self) { level in
                Text(level.title).tag(level)
            }
        }
        .labelsHidden()
        .historyLevelPickerStyle()
        // Announced as tabs (plan 5.9): it switches what the screen shows, it is not a setting.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The item itself is conditional, so no empty glass capsule is left behind (spike).
        if let model, !model.isShowingToday {
            ToolbarItem(placement: .topBarLeading) {
                Button(Copy.History.today) { goToToday(model) }
            }
        }
        if model != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(Copy.History.jumpToDate, systemImage: "calendar") { showsCalendar = true }
                Button(Copy.History.search, systemImage: "magnifyingglass") { enterSearch() }
            }
        }
    }

    /// Nothing has ever been recorded (plan 5.8): one centred message and a line pointing to
    /// Today; no level control content, no paging.
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

    // MARK: Search and pushes

    /// Resolves a moment and pushes it. A moment with nothing recorded near it resolves to nil
    /// and the tap does nothing — there is nowhere true to go.
    ///
    /// The demo world is the one exception: `MockHistory`'s days are fixed in September 2026 and
    /// the mock conversation world is built around the real today, so their clocks never meet.
    /// There a moment that finds nothing opens the demo conversation instead, so a tap in
    /// `-demo-data` still visibly goes somewhere.
    static func openMoment(_ ms: Int64, source: any HistoryDataSource, router: AppRouter) async {
        if let route = await Route.moment(atWallMs: ms) {
            router.push(route)
        } else if source is MockHistory {
            router.push(.conversation(id: MockHistory.demoConversationID, atMs: nil))
        }
    }

    /// `openMoment`, or the real resolver.
    private var momentOpener: (Int64) -> Void {
        if let openMoment { return openMoment }
        let router = self.router
        let source = self.source
        return { ms in Task { await Self.openMoment(ms, source: source, router: router) } }
    }

    private func enterSearch() {
        searchActive = true
    }

    private func exitSearch() {
        searchActive = false
        searchModel.query = ""
    }

    /// `companion://search?q=` lands here while History holds the tab, as it lands on the
    /// Library otherwise.
    private func consumePendingSearch() {
        guard let query = router.pendingSearchQuery else { return }
        router.pendingSearchQuery = nil
        searchModel.query = query
        searchActive = true
    }

    /// The same destinations the Library's stack registers — search results, a conversation's
    /// notes, a follow-up — plus the Live screen, which History's Live card opens.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .conversation(let id, let atMs, let focus):
            ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
        case .note(let id):
            SavedNotesScreen(noteId: id)
        case .followUp(let id):
            FollowUpDetailScreen(id: id)
        case .live:
            LiveConversationScreen()
        default:
            EmptyView()
        }
    }

    // MARK: Moves

    /// Level changes and drill-downs cross-fade with a slight scale (`Motion.transition`, which
    /// is a plain cross-fade under Reduce Motion); then VoiceOver moves to the new title.
    private func change(_ model: HistoryModel, to level: HistoryLevel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = model.changeLevel(to: level)
        }
        titleFocusToken += 1
    }

    /// From the page next door the pager scrolls there; from further away it is rebuilt at
    /// today and cross-faded — scrolling across two hundred pages would look wrong.
    private func goToToday(_ model: HistoryModel) {
        withAnimation(.easeInOut(duration: 0.3)) {
            _ = model.showToday()
        }
    }

    /// The tab was tapped while already showing History with nothing pushed (the system pops
    /// a pushed stack by itself). A scrolled page goes to its top; a page at its top goes to
    /// today — "back to now", as Photos does.
    private func reselected() {
        guard let model, router.libraryPath.isEmpty else { return }
        if let page = model.visiblePage, model.scrolledPages.contains(page) {
            model.scrollToTop()
        } else {
            goToToday(model)
        }
    }

    // MARK: Data

    private func refreshBounds() async {
        let bounds = await source.bounds()
        if let model {
            model.update(bounds: bounds)
            return
        }
        guard bounds.firstDateKey != nil else {
            isEmptyArchive = true
            return
        }
        let model = HistoryModel(bounds: bounds, level: initialLevel, focus: initialDay)
        services = makeServices(model)
        self.model = model
        prefetchNeighbours()
    }

    /// While the screen is up, the list gains the new day at the 5 AM rollover.
    private func waitForRollover(after todayKey: String) async {
        let now = Date()
        let calendar = Calendar.current
        var next = calendar.date(
            bySettingHour: LogicalDay.boundaryHour, minute: 0, second: 5, of: now) ?? now
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
        guard !Task.isCancelled else { return }
        await refreshBounds()
    }

    /// The pager's neighbours are built once into the source's cache, never observed.
    private func prefetchNeighbours() {
        guard let model, model.level == .day else { return }
        let days = model.neighbours.map(\.key)
        if !days.isEmpty { source.prefetch(days: days) }
    }

    private func makeServices(_ model: HistoryModel) -> HistoryPageServices {
        let router = self.router
        let openMoment = momentOpener
        let openTag = $openTag
        return HistoryPageServices(
            source: source,
            actions: HistoryActions(
                openChapter: { block in openMoment(block.startMs) },
                openFollowUp: { line in router.push(.followUp(id: line.id)) },
                openGap: { gap in if gap.isOpenable { openMoment(gap.startMs) } },
                openLive: { router.push(.live) },
                // No period filter on the Follow-ups tab yet (plan 5.2 wants one).
                openFollowUps: { _ in router.selectedTab = .followUps },
                openTag: { tag in openTag.wrappedValue = HistoryTagSelection(tag: tag) }),
            adjust: { offset in
                guard let target = model.page(offset: offset) else { return }
                model.visiblePage = target
            },
            reportScrolled: { page, scrolled in
                if scrolled { model.scrolledPages.insert(page) } else { model.scrolledPages.remove(page) }
            },
            drillDown: { level, dateKey in
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = model.show(level, containing: dateKey)
                }
                titleFocusToken += 1
            })
    }
}

// MARK: - The pager

/// One horizontal pager for the current level (spike-corrected). Rebuilt — and cross-faded —
/// when the level changes or on a far jump, through its identity.
struct HistoryPager: View {
    @Bindable var model: HistoryModel
    let services: HistoryPageServices
    let titleFocusToken: Int

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.pages(for: model.level), id: \.self) { page in
                    pageView(page)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $model.visiblePage)
        .scrollIndicators(.hidden)
        // Swipes belong to VoiceOver; a three-finger scroll pages instead.
        .accessibilityScrollAction { edge in
            let offset: Int
            switch edge {
            case .leading: offset = 1
            case .trailing: offset = -1
            default: return
            }
            if let target = model.page(offset: offset) { model.visiblePage = target }
        }
        // Spike caveat: after a tab re-tap the pager's phase can stay `.animating`; nothing
        // here gates on it being idle.
        .id(PagerIdentity(level: model.level, jump: model.jumpToken))
        .transition(Motion.transition(.opacity.combined(with: .scale(scale: 0.98))))
    }

    private struct PagerIdentity: Hashable {
        var level: HistoryLevel
        var jump: Int
    }

    @ViewBuilder
    private func pageView(_ page: HistoryPageID) -> some View {
        let context = HistoryPageContext(
            page: page, todayKey: model.todayDateKey, isCurrent: page == model.visiblePage,
            isNear: model.isNear(page), scrollToTopToken: model.scrollToTopToken,
            titleFocusToken: titleFocusToken)
        switch page.level {
        case .day:
            DayPage(context: context, services: services).equatable()
        case .week:
            WeekPage(context: context, services: services, lastDateKey: model.range(of: page).upperBound)
                .equatable()
        case .month:
            MonthPage(context: context, services: services).equatable()
        }
    }
}

extension View {
    /// `.tabs` on iOS 27, `.segmented` on iOS 26 (plan 7.12 "Chrome").
    @ViewBuilder
    func historyLevelPickerStyle() -> some View {
        if #available(iOS 27.0, *) {
            self.pickerStyle(.tabs)
        } else {
            self.pickerStyle(.segmented)
        }
    }
}

/// The DEBUG launch arguments that put History in the Library tab's place while it is built
/// (plan phase 2): `-history` shows it, `-historyDay 2026-09-22` picks the day and
/// `-historyLevel week|month` the level. Release builds never see them, and without `-history`
/// nothing about the app changes.
enum HistoryLaunch {
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-history")
        #else
        return false
        #endif
    }

    static var dayKey: String? { value(after: "-historyDay") }

    /// `-historyEmpty`: the demo world with nothing ever recorded.
    static var isEmptyArchive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-historyEmpty")
        #else
        return false
        #endif
    }

    static var level: HistoryLevel {
        value(after: "-historyLevel").flatMap(HistoryLevel.init(rawValue:)) ?? .day
    }

    private static func value(after flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }
}

/// A topic to show results for; `Identifiable` for `navigationDestination(item:)`.
struct HistoryTagSelection: Hashable, Identifiable {
    var tag: String
    var id: String { tag }
}
