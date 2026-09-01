import SwiftUI
import AppDB

/// The Ask tab's ROOT (mockup 2.8 + plan 6.6) — always context-scoped, scope always visible
/// (anti-B5). It is a list of past conversations plus a composer, and nothing else.
///
/// A conversation is a child screen (`AskThreadScreen`), pushed onto the tab's stack: opening
/// one from Recent and starting a new one both push, so both come back with the system back
/// button or an edge swipe. Before this, the root swapped its own body between "Recent" and
/// "a thread" and offered a bespoke "New" button as the only way back — a screen you left by
/// pressing a word in the corner, with the swipe doing nothing and the back chevron absent.
struct AskScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var model = AskHomeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content

            Spacer(minLength: 0)

            if model.hasContent {
                AskComposer(
                    text: $model.draft,
                    placeholder: Copy.Ask.title,
                    send: ask)
            }
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 8)
        .background(Tokens.ground)
        .navigationTitle(Copy.Ask.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Chromeless: the toolbar draws its own capsule on iOS 26, and the pill
                // ScopeMenu paints for Search would sit inside it as a second one.
                ScopeMenu(scope: $model.scope, style: .bare)
            }
        }
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
        .task {
            await model.reloadRecent()
            open(pending: router.consumePendingAsk())
        }
        // A second "Ask about this conversation" while the tab is already open has to re-scope
        // and re-ask. Nothing re-reads a route on a screen that never went away.
        .onChange(of: router.pendingAsk) { _, pending in
            guard pending != nil else { return }
            open(pending: router.consumePendingAsk())
        }
        // Recent is only correct while it is on screen: a conversation had somewhere else
        // gains turns, and a brand-new one does not exist here until it has been answered.
        .onChange(of: router.askPath.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            Task { await model.reloadRecent() }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .askThread(let id, let question):
            // The scope travels as a binding rather than in the route: a follow-up asked in
            // the thread is scoped the way the tab is scoped, and changing it there is the
            // same change coming back.
            AskThreadScreen(threadId: id, openingQuestion: question, scope: $model.scope)
        case .conversation(let id, let atMs, let focus):
            ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
        case .note(let id):
            SavedNotesScreen(noteId: id)
        default:
            Color.clear.background(Tokens.ground)
        }
    }

    // MARK: - Asking

    /// A new question opens its own screen and is asked there, so the thread you were reading
    /// (if you came back from one) is not the thing that answers it.
    private func ask() {
        let question = model.draft.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        model.draft = ""
        Haptics.sent()
        router.askPath.append(.askThread(id: nil, question: question))
    }

    /// Applies an incoming `.ask` link: re-scope, and open a conversation straight away when
    /// it carried a question. A link that carries only a scope leaves you on Recent with the
    /// composer ready, rather than in an empty thread.
    private func open(pending route: Route?) {
        guard case .ask(let scopeKey, let query)? = route else { return }
        model.scope = AskScope.parse(scopeKey) { id in
            AskLibraryDataSources.current.ask.conversationTitle(citedId: id)
        }
        let question = query?.trimmingCharacters(in: .whitespaces) ?? ""
        router.askPath = question.isEmpty ? [] : [.askThread(id: nil, question: question)]
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
            recentList
        }
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
    /// It pushes — hence the chevron, which is the only honest promise about what a tap does.
    private func recentRow(_ thread: AskThread) -> some View {
        Button {
            router.askPath.append(.askThread(id: thread.id, question: nil))
        } label: {
            HStack(alignment: .top, spacing: 10) {
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
                        Text(AskAnswerPreview.line(thread.lastTurn?.answerText ?? ""))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Copy.A11y.openAskThreadHint)
    }
}

// MARK: - Recent row preview text

enum AskAnswerPreview {
    /// One-line history row: drop citations, list/heading markers and emphasis so the preview
    /// reads as a sentence rather than as Markdown source.
    static func line(_ text: String) -> String {
        let withoutCitations = text.replacingOccurrences(
            of: " ?\\[\\d+\\]", with: "", options: .regularExpression)
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
}

// MARK: - Composer (shared by the root and the open conversation)

/// The ask field. Dismisses the keyboard on send: on the root the answer is arriving on a
/// screen that is about to be pushed over it, and in a thread the point of sending is to read
/// what comes back.
struct AskComposer: View {
    @Binding var text: String
    var placeholder: String
    var isSending: Bool = false
    var send: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .font(AppFont.callout)
                .focused($focused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .background(
                    Capsule().fill(Tokens.surface)
                        .overlay(Capsule().strokeBorder(Tokens.barHairline, lineWidth: 0.5))
                )
                .submitLabel(.send)
                .onSubmit(submit)

            CircleSendButton(action: submit)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
        }
    }

    private func submit() {
        guard canSend else { return }
        focused = false
        send()
    }
}

// MARK: - Scope menu (plan 6.6 — shared with Search's date scoping)

struct ScopeMenu: View {
    /// `pill` paints its own tinted capsule, for use inside content (Search). `bare` renders
    /// text and a chevron only, for a toolbar that supplies the capsule itself.
    enum Style { case pill, bare }

    @Binding var scope: AskScope
    var style: Style = .pill
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
            if style == .bare {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(scope.label)
                }
            } else {
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

/// The root's state only: the scope every question inherits, the history list, and the draft.
/// A conversation's own state belongs to the screen showing it, so leaving one disposes of it
/// and reopening it reads it back from history.
@MainActor
@Observable
final class AskHomeViewModel {
    var scope: AskScope = .lastDays(2)
    var recent: [AskThread] = []
    var draft = ""
    var confirmClear = false

    var hasContent: Bool { AskLibraryDataSources.current.ask.hasContent }

    func reloadRecent() async {
        recent = (try? await AskLibraryDataSources.current.ask.recentThreads()) ?? []
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
