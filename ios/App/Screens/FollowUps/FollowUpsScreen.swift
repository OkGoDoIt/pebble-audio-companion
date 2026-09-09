import AppDB
import SwiftUI

/// The Follow-ups tab.
///
/// This is the one screen in the app that is a plain iOS list, and deliberately so. A follow-up
/// list is a to-do list; people already know how one behaves — swipe left to get rid of it,
/// swipe right to tick it, tap it to see more, pull to refresh — and every one of those was
/// missing while this lived as two rows in a card on Today. So: a real `List`, real
/// `swipeActions`, real sections, and the system's own large title.
///
/// It is sectioned by WHEN rather than by where it came from. "Overdue / Today / Next 7 days /
/// Later / No date" is the order a person actually reads a list in; grouping by conversation
/// would be grouping by an implementation detail of how the item was found.
struct FollowUpsScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = FollowUpsViewModel()
    @State private var snackbar: SnackbarItem?

    var body: some View {
        content
            .navigationTitle(Copy.FollowUps.title)
            .toolbar { toolbar }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
            .snackbar(item: $snackbar)
            .task { await model.start(scope: router.consumePendingFollowUpScope()) }
            // A link that arrives while this screen is already up never re-runs `.task`, so
            // without this it did nothing now and silently flipped the filter minutes later,
            // on some unrelated tab switch.
            .onChange(of: router.pendingFollowUpScope) { _, pending in
                guard pending != nil,
                    let scope = FollowUpListScope(
                        rawValue: router.consumePendingFollowUpScope() ?? "")
                else { return }
                model.scope = scope
            }
    }

    // MARK: Content
    //
    // ONE view identity, always the `List`, with the empty state as an overlay. Swapping the
    // whole screen between a list and a placeholder changed identity on every load, and the
    // navigation bar lost its large title to the swap — the screen came up with a collapsed
    // inline title as if it had been scrolled.

    private var content: some View {
        List {
            // Said once, at the top, only when the on-device reader is the one proposing. It
            // leads with what is MISSING rather than with what might be wrong: the measurement
            // is certain that it finds fewer (three of eight a careful reader found) and never
            // dates them, and much less certain about how often it is wrong.
            if model.scope == .open, !model.isEmpty, model.proposalsAreOnDevice {
                Text(Copy.LocalFollowUps.banner)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityLabel(Copy.LocalFollowUps.bannerA11y)
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        row(item)
                    }
                } header: {
                    // A header on the only section says nothing — least of all "No date"
                    // over a list where nothing has one.
                    if model.sections.count > 1 && !section.title.isEmpty {
                        Text(section.title)
                    }
                }
            }
            if model.scope == .open && !model.isEmpty {
                filedAwayTail
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.ground)
        .animation(Motion.animation(.snappy(duration: 0.25)), value: model.animationKey)
        .overlay {
            if model.isEmpty {
                ContentUnavailableView {
                    Label(model.emptyTitle, systemImage: model.emptyGlyph)
                } description: {
                    Text(model.emptyBody)
                } actions: {
                    // The old action here was "New Follow-up". With nothing to add by hand,
                    // the useful thing to offer someone staring at an empty list is the one
                    // place their missing items actually went — and only when some are there.
                    if model.scope == .open && model.filedAwayCount > 0 {
                        Button(Copy.FollowUps.openFiledAway(model.filedAwayCount)) {
                            model.scope = .archived
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: The tail of the open list — what the age rule took away
    //
    // Filed-away items used to leave the screen completely: the only trace was a footer
    // sentence pointing at a filter three taps away, so a fortnight later the list was simply
    // shorter and nothing said why. They are still not part of the working list — they are
    // collapsed, unticked, one type size down, at the very bottom — but the count is always
    // on screen, and opening it takes one tap.
    //
    // That is also why the footer sentence itself is gone. It explained the age rule to a
    // reader who could not see its results; now the results are the row above.

    @ViewBuilder
    private var filedAwayTail: some View {
        Section {
            if model.filedAwayCount > 0 {
                filedAwayDisclosure
                if model.showsFiledAway {
                    ForEach(model.filedAwayPreview) { item in
                        filedAwayRow(item)
                    }
                    if model.hasMoreFiledAway {
                        seeAllFiledAwayRow
                    }
                }
            }
        }
    }

    private var filedAwayDisclosure: some View {
        Button {
            withAnimation(Motion.animation(.snappy(duration: 0.25))) {
                model.showsFiledAway.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.meta)
                    .frame(width: 22)
                Text(Copy.FollowUps.scopeArchived)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(Copy.FollowUps.filedAwayCount(model.filedAwayCount))
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.meta)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .rotationEffect(.degrees(model.showsFiledAway ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The bare digit is meaningless read aloud, and the rotated chevron says nothing at
        // all — so the label carries the noun and the hint carries the direction.
        .accessibilityLabel(Copy.FollowUps.filedAwayA11y(model.filedAwayCount))
        .accessibilityHint(
            model.showsFiledAway
                ? Copy.FollowUps.filedAwayHideHint : Copy.FollowUps.filedAwayShowHint)
        .listRowBackground(Tokens.surface)
    }

    /// Quieter than `FollowUpRow` on purpose, and not by dimming it: a filed-away item is no
    /// longer a task, so it gets no checkbox to tick and no due date to be late for. What is
    /// left is what it said and when it stopped being asked about — indented under the section
    /// head, so it reads as a footnote to the list rather than a continuation of it.
    private func filedAwayRow(_ item: FollowUpItem) -> some View {
        Button {
            router.followUpsPath.append(.followUp(id: item.id))
        } label: {
            filedAwayRowContent(item)
                // 32 pt = the disclosure row's glyph plus its gap, so these line up under the
                // words "Filed away" and read as belonging to it.
                .padding(.leading, 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                restore(item)
            } label: {
                Label(Copy.FollowUps.restore, systemImage: "tray.and.arrow.up")
            }
            .tint(Tokens.good)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(Copy.FollowUps.delete, systemImage: "trash")
            }
            .tint(Tokens.destructive)
        }
        .contextMenu {
            Button {
                restore(item)
            } label: {
                Label(Copy.FollowUps.restore, systemImage: "tray.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(Copy.FollowUps.delete, systemImage: "trash")
            }
        }
        .listRowBackground(Tokens.surface)
    }

    /// Side by side at the everyday sizes, stacked at accessibility ones — the rule
    /// `SettingsRow` already follows, because a title and a trailing value sharing one line at
    /// AX5 is a hyphenated fragment beside a truncated date.
    @ViewBuilder
    private func filedAwayRowContent(_ item: FollowUpItem) -> some View {
        let when = FollowUpFormatting.filedAwayDay(item, now: model.now)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                filedAwayText(item)
                if let when { filedAwayWhen(when) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                filedAwayText(item)
                Spacer(minLength: 8)
                if let when { filedAwayWhen(when).lineLimit(1) }
            }
        }
    }

    private func filedAwayText(_ item: FollowUpItem) -> some View {
        Text(item.text)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.tertiary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func filedAwayWhen(_ when: String) -> some View {
        Text(when)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.faint)
    }

    /// The preview is capped, so a year of filed-away suggestions cannot push the list it sits
    /// under off the screen. This is the honest way out: the whole slice, in the filter that
    /// is named the same as the section above it.
    private var seeAllFiledAwayRow: some View {
        Button {
            model.scope = .archived
        } label: {
            HStack(spacing: 10) {
                Text(Copy.FollowUps.seeAllFiledAway(model.filedAwayCount))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tint)
                Spacer(minLength: 8)
            }
            .padding(.leading, 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Tokens.surface)
    }

    /// Undoable like every other move on this screen: putting something back on the list is a
    /// decision, and a mis-swipe on a row you were only reading is easy.
    private func restore(_ item: FollowUpItem) {
        model.setArchived(item, archived: false)
        snackbar = SnackbarItem(
            message: Copy.FollowUps.restored, actionTitle: Copy.Common.undo
        ) {
            model.setArchived(item, archived: true)
        }
    }

    // MARK: Row

    private func row(_ item: FollowUpItem) -> some View {
        Button {
            router.followUpsPath.append(.followUp(id: item.id))
        } label: {
            FollowUpRow(item: item, now: model.now) {
                Haptics.checkedOff()
                model.toggle(item)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(Copy.FollowUps.delete, systemImage: "trash")
            }
            // The app-wide violet tint wins over the destructive role in a swipe action, so a
            // delete came up looking like any other button. Red, explicitly.
            .tint(Tokens.destructive)
            if !item.done && !item.isArchived {
                Button {
                    snooze(item, until: model.tomorrow)
                } label: {
                    Label(Copy.FollowUps.snooze, systemImage: "clock.badge")
                }
                .tint(Tokens.attention)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Haptics.checkedOff()
                model.toggle(item)
            } label: {
                Label(
                    item.done ? Copy.FollowUps.markNotDone : Copy.FollowUps.markDone,
                    systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(Tokens.good)
        }
        // Swipe is never the only path to an action (the speaker sheet set this rule): the same
        // three live in a long-press menu, where they are discoverable without guessing.
        .contextMenu {
            Button {
                model.toggle(item)
            } label: {
                Label(
                    item.done ? Copy.FollowUps.markNotDone : Copy.FollowUps.markDone,
                    systemImage: item.done ? "arrow.uturn.backward" : "checkmark.circle")
            }
            // Not offered on a filed-away row: snoozing un-archives, which would move it out
            // of the only list showing it.
            if !item.done && !item.isArchived {
                Menu {
                    Button(Copy.FollowUps.snoozeTomorrow) { snooze(item, until: model.tomorrow) }
                    Button(Copy.FollowUps.snoozeNextWeek) { snooze(item, until: model.nextWeek) }
                } label: {
                    Label(Copy.FollowUps.snooze, systemImage: "clock.badge")
                }
            }
            if item.isArchived {
                // Through the same helper the summary uses, so restoring is undoable wherever
                // it is done — it was the one move on this screen that was not.
                Button {
                    restore(item)
                } label: {
                    Label(Copy.FollowUps.restore, systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    archive(item)
                } label: {
                    Label(Copy.FollowUps.fileAway, systemImage: "archivebox")
                }
            }
            Divider()
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(Copy.FollowUps.delete, systemImage: "trash")
            }
        }
        .listRowBackground(Tokens.surface)
    }

    /// Destructive, so it is undoable. The snackbar is the app's standing undo affordance and
    /// the only thing standing between a mis-swipe and a lost commitment.
    private func delete(_ item: FollowUpItem) {
        Haptics.destructiveConfirmed()
        model.delete(item)
        snackbar = SnackbarItem(
            message: Copy.FollowUps.deleted, actionTitle: Copy.Common.undo
        ) {
            model.undoDelete(item)
        }
    }

    /// Undoable like the other two: putting something off is a decision, and a mis-swipe on a
    /// list is easy.
    private func snooze(_ item: FollowUpItem, until date: Date) {
        model.snooze(item, until: date)
        snackbar = SnackbarItem(
            message: Copy.FollowUps.putOff(FollowUpFormatting.day(date, now: model.now)),
            actionTitle: Copy.Common.undo
        ) {
            model.snooze(item, until: nil)
        }
    }

    private func archive(_ item: FollowUpItem) {
        model.setArchived(item, archived: true)
        snackbar = SnackbarItem(
            message: Copy.FollowUps.filedAway, actionTitle: Copy.Common.undo
        ) {
            model.setArchived(item, archived: false)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(Copy.FollowUps.title, selection: $model.scope) {
                    ForEach(FollowUpListScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
            } label: {
                // Which slice you are looking at belongs ON the control, not only inside the
                // menu that set it: a widget or a deep link can land you in "Filed away" with
                // no idea why the list looks short. An explicit glyph + text pair, because
                // iOS 26 renders a `Label` icon-only in a bar.
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(model.scope.title)
                }
            }
            .accessibilityLabel(Copy.A11y.followUpFilter(model.scope.title))
        }
        // There is deliberately no "+" beside the filter. Nothing on this screen is a list you
        // keep by hand: every row is something the app heard you say, and a blank editor next
        // to them invited people to use it as a to-do app it is not — and then to wonder why
        // their own items had no recording behind them. Writing one is still possible where it
        // makes sense (Edit, on an item that already exists).
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .followUp(let id):
            FollowUpDetailScreen(id: id)
        case .conversation(let id, let atMs, let focus):
            ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
        case .note(let id):
            // Reachable from here: a follow-up opens its recording, and a recording's Notes
            // pill pushes onto whichever stack the person is in — this one.
            SavedNotesScreen(noteId: id)
        default:
            Color.clear.background(Tokens.ground)
        }
    }
}

// MARK: - Row

/// One follow-up, wherever it appears. Shared by the list, the Today card and the conversation
/// sheet so a follow-up looks the same everywhere and only has to be got right once.
struct FollowUpRow: View {
    let item: FollowUpItem
    let now: Date
    var showsChevron = true
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(item.done ? Tokens.tint : Tokens.chevron)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.text)
            .accessibilityValue(item.done ? Copy.A11y.followUpDone : Copy.A11y.followUpNotDone)
            .accessibilityHint(Copy.A11y.followUpHint)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(AppFont.callout)
                    .foregroundStyle(item.done ? Tokens.meta : Tokens.label)
                    .strikethrough(item.done, color: Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let meta = FollowUpFormatting.metaLine(item, now: now) {
                    HStack(spacing: 6) {
                        // Not on something deferred: the person has already said "not now",
                        // and a row in "Put off" that still shouts is the feature being
                        // annoying about a decision they made.
                        if item.priority == .high && !item.done && !item.isSnoozed(at: now) {
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Tokens.attention)
                                .accessibilityHidden(true)
                        }
                        Text(meta.text)
                            .font(AppFont.footnote)
                            .foregroundStyle(meta.isUrgent ? Tokens.attention : Tokens.meta)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - View model

@MainActor
@Observable
final class FollowUpsViewModel {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        var items: [FollowUpItem]
    }

    private let injectedSource: (any FollowUpsDataSource)?

    var scope: FollowUpListScope = .open {
        didSet { if scope != oldValue { Task { await reload() } } }
    }
    /// Bumped on every load. A reload that finishes after a newer one started is discarded, so
    /// switching Open → Completed → Filed away quickly cannot leave one slice's rows sitting
    /// under another slice's filter.
    private var loadGeneration = 0
    private(set) var items: [FollowUpItem] = []
    /// The filed-away slice, loaded alongside the open list so the summary at its foot can be
    /// honest about how many there are. Empty on the other two scopes, where the list itself is
    /// already showing everything.
    private(set) var filedAway: [FollowUpItem] = []
    /// Collapsed to start with. The count is always visible; the rows are opt-in.
    var showsFiledAway = false
    /// How many filed-away rows the open list will show inline before handing over to the
    /// filter. Enough to recognise what went, few enough that the list underneath stays the
    /// point of the screen.
    static let filedAwayPreviewLimit = 5
    private(set) var loaded = false
    /// Ticks the person has just made, applied over whatever the last load returned.
    ///
    /// Without this the checkmark waits on a database write and a full reload before it fills
    /// in — which reads, correctly, as "tapping the checkbox doesn't do anything".
    private var optimisticDone: [String: Bool] = [:]
    private var hidden: Set<String> = []
    private(set) var now = Date()

    /// Resolved at point of use, not captured at init.
    ///
    /// A view model built before the live graph is installed would otherwise observe the mock
    /// world for its whole life. That is not hypothetical: a launch iOS labelled "Bluetooth
    /// state restoration" left the runtime receive-only while the app was visible, and the same
    /// shape of latent binding fault was the first suspect. It was not the cause there, but it
    /// is a real hazard and this is what closes it.
    private var source: any FollowUpsDataSource {
        injectedSource ?? AskLibraryDataSources.current.followUps
    }

    init(source: (any FollowUpsDataSource)? = nil) {
        self.injectedSource = source
    }

    func start(scope requested: String?) async {
        if let requested, let parsed = FollowUpListScope(rawValue: requested) { scope = parsed }
        await reload()
        for await _ in source.followUpUpdates() {
            await reload()
        }
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        now = Date()
        let loadedItems = (try? await source.items(scope: scope)) ?? []
        // The filed-away slice rides along with the open list, because a count at the foot of
        // that list has to be a count of what is there NOW — a number cached from whenever the
        // filter was last opened is exactly the kind of quiet lie this section exists to end.
        // Read on `.open` only: the other two scopes are already showing their own everything.
        var loadedFiledAway: [FollowUpItem] = []
        if scope == .open { loadedFiledAway = await filedAwaySlice() }
        // EVERY mutation below the guard, including this one. `optimisticDone` used to be
        // rewritten before it, so a load that had already been superseded still got to retire
        // the overrides — and a tick made while that load was in flight was reverted by a
        // snapshot too old to know about it, with `items` left untouched. The rule is now the
        // plain one: a stale load changes nothing at all.
        guard generation == loadGeneration else { return }
        // Anything the DB now agrees with is no longer an optimistic guess — and neither is
        // anything that has left this slice entirely. Keeping an override for a row that is no
        // longer here is how a ticked item came back later still rendering as done, with its
        // checkbox writing the value it already had.
        let present = Set(loadedItems.map(\.id))
        optimisticDone = optimisticDone.filter { id, done in
            guard present.contains(id) else { return false }
            return loadedItems.first { $0.id == id }?.done != done
        }
        // A deleted row is held back until it is gone from BOTH lists: without the second half,
        // deleting from the filed-away summary un-hid the row on the very next reload and it
        // flickered back for as long as the write took.
        hidden = hidden.filter { id in
            loadedItems.contains { $0.id == id } || loadedFiledAway.contains { $0.id == id }
        }
        items = loadedItems
        filedAway = loadedFiledAway
        loaded = true
    }

    /// Newest first, sorted here rather than trusted from the source: the preview shows only
    /// the first few, so "the first few" has to mean the ones that went most recently — which
    /// is the ordering the store gives and the mock does not.
    private func filedAwaySlice() async -> [FollowUpItem] {
        let rows = (try? await source.items(scope: .archived)) ?? []
        return rows.sorted { ($0.archivedAtMs ?? 0) > ($1.archivedAtMs ?? 0) }
    }

    // MARK: Derived

    private var visible: [FollowUpItem] {
        items.compactMap { item in
            guard !hidden.contains(item.id) else { return nil }
            guard let optimistic = optimisticDone[item.id] else { return item }
            // A tick in the Open list means the row is on its way out; leave it visible and
            // struck through until the reload lands, so it does not vanish under the finger.
            var copy = item
            copy.done = optimistic
            return copy
        }
    }

    var isEmpty: Bool { loaded && visible.isEmpty }

    // MARK: Filed away
    //
    // `hidden` applies here too: a row deleted out of the summary leaves the count in the same
    // frame it leaves the list, so the header cannot say "3" over two rows.

    private var visibleFiledAway: [FollowUpItem] {
        filedAway.filter { !hidden.contains($0.id) }
    }

    var filedAwayCount: Int { visibleFiledAway.count }

    /// Whether the proposals on this screen were found by the on-device model. It changes what
    /// an empty list MEANS, so the screen says so rather than presenting two very different
    /// readers as one.
    var proposalsAreOnDevice: Bool { source.proposalsAreOnDevice }

    var filedAwayPreview: [FollowUpItem] {
        Array(visibleFiledAway.prefix(Self.filedAwayPreviewLimit))
    }

    var hasMoreFiledAway: Bool { visibleFiledAway.count > Self.filedAwayPreviewLimit }

    /// Changes whenever the rendered set does, so the list animates its own insertions and
    /// removals instead of snapping. The filed-away tail is part of that set: expanding it, and
    /// restoring or deleting a row out of it, both change what is drawn.
    var animationKey: String {
        visible.map { "\($0.id)\($0.done)" }.joined()
            + "|\(showsFiledAway)|\(filedAwayCount)|"
            + filedAwayPreview.map(\.id).joined()
    }

    var sections: [Section] {
        let rows = visible
        guard scope == .open else {
            return rows.isEmpty ? [] : [Section(id: scope.rawValue, title: "", items: rows)]
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday

        var overdue: [FollowUpItem] = []
        var today: [FollowUpItem] = []
        var soon: [FollowUpItem] = []
        var later: [FollowUpItem] = []
        var anytime: [FollowUpItem] = []
        // Snoozed items get their own section at the bottom rather than vanishing. They used
        // to belong to no slice at all — put something off and it left every list in the app,
        // with the only control for undoing that on a screen you could no longer reach.
        var putOff: [FollowUpItem] = []
        for item in rows {
            if item.isSnoozed(at: now) { putOff.append(item); continue }
            guard let due = item.dueDate else { anytime.append(item); continue }
            if due < startOfToday {
                overdue.append(item)
            } else if due < endOfToday {
                today.append(item)
            } else if due < endOfWeek {
                soon.append(item)
            } else {
                later.append(item)
            }
        }
        return [
            Section(id: "overdue", title: Copy.FollowUps.sectionOverdue, items: overdue),
            Section(id: "today", title: Copy.FollowUps.sectionToday, items: today),
            Section(id: "soon", title: Copy.FollowUps.sectionSoon, items: soon),
            Section(id: "later", title: Copy.FollowUps.sectionLater, items: later),
            Section(id: "anytime", title: Copy.FollowUps.sectionAnytime, items: anytime),
            Section(id: "snoozed", title: Copy.FollowUps.sectionSnoozed, items: putOff),
        ].filter { !$0.items.isEmpty }
    }

    var emptyTitle: String {
        switch scope {
        case .open: return Copy.FollowUps.emptyOpenTitle
        case .completed: return Copy.FollowUps.emptyCompletedTitle
        case .archived: return Copy.FollowUps.emptyArchivedTitle
        }
    }

    var emptyGlyph: String {
        switch scope {
        case .open: return "checkmark.circle"
        case .completed: return "checkmark.circle.badge.questionmark"
        case .archived: return "archivebox"
        }
    }

    var emptyBody: String {
        switch scope {
        case .open:
            // Both of these used to end by offering to let you write your own. There is no
            // longer anywhere to do that, and an empty state that suggests a control the screen
            // does not have is worse than a shorter sentence.
            guard source.automaticProposalsEnabled else {
                return Copy.FollowUps.emptyOpenBodySuggestedNoAi
            }
            // On-device extraction is deliberately cautious — it drops anything it cannot
            // verify — so an empty list means something different here than it does on the
            // cloud path, and the empty state is the only place that difference can be said.
            return source.proposalsAreOnDevice
                ? Copy.LocalFollowUps.emptyOpenBody
                : Copy.FollowUps.emptyOpenBodySuggested
        case .completed: return Copy.FollowUps.emptyCompletedBody
        case .archived: return Copy.FollowUps.emptyArchivedBody
        }
    }

    var tomorrow: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    var nextWeek: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: Actions

    func toggle(_ item: FollowUpItem) {
        let next = !(optimisticDone[item.id] ?? item.done)
        optimisticDone[item.id] = next
        Task {
            try? await source.setDone(id: item.id, done: next)
            await reload()
        }
    }

    func snooze(_ item: FollowUpItem, until date: Date?) {
        Task {
            try? await source.snooze(
                id: item.id, untilMs: date.map { Int64($0.timeIntervalSince1970 * 1000) })
            await reload()
        }
    }

    func setArchived(_ item: FollowUpItem, archived: Bool) {
        Task {
            try? await source.setArchived(id: item.id, archived: archived)
            await reload()
        }
    }

    /// Deletes for real, immediately — the undo path re-adds it. Holding the row back for five
    /// seconds instead would leave a follow-up that looks deleted but still fires the widget's
    /// count, which is a worse lie than a re-created id.
    func delete(_ item: FollowUpItem) {
        hidden.insert(item.id)
        Task {
            try? await source.delete(id: item.id)
            await reload()
        }
    }

    /// Puts the row back as it was — same id, same quote, same recording. Re-adding it as a
    /// fresh hand-written item would look like undo and quietly lose where it came from.
    func undoDelete(_ item: FollowUpItem) {
        hidden.remove(item.id)
        Task {
            try? await source.restore(item)
            await reload()
        }
    }
}
