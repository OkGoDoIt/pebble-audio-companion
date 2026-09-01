import SwiftUI
import AppDB

/// The Ask tab (mockup 2.8 + plan 6.6) — always context-scoped, scope always visible
/// (anti-B5). Initial state: composer + Recent (Q18). Citations tap through to the cited
/// conversation.
///
/// Ask is a CONVERSATION: every turn stays on screen and every follow-up is answered with the
/// earlier turns as context, so "so what's the plan?" means what it means in a chat. Recent
/// lists whole conversations, and reopening one restores all of it.
///
/// It was a 620 pt sheet behind a pill on Today. A sheet is a thing you dismiss, and it took
/// the whole conversation with it: no back, no history you could return to mid-thought, and a
/// citation tap had to close the answer you were reading in order to show you its source.
/// A tab keeps the thread, and a citation now pushes the recording on top of it.
struct AskScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var model = AskViewModel()

    /// Scroll target that keeps the newest turn in view as the conversation grows.
    /// Anchor for the turn being asked, so a question in flight scrolls to the same place its
    /// answer will occupy.
    private let pendingAnchor = "ask-thread-pending"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 0)
                ScopeMenu(scope: $model.scope)
            }
            .padding(.top, 2)

            content

            Spacer(minLength: 0)

            if model.hasContent {
                composer
            }
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 8)
        .background(Tokens.ground)
        .navigationTitle(Copy.Ask.title)
        .toolbar {
            if model.isInThread {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Copy.Ask.newConversation) { model.startNewConversation() }
                        .accessibilityHint(Copy.A11y.newConversationHint)
                }
            }
        }
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
        .task { await model.prepare(route: router.consumePendingAsk()) }
        // A second "Ask about this conversation" while the tab is already open has to re-scope
        // and re-ask. Nothing re-reads a route on a screen that never went away.
        .onChange(of: router.pendingAsk) { _, pending in
            guard pending != nil else { return }
            model.accept(route: router.consumePendingAsk())
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .conversation(let id, let atMs, let focus):
            ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
        case .note(let id):
            SavedNotesScreen(noteId: id)
        default:
            Color.clear.background(Tokens.ground)
        }
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
        } else if model.isInThread {
            threadView
        } else {
            recentList
        }
    }

    // MARK: - The conversation

    private var threadView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.turns, id: \.id) { turn in
                        answeredTurn(turn).id(turn.id)
                    }

                    if let question = model.pendingQuestion {
                        VStack(alignment: .leading, spacing: 10) {
                            questionText(question)
                            Card {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .padding(.vertical, 24)
                            }
                        }
                        .accessibilityLabel(Copy.A11y.askThinking(question))
                        .id(pendingAnchor)
                    } else if let question = model.failedQuestion {
                        VStack(alignment: .leading, spacing: 10) {
                            questionText(question)
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(Copy.Ask.didNotGoThrough)
                                        .font(AppFont.subBody)
                                        .foregroundStyle(Tokens.tertiary)
                                    Button(Copy.Common.retry) { model.retry() }
                                        .buttonStyle(.smallBordered)
                                }
                            }
                        }
                        .id(pendingAnchor)
                    }

                    // Room below the last turn so its question can actually reach the top of the
                    // scroll view — without it, a short final answer cannot scroll far enough and
                    // lands mid-screen.
                    Color.clear.frame(height: 400)
                }
            }
            .onChange(of: model.threadProgress) { _, _ in
                // To the TOP of the newest turn, not the bottom of the thread. An answer can run
                // to several screens, and landing at its end means reading it backwards: the
                // first thing you want to see is the question you asked and the sentence that
                // answers it.
                withAnimation(Motion.animation(.snappy(duration: 0.25))) {
                    proxy.scrollTo(newestAnchor, anchor: .top)
                }
            }
        }
    }

    /// The turn the thread should be showing: the one in flight, else the newest answered one.
    private var newestAnchor: String {
        model.pendingQuestion != nil || model.failedQuestion != nil
            ? pendingAnchor
            : (model.turns.last?.id ?? pendingAnchor)
    }

    private func answeredTurn(_ entry: AskEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionText(entry.question)
            Card { answerBody(entry) }
        }
    }

    private func questionText(_ question: String) -> some View {
        Text(question)
            .font(AppFont.headline)
            .foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        ForEach(model.recent) { thread in
                            recentRow(thread)
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

    /// A row is a whole past conversation: the question it opened with, and how far it got.
    private func recentRow(_ thread: AskThread) -> some View {
        Button {
            model.reopen(thread)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread.openingQuestion)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(TimeFmt.relative(
                        Date(timeIntervalSince1970: Double(thread.updatedAtMs) / 1000)))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.faint)
                }
                HStack(spacing: 6) {
                    if thread.turns.count > 1 {
                        Text(Copy.Ask.followUpCount(thread.turns.count - 1))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                    }
                    Text(answerPreview(thread.lastTurn?.answerText ?? ""))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .lineLimit(1)
                }
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

    /// Sources expand per turn, so opening one answer's moments does not fold another's.
    @ViewBuilder
    private func answerBody(_ entry: AskEntry) -> some View {
        let showSources = model.expandedSources.contains(entry.id)
        VStack(alignment: .leading, spacing: 10) {
            MarkdownText(entry.answerText, lineSpacing: 7) { number in
                openCitation(entry: entry, number: number)
            }

            // An answer drawn from part of the range says so, in the same calm register the
            // rest of the app uses for missing audio. Complete answers say nothing — a note on
            // every answer would be noise, and shortfall is the case that changes what the
            // answer means.
            if entry.isPartialCoverage,
                let read = entry.conversationsRead, let inScope = entry.conversationsInScope
            {
                Text(Copy.Ask.partialCoverage(read: read, inScope: inScope))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.citations.isEmpty {
                Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                Button {
                    withAnimation(Motion.animation(.snappy(duration: 0.2))) {
                        model.toggleSources(entry)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(momentsLabel(entry))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.chevron)
                            .rotationEffect(.degrees(showSources ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showSources {
                    ForEach(sources(entry), id: \.number) { source in
                        Button {
                            open(citation: source.citation)
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

    private struct Source {
        let citation: AskCitation
        let title: String

        var number: Int { citation.number }
    }

    private func sources(_ entry: AskEntry) -> [Source] {
        entry.citations.map { citation in
            Source(
                citation: citation,
                title: AskLibraryDataSources.current.ask
                    .conversationTitle(citedId: citation.segmentId) ?? "Conversation")
        }
    }

    private func momentsLabel(_ entry: AskEntry) -> String {
        let titles = sources(entry).map(\.title)
        var unique: [String] = []
        for title in titles where !unique.contains(title) { unique.append(title) }
        return Copy.Ask.moments(unique)
    }

    /// Only the number the answer actually recorded: a chip the entry has no citation for
    /// opens nothing, rather than the first moment in the list, which it does not name.
    private func openCitation(entry: AskEntry, number: Int) {
        guard let citation = entry.citations.first(where: { $0.number == number })
        else { return }
        open(citation: citation)
    }

    /// A citation names a stretch of a SEGMENT, and `conversation/<segmentId>` is not a
    /// conversation id — which is why every chip used to land on "Conversation not found".
    /// Resolve it to the conversation holding it, cue the scrubber to where the cited stretch
    /// begins, and mark those lines on arrival.
    private func open(citation: AskCitation) {
        Task { @MainActor in
            guard
                let target = await AskLibraryDataSources.current.ask.citationTarget(
                    for: citation)
            else { return }
            // Pushed, not navigated: the answer you were reading is still there when you come
            // back, which is the whole reason Ask stopped being a sheet.
            router.askPath.append(
                .conversation(
                    id: target.conversationId,
                    atMs: target.mediaOffsetMs,
                    focus: target.focus))
        }
    }

    // MARK: - Composer

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespaces).isEmpty && !model.isSending
    }

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
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
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
    /// The open conversation, oldest turn first. Empty means the sheet is showing Recent.
    private(set) var turns: [AskEntry] = []
    /// The question waiting on an answer, and the one whose answer failed. Only one at a time.
    private(set) var pendingQuestion: String?
    private(set) var failedQuestion: String?
    /// Thread the next answer joins. Nil until the first answer of a new conversation lands,
    /// which is what mints it.
    private var threadId: String?

    var scope: AskScope = .lastDays(2)
    var recent: [AskThread] = []
    var draft = ""
    var expandedSources: Set<String> = []
    var confirmClear = false

    var hasContent: Bool { AskLibraryDataSources.current.ask.hasContent }
    /// True once a conversation is open — including while its first answer is still coming.
    var isInThread: Bool {
        !turns.isEmpty || pendingQuestion != nil || failedQuestion != nil
    }
    /// Anything after the first question is a follow-up, so the composer says so.
    var isFollowUp: Bool { isInThread }
    /// Changes on every turn added, sent, or failed — the cue to scroll to the newest one.
    var threadProgress: String {
        "\(turns.count)|\(pendingQuestion ?? "")|\(failedQuestion ?? "")"
    }

    private var prepared = false

    func prepare(route: Route?) async {
        guard !prepared else { return }
        prepared = true
        await reloadRecent()
        accept(route: route)
    }

    /// Applies an incoming `.ask` link: re-scope, and ask straight away when it carried a
    /// question. A link that arrives mid-thread starts a fresh conversation rather than
    /// appending to whatever was on screen — "ask about this recording" is a new subject.
    func accept(route: Route?) {
        guard case .ask(let scopeKey, let query)? = route else { return }
        let question = query?.trimmingCharacters(in: .whitespaces) ?? ""
        if isInThread { startNewConversation() }
        scope = AskScope.parse(scopeKey) { id in
            AskLibraryDataSources.current.ask.conversationTitle(citedId: id)
        }
        if !question.isEmpty { send(question) }
    }

    func reloadRecent() async {
        recent = (try? await AskLibraryDataSources.current.ask.recentThreads()) ?? []
    }

    /// True while an answer is on its way — a second question sent now would race the first
    /// into the same thread and land out of order.
    var isSending: Bool { pendingQuestion != nil }

    func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !isSending else { return }
        draft = ""
        send(question)
    }

    /// Asks the next turn of the open conversation. The turns already on screen go with it,
    /// so a follow-up is answered in context instead of as a fresh question.
    func send(_ question: String) {
        pendingQuestion = question
        failedQuestion = nil
        let thread = openThread
        Task {
            do {
                let entry = try await AskLibraryDataSources.current.ask.ask(
                    question: question, thread: thread, scope: scope)
                // The first answer of a new conversation is what mints its thread id.
                threadId = entry.threadId
                turns.append(entry)
                pendingQuestion = nil
                await reloadRecent()
            } catch {
                pendingQuestion = nil
                failedQuestion = question
            }
        }
    }

    func retry() {
        guard let question = failedQuestion else { return }
        send(question)
    }

    /// The conversation as the data source needs it: nil until it has a turn to build on.
    private var openThread: AskThread? {
        guard let threadId, !turns.isEmpty else { return nil }
        return AskThread(id: threadId, turns: turns)
    }

    func reopen(_ thread: AskThread) {
        expandedSources = []
        failedQuestion = nil
        pendingQuestion = nil
        threadId = thread.id
        turns = thread.turns
    }

    /// Back to Recent, ready for an unrelated question. The conversation is already saved.
    func startNewConversation() {
        expandedSources = []
        failedQuestion = nil
        pendingQuestion = nil
        threadId = nil
        turns = []
        draft = ""
    }

    func toggleSources(_ entry: AskEntry) {
        if expandedSources.contains(entry.id) {
            expandedSources.remove(entry.id)
        } else {
            expandedSources.insert(entry.id)
        }
    }

    func clearHistory() {
        Task {
            try? await AskLibraryDataSources.current.ask.clearHistory()
            await reloadRecent()
        }
    }
}

#Preview("Ask") {
    NavigationStack {
        AskScreen()
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
