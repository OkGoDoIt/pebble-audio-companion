import SwiftUI
import AppDB
import Intelligence

/// One Ask conversation, as a pushed detail screen: back chevron, edge-swipe, the lot.
///
/// Ask is a CONVERSATION: every turn stays on screen and every follow-up is answered with the
/// earlier turns as context, so "so what's the plan?" means what it means in a chat. A citation
/// pushes the cited recording ON TOP of this screen, so the answer being read is still there
/// when you come back — the reason Ask stopped being a sheet.
struct AskThreadScreen: View {
    /// The conversation to reopen from history, or nil for one being started right now.
    let threadId: String?
    /// The question a new conversation opens with — asked on appear.
    let openingQuestion: String?
    @Binding var scope: AskScope

    @Environment(AppRouter.self) private var router
    @State private var model = AskThreadViewModel()
    /// The first scroll positions the thread; it should not fly past the user on arrival.
    @State private var hasPositioned = false

    /// Scroll target that keeps the newest turn in view as the conversation grows.
    /// Anchor for the turn being asked, so a question in flight scrolls to the same place its
    /// answer will occupy.
    private let pendingAnchor = "ask-thread-pending"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            threadView

            AskComposer(
                text: $model.draft,
                placeholder: Copy.Ask.followUpPlaceholder,
                isSending: model.isSending,
                send: { Haptics.sent(); model.sendDraft(scope: scope) })
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 8)
        // Same composer, same clearance — see `AskScreen`.
        .noteJobDockClearance()
        .background(Tokens.ground)
        // The question is the heading of the content; repeating it in the bar would say it
        // twice and truncate it once. The back button already reads "Ask".
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ScopeMenu(scope: $scope, style: .bare)
            }
        }
        .task { await model.start(threadId: threadId, question: openingQuestion, scope: scope) }
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
                                    // WHY it did not go through. This card used to say only
                                    // the line above, which reads the same for a rejected API
                                    // key, an aeroplane and a question too long for the
                                    // on-device model — three situations with three different
                                    // things to do about them, and Retry the right move in
                                    // only one.
                                    if let reason = model.failedReason {
                                        Text(reason)
                                            .font(AppFont.subBody)
                                            .foregroundStyle(Tokens.tertiary)
                                    }
                                    Button(Copy.Common.retry) { model.retry(scope: scope) }
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
            // Same escape as the root's history list: drag the thread and the keyboard goes
            // down with your finger, which is how you get the tab bar back.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.threadProgress) { _, _ in
                // To the TOP of the newest turn, not the bottom of the thread. An answer can run
                // to several screens, and landing at its end means reading it backwards: the
                // first thing you want to see is the question you asked and the sentence that
                // answers it.
                guard hasPositioned else {
                    hasPositioned = true
                    proxy.scrollTo(newestAnchor, anchor: .top)
                    return
                }
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

    /// Titles come from the view model's cache, resolved once per new turn: looking them up
    /// live decoded a transcript per citation on every render — every keystroke in the
    /// composer paid for it.
    private func sources(_ entry: AskEntry) -> [Source] {
        entry.citations.map { citation in
            Source(
                citation: citation,
                title: model.citationTitles[citation.segmentId] ?? "Conversation")
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
            // Pushed on top of this thread, so the answer is still here on the way back.
            router.askPath.append(
                .conversation(
                    id: target.conversationId,
                    atMs: target.mediaOffsetMs,
                    focus: target.focus))
        }
    }
}

// MARK: - View model

/// One conversation's state. It belongs to the screen that shows it, so a thread cannot be
/// half-replaced by another: leaving disposes of it, and the next one starts clean.
@MainActor
@Observable
final class AskThreadViewModel {
    /// The open conversation, oldest turn first.
    private(set) var turns: [AskEntry] = []
    /// Conversation title per cited segment id, resolved off-main once per new turn. `sources`
    /// reads only this — resolving titles inside the render pass decoded transcripts on every
    /// body evaluation.
    private(set) var citationTitles: [String: String] = [:]
    /// The question waiting on an answer, and the one whose answer failed. Only one at a time.
    private(set) var pendingQuestion: String?
    private(set) var failedQuestion: String?
    /// The classified cause, in the app's own words. Nil when there is nothing useful to add
    /// beyond "that didn't go through" — never a raw provider message (B20).
    private(set) var failedReason: String?
    /// Thread the next answer joins. Nil until the first answer of a new conversation lands,
    /// which is what mints it.
    private var threadId: String?

