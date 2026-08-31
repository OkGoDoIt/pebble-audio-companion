import SwiftUI
import AppDB

/// Library tab root (mockup 2.5): title + "All ⌄" filter menu, "Search or ask" field
/// (focusing enters the Search state — mockup 2.7), scrolling tag chips with counts, and
/// day-sectioned conversation rows. Registers the library stack's navigation destinations
/// (conversation + note) and hosts the delete-undo snackbar.
struct LibraryScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var model = LibraryViewModel()
    @State private var searchModel = SearchViewModel()
    @State private var searchActive = false
    @State private var showAllTags = false
    @State private var undo = UndoCenter.shared

    var body: some View {
        @Bindable var undo = undo
        Group {
            if searchActive {
                SearchStateView(
                    model: searchModel,
                    onCancel: { exitSearch() },
                    onSelectTag: { tag in
                        model.selectedTag = tag
                        exitSearch()
                    }
                )
            } else {
                libraryContent
            }
        }
        .background(Tokens.ground)
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(searchActive ? "Search" : Copy.Library.title)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .conversation(let id, let atMs, let focus):
                ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
            case .note(let id):
                SavedNotesScreen(noteId: id)
            default:
                // Other hosts (Today/Live/Settings) register their own destinations.
                EmptyView()
            }
        }
        .snackbar(item: $undo.snackbar)
        .task { await model.start() }
        .onAppear {
            consumePendingSearch()
            consumePendingTag()
        }
        .onChange(of: router.pendingSearchQuery) { consumePendingSearch() }
        .onChange(of: router.pendingLibraryTag) { consumePendingTag() }
        .sheet(isPresented: $showAllTags) {
            AllTagsSheet(tags: model.tags) { tag in
                model.selectedTag = tag
                showAllTags = false
            }
        }
    }

    private func exitSearch() {
        searchActive = false
        searchModel.query = ""
    }

    private func consumePendingSearch() {
        guard let query = router.pendingSearchQuery else { return }
        router.pendingSearchQuery = nil
        searchModel.query = query
        searchActive = true
    }

    /// `companion://library?tag=travel` — the tag the deep link asked for becomes the selected
    /// chip. Nothing read `pendingLibraryTag` before this, so the link opened an unfiltered
    /// Library and the filter was dropped without a word.
    private func consumePendingTag() {
        guard let tag = router.consumePendingLibraryTag() else { return }
        searchActive = false
        model.selectedTag = tag
    }

    // MARK: - Library state

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                titleRow
                restingSearchField
                // With no tags there is nothing to filter by, so the row (and its lone
                // "more…" affordance) would be a control that does nothing.
                if !model.tags.isEmpty { tagChipsRow }

                if model.sections.isEmpty {
                    Text(Copy.Empty.library)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    ForEach(model.sections, id: \.dateKey) { section in
                        sectionHeader(TimeFmt.dayLabel(dateKey: section.dateKey))
                        ListCard {
                            ForEach(section.rows, id: \.id) { row in
                                ConversationRowView(row: row)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.bottom, Tokens.blockGap)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            Text(Copy.Library.title)
                .font(AppFont.tabTitle)
                .foregroundStyle(Tokens.label)
            Spacer()
            filterMenu
        }
        .padding(.top, 2)
    }

    private var filterMenu: some View {
        Menu {
            Picker("", selection: $model.filter) {
                Text(Copy.Library.filterAll).tag(LibraryFilter.all)
                Text(Copy.Library.filterUntranscribed).tag(LibraryFilter.untranscribed)
                Text(Copy.Library.filterWithFollowUps).tag(LibraryFilter.withFollowUps)
                Text(Copy.Library.filterWithMissingAudio).tag(LibraryFilter.withMissingAudio)
            }
        } label: {
            HStack(spacing: 4) {
                Text(filterLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(AppFont.chip)
            .foregroundStyle(Tokens.tint)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var filterLabel: String {
        switch model.filter {
        case .all: return Copy.Library.filterAll
        case .untranscribed: return Copy.Library.filterUntranscribed
        case .withFollowUps: return Copy.Library.filterWithFollowUps
        case .withMissingAudio: return Copy.Library.filterWithMissingAudio
        }
    }

    private var restingSearchField: some View {
        Button {
            searchActive = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.meta)
                Text(Copy.Library.searchPlaceholder)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.meta)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var tagChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.tags.prefix(4), id: \.id) { tag in
                    tagChip(tag)
                }
                if model.tags.count > 4 {
                    Button(Copy.Library.moreTags) { showAllTags = true }
                        .font(AppFont.chip)
                        .foregroundStyle(Tokens.meta)
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                }
            }
        }
        .scrollClipDisabled(false)
    }

    private func tagChip(_ tag: TagWithCount) -> some View {
        let selected = model.selectedTag?.caseInsensitiveCompare(tag.name) == .orderedSame
        return Button {
            model.selectedTag = selected ? nil : tag.name
        } label: {
            HStack(spacing: 5) {
                Text(tag.name)
                Text("\(tag.count)").opacity(0.55)
            }
            .font(AppFont.chip)
            .foregroundStyle(selected ? Tokens.onTint : Tokens.tint)
            .padding(.vertical, 4)
            .padding(.horizontal, 11)
            .background(Capsule().fill(selected ? Tokens.tint : Tokens.tintFill10))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(AppFont.sectionHeader)
            .kerning(0.4)
            .foregroundStyle(Tokens.meta)
            .padding(.top, 6)
    }
}

// MARK: - Row

/// One Library conversation row: title, meta ("7:02 PM · 1 hr 40 min · mostly quiet"),
/// optional one-line summary, optional gray tag chips. Live rows get the badge, no summary,
/// no chevron; the row navigates to the Live screen instead of the conversation detail.
private struct ConversationRowView: View {
    @Environment(AppRouter.self) private var router
    let row: LibraryRow

    var body: some View {
        if row.isLive {
            Button {
                router.navigate(to: .live)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: Route.conversation(id: row.id, atMs: nil)) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title ?? "Conversation")
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .lineLimit(2)
                Text(TimeFmt.rowMeta(row))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                if !row.isLive, let summary = row.summary {
                    Text(summary)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .lineLimit(1)
                }
                if !row.isLive, !row.tags.isEmpty {
                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                        ForEach(row.tags, id: \.self) { TagChip(text: $0) }
                    }
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            if row.isLive {
                LiveBadge()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Full tag list ("more…", plan 6.7)

private struct AllTagsSheet: View {
    let tags: [TagWithCount]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.id) { tag in
                    Button {
                        onSelect(tag.name)
                    } label: {
                        HStack {
                            FilterChip(text: tag.name)
                            Spacer()
                            Text(Copy.Search.conversationCount(tag.count))
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $filter)
            .navigationTitle(Copy.Tags.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filtered: [TagWithCount] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

// MARK: - View model

@MainActor
@Observable
final class LibraryViewModel {
    var sections: [LibraryDayGroup] = []
    var tags: [TagWithCount] = []
    var filter: LibraryFilter = .all {
        didSet { Task { await load() } }
    }
    var selectedTag: String? {
        didSet { Task { await load() } }
    }

    private var started = false

    func start() async {
        await load()
        guard !started else { return }
        started = true
        let updates = AskLibraryDataSources.current.library.updates()
        for await _ in updates {
            await load()
        }
    }

    func load() async {
        let sources = AskLibraryDataSources.current
        do {
            sections = try await sources.library.library(filter: filter, tag: selectedTag)
            tags = try await sources.library.tags()
        } catch {
            // Mock sources don't throw; DB-backed sources surface errors via diagnostics.
        }
    }
}

#Preview("Library") {
    NavigationStack {
        LibraryScreen()
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
