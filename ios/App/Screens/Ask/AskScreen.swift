import SwiftUI
import AppDB
import UIKit

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
        // `.whitespacesAndNewlines`, now the composer is a multi-line field: a draft that is
        // three Returns is an empty question, and a trailing newline is not part of what was
        // asked — it would ride into the thread's own heading and the history row.
        let question = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Drag the list and the keyboard follows your finger down — the gesture people
            // already use to get out of a composer, and the one that gives the tab bar back.
            .scrollDismissesKeyboard(.interactively)
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
///
/// It GROWS with the question. A single-line field made every question look like it was meant
/// to be short — you could not see the sentence you were typing past about six words, and a
/// long one scrolled sideways under the cursor. Ask is the one place in the app where the
/// person writes more than a word, so the box is the size of what they wrote, up to six lines.
///
/// Growing is about WRAPPING, not about paragraphs. A question to an AI never legitimately
/// contains a line break, so the keyboard keeps a Send key and Return sends.
///
/// `.submitLabel(.send)` is what puts that key there — it is the real system Send key, not a
/// drawing of one. What SwiftUI will not do is deliver its press: on a vertical-axis `TextField`
/// the key inserts a line break and `onSubmit` is never called (still true on iOS 26 — it fires
/// only for single-line fields and hardware keyboards). There is no modifier that changes this,
/// so the break IS the press, and `sendOnReturn` reads it as one. It never survives to be seen:
/// it is stripped in the same state update that added it.
///
/// The arrow stays as the visible, non-keyboard way to send. And the keyboard still needs a way
/// out that is not sending — hence the Done bar above it, and
/// `.scrollDismissesKeyboard(.interactively)` on the lists both screens put above this field.
struct AskComposer: View {
    @Binding var text: String
    var placeholder: String
    var isSending: Bool = false
    var send: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Newlines count as whitespace here: on a multi-line field the difference between an empty
    /// box and one holding three Returns is nothing worth sending.
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// Six lines is about a paragraph at the default sizes. At accessibility sizes six lines is
    /// most of the screen, and what the field is asking about is the thing above it — so the
    /// box stops growing sooner there and scrolls inside itself instead.
    private var maxLines: Int { typeSize.isAccessibilitySize ? 3 : 6 }

    var body: some View {
        // Bottom-aligned: the send button belongs beside the line being typed, not floating
        // half-way up a five-line question.
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(AppFont.callout)
                .focused($focused)
                .lineLimit(1...maxLines)
                .submitLabel(.send)
                .onChange(of: text) { previous, current in
                    sendOnReturn(previous: previous, current: current)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .background(
                    fieldShape.fill(Tokens.surface)
                        .overlay(fieldShape.strokeBorder(Tokens.barHairline, lineWidth: 0.5))
                )
                .toolbar {
                    // The standard escape. A plain text button, not a `Label`: the keyboard bar
                    // is a bar, and iOS 26 renders a `Label` in one icon-only.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(Copy.Common.done) { dismissKeyboard() }
                    }
                }

            CircleSendButton(action: submit)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
        }
    }

    /// A capsule at one line, a rounded box after that. A real `Capsule` around a grown field
    /// draws half-circles the height of the whole box, which looks like a mistake; a fixed
    /// 22 pt radius is what iMessage's composer does and reads right at every height.
    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private func submit() {
        guard canSend else { return }
        dismissKeyboard()
        send()
    }

    /// The Send key's press — the one thing SwiftUI will not hand us directly.
    ///
    /// Tightly scoped so that only the key can trigger it: exactly one character was added, and
    /// it added exactly one line break. Pasting a question that contains line breaks arrives as
    /// many characters at once and so is still a paste; a break typed into the middle of a
    /// sentence is still caught, because what is counted is line breaks rather than a suffix.
    /// The break is stripped in the same update that added it, so the field never renders it and
    /// the draft never carries it.
    private func sendOnReturn(previous: String, current: String) {
        guard current.count == previous.count + 1,
            current.filter(\.isNewline).count == previous.filter(\.isNewline).count + 1
        else { return }
        text = current.filter { !$0.isNewline }
        submit()
    }

    /// `focused = false` is the SwiftUI half. The responder call is the other half, because a
    /// `.keyboard` toolbar belongs to a view hierarchy rather than to a field, and the Ask tab
    /// keeps TWO composers alive at once — the root's, underneath a pushed thread's. If the bar
    /// on screen is the other composer's, its `@FocusState` is not the field holding the
    /// keyboard, and Done would visibly do nothing.
    private func dismissKeyboard() {
        focused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    /// Cached: the live check walks the spool directory, and reading it per render made every
    /// keystroke in the composer pay for a disk scan. Starts true so a library with content
    /// (the common case) never flashes the empty state while the first check runs.
    private(set) var hasContent = true

    func reloadRecent() async {
        hasContent = await AskLibraryDataSources.current.ask.hasContent()
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