    var draft = ""
    var expandedSources: Set<String> = []

    /// True while an answer is on its way — a second question sent now would race the first
    /// into the same thread and land out of order.
    var isSending: Bool { pendingQuestion != nil }
    /// Changes on every turn added, sent, or failed — the cue to scroll to the newest one.
    var threadProgress: String {
        "\(turns.count)|\(pendingQuestion ?? "")|\(failedQuestion ?? "")"
    }

    private var started = false

    /// Reads a past conversation back from history, or asks the opening question of a new one.
    /// Runs once: `.task` re-runs on every re-appearance, and re-asking on the way back from a
    /// citation would answer the same question twice.
    func start(threadId id: String?, question: String?, scope: AskScope) async {
        guard !started else { return }
        started = true
        if let id {
            threadId = id
            let threads = (try? await AskLibraryDataSources.current.ask.recentThreads()) ?? []
            turns = threads.first { $0.id == id }?.turns ?? []
            await resolveCitationTitles()
        }
        if let question, !question.isEmpty { send(question, scope: scope) }
    }

    func sendDraft(scope: AskScope) {
        // Newlines too: the composer grows with the text now, so a draft can legitimately hold
        // line breaks — including a trailing one nobody meant to ask.
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        draft = ""
        send(question, scope: scope)
    }

    /// Asks the next turn of the open conversation. The turns already on screen go with it,
    /// so a follow-up is answered in context instead of as a fresh question.
    func send(_ question: String, scope: AskScope) {
        pendingQuestion = question
        failedQuestion = nil
        failedReason = nil
        let thread = openThread
        Task {
            do {
                let entry = try await AskLibraryDataSources.current.ask.ask(
                    question: question, thread: thread, scope: scope)
                // The first answer of a new conversation is what mints its thread id.
                threadId = entry.threadId
                turns.append(entry)
                await resolveCitationTitles()
                pendingQuestion = nil
            } catch is CancellationError {
                pendingQuestion = nil
            } catch {
                pendingQuestion = nil
                failedQuestion = question
                let failure = AiFailure.classify(error)
                // `.unknown` adds nothing the line above does not already say, so it is left
                // off rather than padding the card with "Something went wrong."
                failedReason = failure.kind == .unknown ? nil : failure.reason
            }
        }
    }

    func retry(scope: AskScope) {
        guard let question = failedQuestion else { return }
        send(question, scope: scope)
    }

    /// The conversation as the data source needs it: nil until it has a turn to build on.
    private var openThread: AskThread? {
        guard let threadId, !turns.isEmpty else { return nil }
        return AskThread(id: threadId, turns: turns)
    }

    /// Fills the title cache for every citation on screen; ids already resolved are kept.
    private func resolveCitationTitles() async {
        let ids = turns.flatMap { $0.citations.map(\.segmentId) }
            .filter { citationTitles[$0] == nil }
        guard !ids.isEmpty else { return }
        let resolved = await AskLibraryDataSources.current.ask.citationTitles(for: ids)
        citationTitles.merge(resolved) { _, new in new }
    }

    func toggleSources(_ entry: AskEntry) {
        if expandedSources.contains(entry.id) {
            expandedSources.remove(entry.id)
        } else {
            expandedSources.insert(entry.id)
        }
    }
}

#Preview("Ask conversation") {
    @Previewable @State var scope: AskScope = .lastDays(2)
    return NavigationStack {
        AskThreadScreen(
            threadId: nil, openingQuestion: "What did we decide about the trip?", scope: $scope)
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
