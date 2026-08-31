import SwiftUI
import AppDB

/// The Ask sheet (mockup 2.8 + plan 6.6). Presented from Today's title pill, the Search
/// hand-off row, and the Conversation bottom bar — always context-scoped, scope always
/// visible (anti-B5). Initial state: composer + Recent (Q18). Citations tap through to the
/// cited conversation.
struct AskSheetView: View {
    let route: Route

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = AskViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetGrabber()

            SheetTitleRow(title: Copy.Ask.title) {
                ScopeMenu(scope: $model.scope)
            }

            content

            Spacer(minLength: 0)

            if model.hasContent {
                composer
            }
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 16)
        .background(Tokens.ground)
        .presentationDetents([.height(620)])
        .presentationDragIndicator(.hidden)
        .task { await model.prepare(route: route) }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !model.hasContent {
            Text(Copy.Ask.nothingToAskYet)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            switch model.state {
            case .initial:
                recentList
            case .loading(let question):
                questionText(question)
                Card {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            case .answer(let entry):
                answerState(entry)
            case .failed(let question):
                questionText(question)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("That didn’t go through.")
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.tertiary)
                        Button(Copy.Common.retry) {
                            model.send(question)
                        }
                        .buttonStyle(.smallBordered)
                    }
                }
            }
        }
    }

    private func questionText(_ question: String) -> some View {
        Text(question)
            .font(AppFont.headline)
            .foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Recent (Q18)

    @ViewBuilder
    private var recentList: some View {
        if !model.recent.isEmpty {
            Text(Copy.Ask.recentSection.uppercased())
                .font(AppFont.sectionHeader)
                .kerning(0.4)
                .foregroundStyle(Tokens.meta)

            ScrollView {
                VStack(spacing: Tokens.blockGap) {
                    ListCard {
                        ForEach(model.recent, id: \.id) { entry in
                            recentRow(entry)
                        }
                    }
                    Button(Copy.Ask.clearHistory) {
                        model.confirmClear = true
                    }
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tint)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog(
                        Copy.Ask.clearHistory, isPresented: $model.confirmClear,
                        titleVisibility: .visible
                    ) {
                        Button(Copy.Ask.clearHistory, role: .destructive) {
                            model.clearHistory()
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ entry: AskEntry) -> some View {
        Button {
            model.reopen(entry)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.question)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(TimeFmt.relative(
                        Date(timeIntervalSince1970: Double(entry.createdAtMs) / 1000)))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.faint)
                }
                Text(answerPreview(entry.answerText))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func answerPreview(_ text: String) -> String {
        let withoutCitations = text.replacingOccurrences(
            of: " ?\\[\\d+\\]", with: "", options: .regularExpression)
        // One-line history row: drop list/heading markers and emphasis so the preview reads
        // as a sentence rather than as Markdown source.
        let firstLine =
            withoutCitations
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let unmarked = firstLine.replacingOccurrences(
            of: "^(#{1,6}\\s+|[-*+]\\s+|\\d{1,3}[.)]\\s+|>\\s*)", with: "",
            options: .regularExpression)
        return InlineMarkdown.plainText(unmarked)
    }

    // MARK: - Answer

    @ViewBuilder
    private func answerState(_ entry: AskEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                questionText(entry.question)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        MarkdownText(entry.answerText, lineSpacing: 7) { number in
                            openCitation(entry: entry, number: number)
                        }

                        if !entry.citations.isEmpty {
                            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                            Button {
                                withAnimation(Motion.animation(.snappy(duration: 0.2))) {
                                    model.showSources.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(momentsLabel(entry))
                                        .font(AppFont.footnote)
                                        .foregroundStyle(Tokens.meta)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Tokens.chevron)
                                        .rotationEffect(.degrees(model.showSources ? 90 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if model.showSources {
                                ForEach(sources(entry), id: \.number) { source in
                                    Button {
                                        openConversation(id: source.id)
                                    } label: {
                                        HStack(spacing: 8) {
                                            CitationChip(number: source.number)
                                            Text(source.title)
                                                .font(AppFont.footnote)
                                                .foregroundStyle(Tokens.tint)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Source {
        let number: Int
        let id: String
        let title: String
    }

    private func sources(_ entry: AskEntry) -> [Source] {
        entry.citations.map { citation in
            Source(
                number: citation.number,
                id: citation.segmentId,
                title: AskLibraryDataSources.current.ask
                    .conversationTitle(citedId: citation.segmentId) ?? "Conversation")
        }
    }

    private func momentsLabel(_ entry: AskEntry) -> String {
        let titles = sources(entry).map(\.title)
        var unique: [String] = []
        for title in titles where !unique.contains(title) { unique.append(title) }
        return Copy.Ask.moments(unique.count, unique.joined(separator: ", "))
    }

    private func openCitation(entry: AskEntry, number: Int) {
        guard let citation = entry.citations.first(where: { $0.number == number })
            ?? entry.citations.first else { return }
        openConversation(id: citation.segmentId)
    }

    private func openConversation(id: String) {
        dismiss()
        router.navigate(to: .conversation(id: id, atMs: nil))
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                model.isFollowUp ? Copy.Ask.followUpPlaceholder : Copy.Ask.title,
                text: $model.draft
            )
            .font(AppFont.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(
                Capsule().fill(Tokens.surface)
                    .overlay(Capsule().strokeBorder(Tokens.barHairline, lineWidth: 0.5))
            )
            .submitLabel(.send)
            .onSubmit {
                Haptics.sent()
                model.sendDraft()
            }

            CircleSendButton {
                Haptics.sent()
                model.sendDraft()
            }
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(
                    model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
    }
}

// MARK: - Scope menu (plan 6.6 — shared with Search's date scoping)

struct ScopeMenu: View {
    @Binding var scope: AskScope
    var includePickDates = true

    @State private var showDatePicker = false
    @State private var rangeStart = Date().addingTimeInterval(-3 * 86_400)
    @State private var rangeEnd = Date()

    var body: some View {
        Menu {
            Button(Copy.Ask.scopeToday) { scope = .today }
            Button(Copy.Ask.scopeYesterday) { scope = .yesterday }
            Button(Copy.Ask.scopeLast7Days) { scope = .last7Days }
            Button(Copy.Ask.scopeEverything) { scope = .everything }
            if includePickDates {
                Button(Copy.Ask.scopePickDates) { showDatePicker = true }
            }
        } label: {
            HStack(spacing: 5) {
                Text(scope.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(AppFont.chip)
            .foregroundStyle(Tokens.tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .padding(.horizontal, 11)
            .background(Capsule().fill(Tokens.tintFill10))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .accessibilityLabel(Copy.A11y.scope(scope.label))
        .accessibilityHint(Copy.A11y.scopeHint)
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                Form {
                    DatePicker(
                        "Start", selection: $rangeStart, displayedComponents: .date)
                    DatePicker(
                        "End", selection: $rangeEnd, in: rangeStart...,
                        displayedComponents: .date)
                }
                .navigationTitle(Copy.Ask.scopePickDates)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Common.done) {
                            scope = .dateRange(start: rangeStart, end: rangeEnd)
                            showDatePicker = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.cancel) { showDatePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - View model

@MainActor
@Observable
final class AskViewModel {
    enum SheetState: Equatable {
        case initial
        case loading(question: String)
        case answer(AskEntry)
        case failed(question: String)
    }

    var state: SheetState = .initial
    var scope: AskScope = .lastDays(2)
    var recent: [AskEntry] = []
    var draft = ""
    var showSources = false
    var confirmClear = false

    var hasContent: Bool { AskLibraryDataSources.current.ask.hasContent }
    var isFollowUp: Bool {
        if case .answer = state { return true }
        return false
    }

    private var prepared = false

    func prepare(route: Route) async {
        guard !prepared else { return }
        prepared = true
        var handOffQuery: String?
        if case .ask(let scopeKey, let query) = route {
            scope = AskScope.parse(scopeKey) { id in
                AskLibraryDataSources.current.ask.conversationTitle(citedId: id)
            }
            handOffQuery = query?.trimmingCharacters(in: .whitespaces)
        }
        await reloadRecent()
        if let query = handOffQuery, !query.isEmpty {
            send(query)
        }
    }

    func reloadRecent() async {
        recent = (try? await AskLibraryDataSources.current.ask.recent()) ?? []
    }

    func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        draft = ""
        send(question)
    }

    func send(_ question: String) {
        state = .loading(question: question)
        showSources = false
        Task {
            do {
                let entry = try await AskLibraryDataSources.current.ask.ask(
                    question: question, scope: scope)
                state = .answer(entry)
                await reloadRecent()
            } catch {
                state = .failed(question: question)
            }
        }
    }

    func reopen(_ entry: AskEntry) {
        showSources = false
        state = .answer(entry)
    }

    func clearHistory() {
        Task {
            try? await AskLibraryDataSources.current.ask.clearHistory()
            await reloadRecent()
        }
    }
}

#Preview("Ask sheet") {
    Color.black.sheet(isPresented: .constant(true)) {
        AskSheetView(route: .ask(scope: nil, query: nil))
            .environment(AppRouter())
            .tint(Tokens.tint)
    }
}
