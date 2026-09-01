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
    @State private var model = FollowUpsViewModel()
    @State private var snackbar: SnackbarItem?

    var body: some View {
        content
            .navigationTitle(Copy.FollowUps.title)
            .toolbar { toolbar }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
            .sheet(isPresented: $model.showingAdd) {
                FollowUpEditorSheet(title: Copy.FollowUps.add, text: "", dueAt: nil) { text, due in
                    model.add(text: text, dueAt: due)
                }
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
                Section {
                    EmptyView()
                } footer: {
                    Text(Copy.FollowUps.ageFooter)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
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
                    if model.scope == .open {
                        Button(Copy.FollowUps.add) { model.showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
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
                Button {
                    model.setArchived(item, archived: false)
                    snackbar = SnackbarItem(message: Copy.FollowUps.restored)
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
        // Two trailing items are separated by a spacer, never by drawing a shape: iOS 26
        // supplies the capsule and would otherwise merge them into one control.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.showingAdd = true
            } label: {
                Label(Copy.FollowUps.add, systemImage: "plus")
            }
        }
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
                        if item.priority == .high && !item.done {
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

    private let source: any FollowUpsDataSource

    var scope: FollowUpListScope = .open {
        didSet { if scope != oldValue { Task { await reload() } } }
    }
    /// Bumped on every load. A reload that finishes after a newer one started is discarded, so
    /// switching Open → Completed → Filed away quickly cannot leave one slice's rows sitting
    /// under another slice's filter.
    private var loadGeneration = 0
    var showingAdd = false
    private(set) var items: [FollowUpItem] = []
    private(set) var loaded = false
    /// Ticks the person has just made, applied over whatever the last load returned.
    ///
    /// Without this the checkmark waits on a database write and a full reload before it fills
    /// in — which reads, correctly, as "tapping the checkbox doesn't do anything".
    private var optimisticDone: [String: Bool] = [:]
    private var hidden: Set<String> = []
    private(set) var now = Date()

    init(source: (any FollowUpsDataSource)? = nil) {
        self.source = source ?? AskLibraryDataSources.current.followUps
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
        // Anything the DB now agrees with is no longer an optimistic guess — and neither is
        // anything that has left this slice entirely. Keeping an override for a row that is no
        // longer here is how a ticked item came back later still rendering as done, with its
        // checkbox writing the value it already had.
        let present = Set(loadedItems.map(\.id))
        optimisticDone = optimisticDone.filter { id, done in
            guard present.contains(id) else { return false }
            return loadedItems.first { $0.id == id }?.done != done
        }
        guard generation == loadGeneration else { return }
        hidden = hidden.filter { id in loadedItems.contains { $0.id == id } }
        items = loadedItems
        loaded = true
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

    /// Changes whenever the rendered set does, so the list animates its own insertions and
    /// removals instead of snapping.
    var animationKey: String {
        visible.map { "\($0.id)\($0.done)" }.joined()
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
            return source.automaticProposalsEnabled
                ? Copy.FollowUps.emptyOpenBody : Copy.FollowUps.emptyOpenBodyNoAi
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

    func add(text: String, dueAt: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await source.add(
                text: trimmed, dueAtMs: dueAt.map { Int64($0.timeIntervalSince1970 * 1000) })
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
