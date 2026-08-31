import SwiftUI
import AppDB

/// The Library search state (mockup 2.7): active field + Cancel, the "Ask about “{q}”"
/// hand-off row, then Tags / Conversations / Follow-ups sections (≤3 each with counts,
/// matches highlighted on `tintFill18`). The Library tab stays lit; date scoping reuses the
/// Ask scope menu (plan 6.6).
struct SearchStateView: View {
    @Environment(AppRouter.self) private var router
    @Bindable var model: SearchViewModel
    let onCancel: () -> Void
    let onSelectTag: (String) -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: Tokens.blockGap) {
            fieldRow
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    scopeRow

                    if !model.trimmedQuery.isEmpty {
                        askHandOffRow
                        if model.results.isEmpty, !model.searching {
                            Text(Copy.Search.noMatches(model.trimmedQuery))
                                .font(AppFont.subBody)
                                .foregroundStyle(Tokens.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            resultSections
                        }
                    }
                }
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.bottom, Tokens.blockGap)
            }
        }
        .background(Tokens.ground)
        .task { fieldFocused = true }
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.search()
        }
        .task(id: model.scope) { await model.search() }
    }

    // MARK: - Field row

    private var fieldRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.meta)
                TextField(Copy.Library.searchPlaceholder, text: $model.query)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Tokens.chevron)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))

            Button(Copy.Common.cancel) {
                fieldFocused = false
                onCancel()
            }
            .font(AppFont.bodyPlain)
            .foregroundStyle(Tokens.tint)
            .buttonStyle(.plain)
        }
    }

    /// Date scoping — the same menu as the Ask sheet's scope picker (plan 6.6).
    private var scopeRow: some View {
        HStack {
            Spacer()
            ScopeMenu(scope: $model.scope, includePickDates: false)
        }
    }

    // MARK: - Ask hand-off

    private var askHandOffRow: some View {
        Button {
            router.askSheet = .ask(scope: model.scope.routeKey, query: model.trimmedQuery)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.tint)
                (Text(Copy.Ask.title).font(AppFont.rowTitle).foregroundColor(Tokens.tint)
                    + Text(" about “\(model.trimmedQuery)”")
                    .font(AppFont.callout).foregroundColor(Tokens.label))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private var resultSections: some View {
        if !model.results.tags.isEmpty {
            sectionHeader(Copy.Search.tagsSection, total: model.results.tags.count)
            ListCard {
                ForEach(model.results.tags.prefix(3), id: \.id) { tag in
                    Button {
                        onSelectTag(tag.name)
                    } label: {
                        HStack(spacing: 10) {
                            FilterChip(text: tag.name)
                            Text(Copy.Search.conversationCount(tag.count))
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                            Spacer(minLength: 0)
                            chevron
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.results.conversations.isEmpty {
            sectionHeader(
                Copy.Search.conversationsSection, total: model.results.conversations.count)
            ListCard {
                ForEach(model.results.conversations.prefix(3)) { hit in
                    NavigationLink(value: Route.conversation(id: hit.id, atMs: nil)) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.title)
                                    .font(AppFont.rowTitle)
                                    .foregroundStyle(Tokens.label)
                                Text(hit.whenLabel)
                                    .font(AppFont.footnote)
                                    .foregroundStyle(Tokens.meta)
                                highlighted(hit.snippet)
                                    .font(AppFont.caption)
                                    .foregroundStyle(Tokens.secondaryBody)
                            }
                            Spacer(minLength: 0)
                            chevron
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.results.followUps.isEmpty {
            sectionHeader(Copy.Search.followUpsSection, total: model.results.followUps.count)
            ListCard {
                ForEach(model.results.followUps.prefix(3), id: \.id) { followUp in
                    followUpRow(followUp)
                }
            }
        }
    }

    private func followUpRow(_ followUp: FollowUp) -> some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    try? await AskLibraryDataSources.current.conversations
                        .toggleFollowUp(id: followUp.id)
                    await model.search()
                }
            } label: {
                Image(systemName: followUp.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(followUp.done ? Tokens.tint : Tokens.chevron)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            highlighted(followUp.text)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 0)
        }
    }

    private func sectionHeader(_ label: String, total: Int) -> some View {
        HStack {
            Text(label.uppercased())
                .font(AppFont.sectionHeader)
                .kerning(0.4)
                .foregroundStyle(Tokens.meta)
            Spacer()
            if total > 3 {
                Text("\(total)")
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.faint)
            }
        }
        .padding(.top, 4)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tokens.chevron)
            .accessibilityHidden(true)
    }

    /// Match highlighting: query occurrences on `tintFill18`, weight 600 (mockup 2.7).
    private func highlighted(_ text: String) -> Text {
        var attributed = AttributedString(text)
        let query = model.trimmedQuery
        guard !query.isEmpty else { return Text(attributed) }
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(
            of: query, options: .caseInsensitive)
        {
            attributed[range].backgroundColor = Tokens.tintFill18
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return Text(attributed)
    }
}

// MARK: - View model

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var scope: AskScope = .everything
    var results = SearchResults()
    var searching = false

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    func search() async {
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            results = SearchResults()
            return
        }
        searching = true
        defer { searching = false }
        do {
            results = try await AskLibraryDataSources.current.search.search(
                query: trimmed, scope: scope)
        } catch {
            results = SearchResults()
        }
    }
}
